import Foundation

private enum LocalWhisperConfiguration {
    static func cliExecutableURL() -> URL? {
        [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
            "/opt/local/bin/whisper-cpp",
            "/opt/homebrew/bin/main",
            "/usr/local/bin/main",
            "/opt/local/bin/main"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ?? executableURLFromPATH(named: ["whisper-cli", "whisper-cpp", "main"])
    }

    static func modelURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/VidLingo/Models/ggml-large-v3-turbo-q5_0.bin"),
            home.appendingPathComponent("Library/Application Support/VidLingo/Models/ggml-large-v3-turbo.bin"),
            home.appendingPathComponent("Library/Application Support/AirTranslate/Models/ggml-large-v3-turbo-q5_0.bin"),
            home.appendingPathComponent("Library/Application Support/AirTranslate/Models/ggml-large-v3-turbo.bin"),
            home.appendingPathComponent(".cache/whisper/ggml-large-v3-turbo-q5_0.bin"),
            home.appendingPathComponent(".cache/whisper/ggml-large-v3-turbo.bin"),
        ]
        return candidates.first { isUsableModel(at: $0) }
    }

    private static func isUsableModel(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value >= 500 * 1_024 * 1_024
    }

    private static func executableURLFromPATH(named executableNames: [String]) -> URL? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathDirectories {
            for executableName in executableNames {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        return nil
    }
}

enum LocalWhisperRunner {
    struct LanguageDetectionResult: Sendable {
        let language: LanguageOption
        let transcript: String
    }

    static func transcribe(audioFileURL: URL, language: LanguageOption) async throws -> String {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VidLingo-Whisper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            return try transcribeSynchronously(
                audioFileURL: audioFileURL,
                languageCode: whisperLanguageCode(for: language),
                temporaryDirectory: directory
            ).text
        }.value
    }

    static func detectLanguageWithTranscript(audioFileURL: URL) async throws -> LanguageDetectionResult? {
        try await Task.detached(priority: .utility) {
            var best: (language: LanguageOption, text: String, score: Double)?

            for candidate in detectionCandidates() {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VidLingo-Whisper-Language-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }

                let result = try transcribeSynchronously(
                    audioFileURL: audioFileURL,
                    languageCode: whisperLanguageCode(for: candidate),
                    temporaryDirectory: directory,
                    durationSeconds: 18
                )
                let score = detectionScore(for: result.text, language: candidate)
                if best == nil || score > best!.score {
                    best = (candidate, result.text, score)
                }
            }

            guard let best, best.score > 0 else { return nil }
            return LanguageDetectionResult(language: best.language, transcript: best.text)
        }.value
    }

    private static func transcribeSynchronously(
        audioFileURL: URL,
        languageCode: String,
        temporaryDirectory directory: URL,
        durationSeconds: Int? = nil
    ) throws -> (text: String, diagnostics: String) {
        guard let executableURL = LocalWhisperConfiguration.cliExecutableURL() else {
            throw LocalWhisperError.executableNotFound
        }
        guard let modelURL = LocalWhisperConfiguration.modelURL() else {
            throw LocalWhisperError.modelNotFound
        }

        let outputStem = directory.appendingPathComponent("transcript")
        let logURL = directory.appendingPathComponent("whisper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        var arguments = [
            "-m", modelURL.path,
            "-f", audioFileURL.path,
            "-l", languageCode,
            "-otxt",
            "-of", outputStem.path,
            "-nt",
            "-np"
        ]
        if let durationSeconds {
            arguments.append(contentsOf: ["-d", String(durationSeconds * 1_000)])
        }
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

        let diagnosticText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocalWhisperError.transcriptionFailed(diagnosticText.isEmpty ? "whisper-cli failed" : diagnosticText)
        }

        let transcriptURL = outputStem.appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            throw LocalWhisperError.transcriptionFailed(diagnosticText.isEmpty ? "whisper-cli did not create a transcript file." : diagnosticText)
        }
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), diagnosticText)
    }

    static func whisperLanguageCode(for language: LanguageOption) -> String {
        String(language.id.split(separator: "-").first ?? "auto")
    }

    private static func detectionCandidates() -> [LanguageOption] {
        ["ms-MY", "id-ID", "th-TH", "en-US"].compactMap { id in
            LanguageOption.supported.first { $0.id == id }
        }
    }

    private static func detectionScore(for text: String, language: LanguageOption) -> Double {
        let normalizedText = text.lowercased()
        let words = normalizedText
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard words.count >= 4 else { return -100 }

        var score = min(Double(words.count), 80)
        score -= Double(repeatedWordCount(in: words)) * 2.0
        score -= Double(repeatedLineCount(in: normalizedText)) * 5.0

        if language.id == "en-US" {
            let offTopicTerms = ["vehicle", "mms", "really good", "also very good", "check the link below"]
            for term in offTopicTerms where normalizedText.contains(term) {
                score -= 18
            }
            if repeatedPhraseCount(in: normalizedText, phrase: "if you want to use") >= 2 {
                score -= 35
            }
            if repeatedPhraseCount(in: normalizedText, phrase: "really good") >= 2 {
                score -= 25
            }
        }

        switch language.id {
        case "ms-MY", "id-ID":
            let regionalMarkers = ["nak", "boleh", "dia", "dekat", "sini", "air", "sabun", "cuci", "kotor", "bersih", "kalau"]
            score += Double(regionalMarkers.filter { normalizedText.contains($0) }.count) * 8.0
        case "th-TH":
            if text.unicodeScalars.contains(where: { (0x0E00...0x0E7F).contains(Int($0.value)) }) {
                score += 40
            }
        default:
            break
        }

        return score
    }

    private static func repeatedWordCount(in words: [String]) -> Int {
        guard words.count > 1 else { return 0 }
        var count = 0
        for index in 1..<words.count where words[index] == words[index - 1] {
            count += 1
        }
        return count
    }

    private static func repeatedLineCount(in text: String) -> Int {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(0, lines.count - Set(lines).count)
    }

    private static func repeatedPhraseCount(in text: String, phrase: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: phrase, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }
}

enum LocalWhisperError: LocalizedError {
    case executableNotFound
    case modelNotFound
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Local Whisper is not installed. Install whisper.cpp so whisper-cli, whisper-cpp, or main is available."
        case .modelNotFound:
            "Local Whisper model not found. Put ggml-large-v3-turbo-q5_0.bin in ~/Library/Application Support/VidLingo/Models."
        case let .transcriptionFailed(message):
            "Local Whisper transcription failed: \(message)"
        }
    }
}
