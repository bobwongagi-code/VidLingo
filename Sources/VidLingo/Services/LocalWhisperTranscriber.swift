import AVFoundation
import CryptoKit
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

    // 泰语专精微调模型，仅泰语用；缺失时回退到通用模型。
    private static let thaiModelNames = [
        "ggml-pathumma-th-large-v3-q5_0.bin",
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
           let thaiModel = thaiModelURL {
            return thaiModel
        }
        return generalModelURL
    }

    static var generalModelURL: URL? {
        candidatePaths(for: generalModelNames).first(where: isUsableModel)
    }

    static var thaiModelURL: URL? {
        candidatePaths(for: thaiModelNames).first(where: isUsableModel)
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

    private struct WhisperRunResult {
        let text: String
        let meanTokenProbability: Double?
    }

    static func transcribe(audioFileURL: URL, language: LanguageOption) async throws -> String {
        if language.id == "th-TH" {
            let candidates = try await transcribeThaiCandidates(audioFileURL: audioFileURL)
            return TranscriptionQualityEvaluator.assess(candidates).selectedText
        }

        return try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VidLingo-Whisper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let languageCode = whisperLanguageCode(for: language)
            return try transcribeSynchronously(
                audioFileURL: audioFileURL,
                languageCode: languageCode,
                temporaryDirectory: directory
            ).text
        }.value
    }

    static func transcribeThaiCandidates(audioFileURL: URL) async throws -> [WhisperSegmentCandidates] {
        try await Task.detached(priority: .utility) {
            guard let duration = await audioDurationSeconds(audioFileURL: audioFileURL) else {
                throw LocalWhisperError.transcriptionFailed("Could not read audio duration.")
            }
            let segmentPlan = makeSegmentPlan(duration: duration)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VidLingo-Whisper-Candidates-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            var candidatesByIndex: [Int: [WhisperSegmentCandidate]] = [:]
            guard let generalModelURL = LocalWhisperConfiguration.generalModelURL else {
                throw LocalWhisperError.modelNotFound
            }

            func currentSegments() -> [WhisperSegmentCandidates] {
                segmentPlan.enumerated().map { index, segment in
                    WhisperSegmentCandidates(
                        index: index,
                        offset: segment.offset,
                        duration: segment.duration,
                        candidates: candidatesByIndex[index] ?? []
                    )
                }
            }

            guard let thaiModelURL = LocalWhisperConfiguration.thaiModelURL else {
                let generalCandidates = try transcribeCandidateSegmentsSynchronously(
                    audioFileURL: audioFileURL,
                    languageCode: "th",
                    segments: segmentPlan,
                    modelURL: generalModelURL,
                    profile: .generalBeam,
                    beamSize: 5,
                    temporaryDirectory: directory.appendingPathComponent("general", isDirectory: true)
                )
                for (index, candidate) in generalCandidates.enumerated() {
                    candidatesByIndex[index, default: []].append(candidate)
                }
                return currentSegments()
            }

            let specialistCandidates = try transcribeCandidateSegmentsSynchronously(
                audioFileURL: audioFileURL,
                languageCode: "th",
                segments: segmentPlan,
                modelURL: thaiModelURL,
                profile: .thaiSpecialistGreedy,
                beamSize: 1,
                temporaryDirectory: directory.appendingPathComponent("thai-specialist", isDirectory: true)
            )
            for (index, candidate) in specialistCandidates.enumerated() {
                candidatesByIndex[index, default: []].append(candidate)
            }

            let reviewIndexes = TranscriptionQualityEvaluator.generalReviewIndexes(for: currentSegments())
            guard !reviewIndexes.isEmpty else {
                return currentSegments()
            }

            let generalFingerprint = try modelFingerprint(for: generalModelURL)
            let reviewSegments = reviewIndexes.map { segmentPlan[$0] }
            let reviewCandidates = try transcribeCandidateSegmentsSynchronously(
                audioFileURL: audioFileURL,
                languageCode: "th",
                segments: reviewSegments,
                modelURL: generalModelURL,
                profile: .generalBeam,
                beamSize: 5,
                temporaryDirectory: directory.appendingPathComponent("general-review", isDirectory: true),
                modelFingerprint: generalFingerprint
            )
            for (index, candidate) in zip(reviewIndexes, reviewCandidates) {
                candidatesByIndex[index, default: []].append(candidate)
            }

            let remainingIndexes = segmentPlan.indices.filter { !reviewIndexes.contains($0) }
            if !remainingIndexes.isEmpty,
               TranscriptionQualityEvaluator.requiresFullGeneralReview(
                   currentSegments(),
                   reviewedIndexes: reviewIndexes
               ) {
                let remainingSegments = remainingIndexes.map { segmentPlan[$0] }
                let remainingCandidates = try transcribeCandidateSegmentsSynchronously(
                    audioFileURL: audioFileURL,
                    languageCode: "th",
                    segments: remainingSegments,
                    modelURL: generalModelURL,
                    profile: .generalBeam,
                    beamSize: 5,
                    temporaryDirectory: directory.appendingPathComponent("general-full", isDirectory: true),
                    modelFingerprint: generalFingerprint
                )
                for (index, candidate) in zip(remainingIndexes, remainingCandidates) {
                    candidatesByIndex[index, default: []].append(candidate)
                }
            }

            return currentSegments()
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
        initialPrompt: String? = nil,
        modelURL explicitModelURL: URL? = nil,
        beamSize: Int = 5
    ) throws -> WhisperRunResult {
        guard let executableURL = LocalWhisperConfiguration.cliExecutableURL() else {
            throw LocalWhisperError.executableNotFound
        }
        // 按语言选模型：泰语用专精微调，其他用通用模型
        guard let modelURL = explicitModelURL ?? LocalWhisperConfiguration.modelURL(for: languageCode) else {
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
        let jsonURL = outputStem.appendingPathExtension("json")
        return WhisperRunResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            meanTokenProbability: meanTokenProbability(from: jsonURL)
        )
    }

    private static func transcribeCandidateSegmentsSynchronously(
        audioFileURL: URL,
        languageCode: String,
        segments: [(offset: Double, duration: Double)],
        modelURL: URL,
        profile: WhisperDecoderProfile,
        beamSize: Int,
        temporaryDirectory directory: URL,
        modelFingerprint explicitModelFingerprint: String? = nil
    ) throws -> [WhisperSegmentCandidate] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fingerprint: String
        if let explicitModelFingerprint {
            fingerprint = explicitModelFingerprint
        } else {
            fingerprint = try modelFingerprint(for: modelURL)
        }

        final class SharedState: @unchecked Sendable {
            let lock = NSLock()
            var results: [Int: WhisperSegmentCandidate] = [:]
            var firstError: Error?
        }
        let state = SharedState()
        let maxConcurrent = 2
        var batchStart = 0

        while batchStart < segments.count {
            let batchEnd = min(batchStart + maxConcurrent, segments.count)
            let batchSize = batchEnd - batchStart
            let currentBatchStart = batchStart
            DispatchQueue.concurrentPerform(iterations: batchSize) { batchIndex in
                let index = currentBatchStart + batchIndex
                let segment = segments[index]
                let segmentDirectory = directory.appendingPathComponent("seg-\(index)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
                    let result = try transcribeSynchronously(
                        audioFileURL: audioFileURL,
                        languageCode: languageCode,
                        temporaryDirectory: segmentDirectory,
                        durationSeconds: Int(ceil(segment.duration)),
                        offsetMilliseconds: Int((segment.offset * 1_000).rounded()),
                        modelURL: modelURL,
                        beamSize: beamSize
                    )
                    let candidate = WhisperSegmentCandidate(
                        profile: profile,
                        offset: segment.offset,
                        duration: segment.duration,
                        text: result.text,
                        meanTokenProbability: result.meanTokenProbability,
                        modelFileName: modelURL.lastPathComponent,
                        modelFingerprint: fingerprint
                    )
                    state.lock.lock()
                    state.results[index] = candidate
                    state.lock.unlock()
                } catch {
                    state.lock.lock()
                    if state.firstError == nil { state.firstError = error }
                    state.lock.unlock()
                }
            }
            if let error = state.firstError { throw error }
            batchStart = batchEnd
        }

        return segments.indices.compactMap { state.results[$0] }
    }

    private static func makeSegmentPlan(duration: Double) -> [(offset: Double, duration: Double)] {
        guard duration > 25 else { return [(0, duration)] }
        let chunkSeconds = 20.0
        let stepSeconds = 18.0
        var segments: [(offset: Double, duration: Double)] = []
        var offset = 0.0
        while offset < duration {
            segments.append((offset, min(chunkSeconds, duration - offset)))
            offset += stepSeconds
        }
        return segments
    }

    private static func meanTokenProbability(from jsonURL: URL) -> Double? {
        guard let data = try? Data(contentsOf: jsonURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcriptions = root["transcription"] as? [[String: Any]] else {
            return nil
        }
        let probabilities = transcriptions.flatMap { transcription in
            (transcription["tokens"] as? [[String: Any]] ?? []).compactMap { $0["p"] as? Double }
        }
        guard !probabilities.isEmpty else { return nil }
        return probabilities.reduce(0, +) / Double(probabilities.count)
    }

    private static func modelFingerprint(for modelURL: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: modelURL)
        defer { try? file.close() }
        var hasher = SHA256()
        while true {
            let data = try file.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func audioDurationSeconds(audioFileURL: URL) async -> Double? {
        let asset = AVURLAsset(url: audioFileURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
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
