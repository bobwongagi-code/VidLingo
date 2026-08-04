import Foundation

enum OfflineVideoAudioExtractor {
    static func extractSpeechAudio(
        from videoURL: URL,
        token: ProcessCancellationToken
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try extractSpeechAudioSynchronously(from: videoURL, token: token)
        }.value
    }

    private static func extractSpeechAudioSynchronously(
        from videoURL: URL,
        token: ProcessCancellationToken
    ) throws -> URL {
        try token.check()
        guard let ffmpegURL = ExecutableFinder.findExecutable(named: ["ffmpeg"]) else {
            throw OfflineVideoTranslationError.ffmpegNotFound
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingo-OfflineVideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keepsAudioDirectory = false
        defer {
            if !keepsAudioDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let audioURL = directory.appendingPathComponent("speech.wav")
        let enhancedArguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", videoURL.path(percentEncoded: false),
            "-vn",
            // 高低通 + 响度标准化让人声更稳定；不加 afftdn 激进降噪，它会吃掉人声反而更糟。
            // 不补开头静音：实测 adelay 会让泰语首段冒出词间空格，而开头漂移已由中性 initial prompt 解决。
            "-af", "highpass=f=80,lowpass=f=8000,loudnorm=I=-16:TP=-1.5:LRA=11",
            "-ar", "16000",
            "-ac", "1",
            "-sample_fmt", "s16",
            audioURL.path(percentEncoded: false)
        ]
        if try runFFmpeg(ffmpegURL, arguments: enhancedArguments, directory: directory, logName: "ffmpeg-enhanced.log", token: token) {
            try validateAudioSize(audioURL)
            keepsAudioDirectory = true
            return audioURL
        }

        let plainArguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", videoURL.path(percentEncoded: false),
            "-vn",
            "-ar", "16000",
            "-ac", "1",
            "-sample_fmt", "s16",
            audioURL.path(percentEncoded: false)
        ]
        if try runFFmpeg(ffmpegURL, arguments: plainArguments, directory: directory, logName: "ffmpeg-plain.log", token: token) {
            try validateAudioSize(audioURL)
            keepsAudioDirectory = true
            return audioURL
        }

        let message = readLog(directory.appendingPathComponent("ffmpeg-enhanced.log"))
            + "\n"
            + readLog(directory.appendingPathComponent("ffmpeg-plain.log"))
        throw OfflineVideoTranslationError.audioExtractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runFFmpeg(
        _ ffmpegURL: URL,
        arguments: [String],
        directory: URL,
        logName: String,
        token: ProcessCancellationToken
    ) throws -> Bool {
        let logURL = directory.appendingPathComponent(logName)
        let logCapture = BoundedProcessLog()
        logCapture.start()
        defer { logCapture.finish(to: logURL) }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logCapture.pipe
        let status = try ProcessSupervisor.run(process, token: token)
        return status == 0
    }

    private static func readLog(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let limitedData = data.suffix(32 * 1024)
        return String(decoding: limitedData, as: UTF8.self)
    }

    private static func validateAudioSize(_ audioURL: URL) throws {
        let size = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0, size <= FunASRTranscriber.maxAudioBytes else {
            throw OfflineVideoTranslationError.audioTooLarge
        }
    }

    static func removeTemporaryAudio(_ audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent())
    }

}

enum OfflineVideoTranslationError: LocalizedError {
    case cloudAudioConsentRequired
    case ffmpegNotFound
    case audioExtractionFailed(String)
    case audioTooLarge
    case invalidVideo
    case videoTooLarge
    case videoTooLong
    case videoTooLongForFunASR

    var errorDescription: String? {
        switch self {
        case .cloudAudioConsentRequired:
            AppText.cloudAudioConsentRequired
        case .ffmpegNotFound:
            "ffmpeg not found. Install it with Homebrew before importing a video."
        case let .audioExtractionFailed(message):
            "Could not extract audio from video: \(message)"
        case .audioTooLarge:
            "提取出的音频超过允许大小，已停止处理。"
        case .invalidVideo:
            "视频无法读取或没有有效时长。"
        case .videoTooLarge:
            "视频文件超过允许大小，已停止处理。"
        case .videoTooLong:
            "视频超过允许时长，已停止处理。"
        case .videoTooLongForFunASR:
            "视频超过 Fun-ASR 支持的 5 分钟，已停止处理。"
        }
    }
}
