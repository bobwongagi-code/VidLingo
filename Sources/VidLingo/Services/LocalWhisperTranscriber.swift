import Foundation
import VidLingoCore

enum LocalWhisperRunner {
    struct LanguageDetectionResult: Sendable {
        let language: LanguageOption
        let transcript: String
    }

    private struct WhisperRunResult {
        let text: String
    }

    static func transcribe(
        audioFileURL: URL,
        language: LanguageOption,
        token: ProcessCancellationToken,
        beamSize: Int = 5
    ) async throws -> String {
        return try await Task.detached(priority: .utility) {
            try token.check()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VidLingo-Whisper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let languageCode = whisperLanguageCode(for: language)
            return try transcribeSynchronously(
                audioFileURL: audioFileURL,
                languageCode: languageCode,
                temporaryDirectory: directory,
                beamSize: beamSize,
                token: token
            ).text
        }.value
    }

    static func detectLanguageWithTranscript(
        audioFileURL: URL,
        token: ProcessCancellationToken
    ) async throws -> LanguageDetectionResult? {
        try await Task.detached(priority: .utility) {
            try token.check()
            if let detectedLanguage = try detectLanguageSynchronously(audioFileURL: audioFileURL, token: token) {
                return LanguageDetectionResult(language: detectedLanguage, transcript: "")
            }

            var candidates = [(language: LanguageOption, text: String, score: Double)]()

            for candidate in WhisperLanguageScorer.candidates {
                try token.check()
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VidLingo-Whisper-Language-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                do {
                    let result = try transcribeSynchronously(
                        audioFileURL: audioFileURL,
                        languageCode: whisperLanguageCode(for: candidate),
                        temporaryDirectory: directory,
                        durationSeconds: 18,
                        token: token
                    )
                    let score = WhisperLanguageScorer.score(transcript: result.text, language: candidate)
                    candidates.append((candidate, result.text, score))
                } catch ProcessSupervisorError.cancelled {
                    throw ProcessSupervisorError.cancelled
                } catch ProcessSupervisorError.deadlineExceeded {
                    throw ProcessSupervisorError.deadlineExceeded
                } catch ProcessSupervisorError.processTimedOut {
                    throw ProcessSupervisorError.processTimedOut
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 单个语言候选失败时继续评估其他支持语言。
                }
            }

            let ranked = candidates.sorted { $0.score > $1.score }
            guard let best = ranked.first, best.score >= 0.35 else { return nil }
            if let runnerUp = ranked.dropFirst().first,
               best.score - runnerUp.score < 0.08 {
                return nil
            }
            return LanguageDetectionResult(language: best.language, transcript: best.text)
        }.value
    }

    private static func detectLanguageSynchronously(
        audioFileURL: URL,
        token: ProcessCancellationToken
    ) throws -> LanguageOption? {
        try token.check()
        guard let executableURL = WhisperModelResolver.cliExecutableURL() else {
            throw LocalWhisperError.executableNotFound
        }
        guard let modelURL = WhisperModelResolver.generalModelURL else {
            throw LocalWhisperError.modelNotFound
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingo-Whisper-Detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("language.log")
        let logCapture = BoundedProcessLog()
        logCapture.start()
        defer { logCapture.finish(to: logURL) }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path(percentEncoded: false),
            "-f", audioFileURL.path(percentEncoded: false),
            "-l", "auto",
            "-dl",
            "-d", "18000"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logCapture.pipe
        _ = try ProcessSupervisor.run(process, token: token, timeout: 120)
        logCapture.finish(to: logURL)

        let diagnosticText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0,
              let detection = parseWhisperLanguageDetection(from: diagnosticText),
              detection.confidence >= 0.50 else {
            return nil
        }
        return LanguageOption.whisperLanguageCode(detection.code)
    }

    private static func parseWhisperLanguageDetection(from text: String) -> (code: String, confidence: Double)? {
        let pattern = #"auto-detected language:\s*([a-z]{2})\s*\(p\s*=\s*([0-9.]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 3,
              let codeRange = Range(match.range(at: 1), in: text),
              let confidenceRange = Range(match.range(at: 2), in: text),
              let confidence = Double(text[confidenceRange]) else {
            return nil
        }
        return (String(text[codeRange]).lowercased(), confidence)
    }

    private static func transcribeSynchronously(
        audioFileURL: URL,
        languageCode: String,
        temporaryDirectory directory: URL,
        durationSeconds: Int? = nil,
        offsetMilliseconds: Int? = nil,
        beamSize: Int = 5,
        token: ProcessCancellationToken
    ) throws -> WhisperRunResult {
        try token.check()
        guard let executableURL = WhisperModelResolver.cliExecutableURL() else {
            throw LocalWhisperError.executableNotFound
        }
        guard let modelURL = WhisperModelResolver.generalModelURL else {
            throw LocalWhisperError.modelNotFound
        }

        let outputStem = directory.appendingPathComponent("transcript")
        let logURL = directory.appendingPathComponent("whisper.log")
        let logCapture = BoundedProcessLog()
        logCapture.start()
        defer { logCapture.finish(to: logURL) }

        let process = Process()
        process.executableURL = executableURL
        var arguments = [
            "-m", modelURL.path(percentEncoded: false),
            "-f", audioFileURL.path(percentEncoded: false),
            "-l", languageCode,
            "-otxt",
            "-of", outputStem.path(percentEncoded: false),
            "-nt",
            "-np",
            // 不携带上文，避免泰语等语种陷入重复幻觉循环
            "-mc", "0",
            "-bs", String(beamSize),
            "-ojf"
        ]
        if let offsetMilliseconds {
            arguments.append(contentsOf: ["-ot", String(offsetMilliseconds)])
        }
        if let durationSeconds {
            arguments.append(contentsOf: ["-d", String(durationSeconds * 1_000)])
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logCapture.pipe
        _ = try ProcessSupervisor.run(process, token: token)
        logCapture.finish(to: logURL)

        let diagnosticText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocalWhisperError.transcriptionFailed(diagnosticText.isEmpty ? "whisper-cli failed" : diagnosticText)
        }

        let transcriptURL = outputStem.appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: transcriptURL.path(percentEncoded: false)) else {
            throw LocalWhisperError.transcriptionFailed(diagnosticText.isEmpty ? "whisper-cli did not create a transcript file." : diagnosticText)
        }
        // 容错解码：分段硬切音频时，whisper 可能把泰语字符切在多字节中间，
        // 写出非法 UTF-8 字节。严格 String(contentsOf:encoding:.utf8) 会抛 NSFileReadCorruptFileError，
        // 让整条视频转写失败。改为有损解码（非法字节转 U+FFFD），后续合并里再清掉。
        let text = String(decoding: try Data(contentsOf: transcriptURL), as: UTF8.self)
        return WhisperRunResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func whisperLanguageCode(for language: LanguageOption) -> String {
        if language.id == LanguageOption.undetermined.id {
            return "auto"
        }
        return String(language.id.split(separator: "-").first ?? "auto")
    }

}

enum LocalWhisperError: LocalizedError {
    case executableNotFound
    case modelNotFound
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 whisper-cli。请用 Homebrew 安装：brew install whisper-cpp"
        case .modelNotFound:
            let dir = WhisperModelResolver.preferredModelDirectory.path(percentEncoded: false)
            return "未找到 Whisper 模型文件。请将 ggml-*.bin 模型文件放到：\(dir)"
        case let .transcriptionFailed(message):
            return "Whisper 转写失败：\(message)"
        }
    }
}
