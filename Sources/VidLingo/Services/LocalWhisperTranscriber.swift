import Foundation

enum LocalWhisperConfiguration {
    static func cliExecutableURL() -> URL? {
        ExecutableFinder.findExecutable(
            named: ["whisper-cli", "whisper-cpp", "main"],
            commonDirectories: [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/opt/local/bin",
                "/opt/homebrew/Cellar/whisper-cpp/1.8.4/bin"
            ]
        )
    }

    // 所有候选模型路径，按优先级排序
    static var modelCandidatePaths: [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        // Application Support 目录（优先用 FileManager API，避免路径拼写问题）
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? home.appendingPathComponent("Library/Application Support")

        // 常用模型文件名，按能力从高到低
        let modelNames = [
            "ggml-large-v3-turbo-q5_0.bin",
            "ggml-large-v3-turbo-q8_0.bin",
            "ggml-large-v3-turbo.bin",
            "ggml-large-v3-q5_0.bin",
            "ggml-large-v3.bin",
            "ggml-large-v2-q5_0.bin",
            "ggml-large-v2.bin",
            "ggml-medium-q5_0.bin",
            "ggml-medium.bin",
            "ggml-small-q5_1.bin",
            "ggml-small.bin",
            "ggml-base.bin",
            "ggml-tiny.bin",
        ]

        // 模型目录搜索顺序
        let modelDirs: [URL] = [
            appSupportURL.appendingPathComponent("VidLingo/Models"),
            appSupportURL.appendingPathComponent("AirTranslate/Models"),
            appSupportURL.appendingPathComponent("whisper/Models"),
            home.appendingPathComponent(".cache/whisper"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper.cpp"),
            URL(fileURLWithPath: "/usr/local/share/whisper.cpp"),
        ]

        var candidates: [URL] = []
        for dir in modelDirs {
            for name in modelNames {
                candidates.append(dir.appendingPathComponent(name))
            }
        }
        return candidates
    }

    static func modelURL() -> URL? {
        modelCandidatePaths.first { isUsableModel(at: $0) }
    }

    // 用于报错时显示给用户的首选放置路径
    static var preferredModelDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("VidLingo/Models")
    }

    private static func isUsableModel(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        ),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        // 放宽到 30 MB：tiny 模型约 75 MB，base 约 142 MB，最小的量化模型也超过 30 MB
        return size.int64Value >= 30 * 1_024 * 1_024
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
            if let detectedLanguage = try detectLanguageSynchronously(audioFileURL: audioFileURL) {
                return LanguageDetectionResult(language: detectedLanguage, transcript: "")
            }

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

    private static func detectLanguageSynchronously(audioFileURL: URL) throws -> LanguageOption? {
        guard let executableURL = LocalWhisperConfiguration.cliExecutableURL() else {
            throw LocalWhisperError.executableNotFound
        }
        guard let modelURL = LocalWhisperConfiguration.modelURL() else {
            throw LocalWhisperError.modelNotFound
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingo-Whisper-Detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("language.log")
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

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
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

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
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        var arguments = [
            "-m", modelURL.path(percentEncoded: false),
            "-f", audioFileURL.path(percentEncoded: false),
            "-l", languageCode,
            "-otxt",
            "-of", outputStem.path(percentEncoded: false),
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
        guard FileManager.default.fileExists(atPath: transcriptURL.path(percentEncoded: false)) else {
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
            return "未找到 whisper-cli。请用 Homebrew 安装：brew install whisper-cpp"
        case .modelNotFound:
            let dir = LocalWhisperConfiguration.preferredModelDirectory.path(percentEncoded: false)
            return "未找到 Whisper 模型文件。请将 ggml-*.bin 模型文件放到：\(dir)"
        case let .transcriptionFailed(message):
            return "Whisper 转写失败：\(message)"
        }
    }
}
