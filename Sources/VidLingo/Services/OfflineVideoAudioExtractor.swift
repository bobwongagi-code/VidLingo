import Foundation

enum OfflineVideoAudioExtractor {
    static func extractSpeechAudio(from videoURL: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try extractSpeechAudioSynchronously(from: videoURL)
        }.value
    }

    private static func extractSpeechAudioSynchronously(from videoURL: URL) throws -> URL {
        guard let ffmpegURL = ExecutableFinder.findExecutable(named: ["ffmpeg"]) else {
            throw OfflineVideoTranslationError.ffmpegNotFound
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingo-OfflineVideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let audioURL = directory.appendingPathComponent("speech.wav")
        let enhancedArguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", videoURL.path(percentEncoded: false),
            "-vn",
            // 高低通 + 响度标准化让人声更稳定；不加 afftdn 激进降噪，它会吃掉人声反而更糟
            "-af", "highpass=f=80,lowpass=f=8000,loudnorm=I=-16:TP=-1.5:LRA=11",
            "-ar", "16000",
            "-ac", "1",
            "-sample_fmt", "s16",
            audioURL.path(percentEncoded: false)
        ]
        if try runFFmpeg(ffmpegURL, arguments: enhancedArguments, directory: directory, logName: "ffmpeg-enhanced.log") {
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
        if try runFFmpeg(ffmpegURL, arguments: plainArguments, directory: directory, logName: "ffmpeg-plain.log") {
            return audioURL
        }

        let message = readLog(directory.appendingPathComponent("ffmpeg-enhanced.log"))
            + "\n"
            + readLog(directory.appendingPathComponent("ffmpeg-plain.log"))
        try? FileManager.default.removeItem(at: directory)
        throw OfflineVideoTranslationError.audioExtractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runFFmpeg(_ ffmpegURL: URL, arguments: [String], directory: URL, logName: String) throws -> Bool {
        let logURL = directory.appendingPathComponent(logName)
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func readLog(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func removeTemporaryAudio(_ audioURL: URL) {
        try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent())
    }

}

enum OfflineVideoTranslationError: LocalizedError {
    case ffmpegNotFound
    case audioExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            "ffmpeg not found. Install it with Homebrew before importing a video."
        case let .audioExtractionFailed(message):
            "Could not extract audio from video: \(message)"
        }
    }
}
