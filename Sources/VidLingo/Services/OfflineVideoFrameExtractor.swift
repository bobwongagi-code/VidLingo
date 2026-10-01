import AppKit
import AVFoundation
import Foundation

enum OfflineVideoFrameExtractor {
    static func extractProductContextFrames(
        from videoURL: URL,
        token: ProcessCancellationToken
    ) async throws -> [Data] {
        let task: Task<[Data], Error> = Task.detached(priority: .utility) {
            try token.check()
            let asset = AVURLAsset(url: videoURL)
            let generatorBox = ImageGeneratorBox(AVAssetImageGenerator(asset: asset))
            generatorBox.generator.appliesPreferredTrackTransform = true
            generatorBox.generator.maximumSize = CGSize(width: 640, height: 640)

            let duration: Double
            do {
                let loadedDuration = try await AsyncOperationTimeout.run(
                    timeout: 15,
                    token: token,
                    onCancel: { asset.cancelLoading() }
                ) {
                    try await asset.load(.duration)
                }
                duration = CMTimeGetSeconds(loadedDuration)
            } catch {
                try Self.rethrowFatalFrameReadError(error)
                return []
            }
            let seconds = frameTimes(forDuration: duration)
            var frames = [Data]()

            for second in seconds {
                try token.check()
                let time = CMTime(seconds: second, preferredTimescale: 600)
                do {
                    if let cgImage = try await cgImage(from: generatorBox, at: time, token: token),
                       let data = jpegData(from: cgImage) {
                        frames.append(data)
                    }
                } catch {
                    try Self.rethrowFatalFrameReadError(error)
                    // 单帧读取失败不阻断其他时间点，避免视觉增强拖垮主流程。
                }
            }
            return frames
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            token.cancel()
            task.cancel()
        }
    }

    static func rethrowFatalFrameReadError(_ error: Error) throws {
        if error is CancellationError {
            throw ProcessSupervisorError.cancelled
        }
        guard let processError = error as? ProcessSupervisorError else { return }
        switch processError {
        case .processTimedOut:
            return
        case .cancelled, .deadlineExceeded:
            throw processError
        }
    }

    private static func frameTimes(forDuration duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else {
            return [0.4, 1.2, 2.0]
        }

        let frameCount = min(12, max(3, Int(ceil(duration / 5.0))))
        let step = duration / Double(frameCount + 1)
        return (1...frameCount).map { index in
            min(max(step * Double(index), 0.35), max(0.35, duration - 0.35))
        }
    }

    private static func jpegData(from cgImage: CGImage) -> Data? {
        let image = NSImage(cgImage: cgImage, size: .zero)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    private static func cgImage(
        from generatorBox: ImageGeneratorBox,
        at time: CMTime,
        token: ProcessCancellationToken
    ) async throws -> CGImage? {
        let result = try await AsyncOperationTimeout.run(
            timeout: 8,
            token: token,
            onCancel: { generatorBox.generator.cancelAllCGImageGeneration() }
        ) {
            try await generatorBox.generator.image(at: time)
        }
        return result.image
    }

    private final class ImageGeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator

        init(_ generator: AVAssetImageGenerator) {
            self.generator = generator
        }
    }
}
