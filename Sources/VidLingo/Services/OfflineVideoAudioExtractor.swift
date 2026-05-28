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
        let logURL = directory.appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", videoURL.path,
            "-vn",
            "-ar", "16000",
            "-ac", "1",
            "-sample_fmt", "s16",
            audioURL.path
        ]

        process.standardOutput = FileHandle.nullDevice
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "ffmpeg failed"
            try? FileManager.default.removeItem(at: directory)
            throw OfflineVideoTranslationError.audioExtractionFailed(message)
        }

        return audioURL
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
