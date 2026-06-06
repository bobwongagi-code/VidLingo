import AVFoundation
import Foundation
import VidLingoCore

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

    // 通用模型文件名，按能力从高到低
    private static let generalModelNames = [
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

    // 泰语专精微调模型（biodatlab/whisper-th-large-v3-combined），仅泰语用，
    // 因为它跑其他语言会更差。找不到时回退到通用模型。
    private static let thaiModelNames = [
        "ggml-th-large-v3-q5_0.bin",
        "ggml-th-large-v3-combined-q5_0.bin",
        "ggml-th-large-v3.bin",
    ]

    // 模型目录搜索顺序
    private static var modelDirs: [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? home.appendingPathComponent("Library/Application Support")
        return [
            appSupportURL.appendingPathComponent("VidLingo/Models"),
            appSupportURL.appendingPathComponent("AirTranslate/Models"),
            appSupportURL.appendingPathComponent("whisper/Models"),
            home.appendingPathComponent(".cache/whisper"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper.cpp"),
            URL(fileURLWithPath: "/usr/local/share/whisper.cpp"),
        ]
    }

    private static func candidatePaths(for names: [String]) -> [URL] {
        var candidates: [URL] = []
        for dir in modelDirs {
            for name in names {
                candidates.append(dir.appendingPathComponent(name))
            }
        }
        return candidates
    }

    // 所有通用候选路径（启动检查模型是否存在时用）
    static var modelCandidatePaths: [URL] {
        candidatePaths(for: generalModelNames)
    }

    /// 按语言选模型：泰语优先用专精微调，其他语言（含语言检测 nil）用通用模型；
    /// 泰语微调缺失时回退到通用模型。
    static func modelURL(for languageCode: String? = nil) -> URL? {
        if languageCode == "th",
           let thaiModel = candidatePaths(for: thaiModelNames).first(where: isUsableModel) {
            return thaiModel
        }
        return candidatePaths(for: generalModelNames).first(where: isUsableModel)
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

            if language.id == "th-TH",
               let duration = await audioDurationSeconds(audioFileURL: audioFileURL),
               duration > 25 {
                return try transcribeSegmentedSynchronously(
                    audioFileURL: audioFileURL,
                    languageCode: "th",
                    duration: duration,
                    temporaryDirectory: directory
                )
            }

            // 短视频（含 ≤22s 的泰语）走单次转写，泰语同样传入中性 initial prompt 锚定泰文，
            // 避免开头漂移成英语幻觉（与分段路径保持一致）
            let languageCode = whisperLanguageCode(for: language)
            return try transcribeSynchronously(
                audioFileURL: audioFileURL,
                languageCode: languageCode,
                temporaryDirectory: directory,
                initialPrompt: initialPrompt(for: languageCode)
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
        durationSeconds: Int? = nil,
        offsetMilliseconds: Int? = nil,
        initialPrompt: String? = nil
    ) throws -> (text: String, diagnostics: String) {
        guard let executableURL = LocalWhisperConfiguration.cliExecutableURL() else {
            throw LocalWhisperError.executableNotFound
        }
        // 按语言选模型：泰语用专精微调，其他用通用模型
        guard let modelURL = LocalWhisperConfiguration.modelURL(for: languageCode) else {
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
            "-np",
            // 不携带上文，避免泰语等语种陷入重复幻觉循环
            "-mc", "0"
        ]
        if let offsetMilliseconds {
            arguments.append(contentsOf: ["-ot", String(offsetMilliseconds)])
        }
        if let durationSeconds {
            arguments.append(contentsOf: ["-d", String(durationSeconds * 1_000)])
        }
        if let initialPrompt, !initialPrompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", initialPrompt])
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
        // 容错解码：分段硬切音频时，whisper 可能把泰语字符切在多字节中间，
        // 写出非法 UTF-8 字节。严格 String(contentsOf:encoding:.utf8) 会抛 NSFileReadCorruptFileError，
        // 让整条视频转写失败。改为有损解码（非法字节转 U+FFFD），后续合并里再清掉。
        let text = String(decoding: try Data(contentsOf: transcriptURL), as: UTF8.self)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), diagnosticText)
    }

    private static func transcribeSegmentedSynchronously(
        audioFileURL: URL,
        languageCode: String,
        duration: Double,
        temporaryDirectory directory: URL
    ) throws -> String {
        // 20s 分段：比原 15s 减少分段数，离 whisper 30s 危险窗口还有 10s 余量，质量不受影响
        let chunkSeconds = 20.0
        let overlapSeconds = 2.0
        let stepSeconds = chunkSeconds - overlapSeconds

        // 预算所有分段
        var segmentsMut: [(offset: Double, duration: Double)] = []
        var offset = 0.0
        while offset < duration {
            segmentsMut.append((offset, min(chunkSeconds, duration - offset)))
            offset += stepSeconds
        }

        let segments = segmentsMut
        let segmentCount = segments.count
        // 最多 2 路并发：M4 Air 16GB 内存足够同时加载两份模型（~2.2GB），
        // 避免更高并发争抢 ANE/GPU 反而变慢
        let maxConcurrent = 2
        // 用 class 包装共享状态，避免 Swift 6 Sendable 闭包捕获 mutable var 的警告
        final class SharedState: @unchecked Sendable {
            let lock = NSLock()
            var results = [(index: Int, text: String)]()
            var firstError: Error?
        }
        let state = SharedState()

        // 分批并发，每批最多 maxConcurrent 个
        var batchStart = 0
        while batchStart < segmentCount {
            let batchEnd = min(batchStart + maxConcurrent, segmentCount)
            let batchSize = batchEnd - batchStart
            let currentBatchStart = batchStart

            DispatchQueue.concurrentPerform(iterations: batchSize) { i in
                let idx = currentBatchStart + i
                let seg = segments[idx]
                // 每个分段用独立子目录，避免 transcript.txt 互相覆盖
                let segDir = directory.appendingPathComponent("seg-\(idx)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
                    let result = try transcribeSynchronously(
                        audioFileURL: audioFileURL,
                        languageCode: languageCode,
                        temporaryDirectory: segDir,
                        durationSeconds: Int(ceil(seg.duration)),
                        offsetMilliseconds: Int((seg.offset * 1_000).rounded()),
                        initialPrompt: initialPrompt(for: languageCode)
                    )
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.lock.lock()
                    if !text.isEmpty { state.results.append((idx, text)) }
                    state.lock.unlock()
                } catch {
                    state.lock.lock()
                    if state.firstError == nil { state.firstError = error }
                    state.lock.unlock()
                }
            }

            // 任何一段失败则整体失败
            if let error = state.firstError { throw error }
            batchStart = batchEnd
        }

        // 按分段顺序排列后合并
        let segmentTexts = state.results.sorted { $0.index < $1.index }.map(\.text)
        return mergeSegmentTexts(segmentTexts)
    }

    private static func mergeSegmentTexts(_ segmentTexts: [String]) -> String {
        var merged = ""
        for rawText in segmentTexts {
            // 切片边界常把泰语字符截断成非法字符 U+FFFD（�），先清掉
            let text = rawText
                .replacingOccurrences(of: "\u{FFFD}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if merged.isEmpty {
                merged = text
                continue
            }
            // 整段已被包含（如最后一小段是上一段尾部的重复）→ 跳过
            let normalizedMerged = TranscriptTextProcessor.normalizedForComparison(merged)
            let normalizedText = TranscriptTextProcessor.normalizedForComparison(text)
            if normalizedMerged.contains(normalizedText) { continue }
            // 相邻段有 ~2s 重叠：找 merged 末尾与 text 开头的最长精确重叠，去掉重复部分再拼接。
            // 重叠 >0 说明是词/短语中途接续，直接拼（泰语无空格，加空格会拆词）；
            // 重叠 =0 是硬边界，补一个空格分隔。
            let overlap = longestBoundaryOverlap(merged, text)
            if overlap > 0 {
                let appended = String(text.dropFirst(overlap))
                guard !appended.isEmpty else { continue }
                merged += appended
            } else {
                merged += " " + text
            }
        }
        return merged
    }

    /// 求 a 的后缀与 b 的前缀的最长相等长度（字符级，泰语无空格也适用）。
    /// 限制搜索窗口（重叠约 2s），并要求最小长度，避免短串误配。
    private static func longestBoundaryOverlap(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var k = min(aChars.count, bChars.count, 120)
        while k >= 8 {
            if Array(aChars.suffix(k)) == Array(bChars.prefix(k)) {
                return k
            }
            k -= 1
        }
        return 0
    }

    private static func audioDurationSeconds(audioFileURL: URL) async -> Double? {
        let asset = AVURLAsset(url: audioFileURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func initialPrompt(for languageCode: String) -> String? {
        switch languageCode {
        case "th":
            // 仅用一句中性、流畅的泰语把解码器锚定在泰文，避免开头漂移成英语幻觉。
            // 刻意不带任何商品品类词、带货词或性别敬语，否则会把所有泰语视频
            // 往该方向拉偏，非对应内容的视频会明显变差；Whisper 也可能把这些词回吐进转写。
            "ต่อไปนี้เป็นคลิปวิดีโอภาษาไทย"
        default:
            nil
        }
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
