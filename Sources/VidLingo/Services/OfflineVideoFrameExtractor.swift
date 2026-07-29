import AppKit
import AVFoundation
import Foundation

enum OfflineVideoFrameExtractor {
    static func extractProductContextFrames(
        from videoURL: URL,
        token: ProcessCancellationToken
    ) async throws -> [Data] {
        try await Task.detached(priority: .utility) {
            try token.check()
            let asset = AVURLAsset(url: videoURL)
            let generatorBox = ImageGeneratorBox(AVAssetImageGenerator(asset: asset))
            generatorBox.generator.appliesPreferredTrackTransform = true
            generatorBox.generator.maximumSize = CGSize(width: 640, height: 640)

            let duration: Double
            do {
                let loadedDuration = try await withTaskCancellationHandler {
                    try await AsyncOperationTimeout.run(timeout: 15) {
                        try await asset.load(.duration)
                    }
                } onCancel: {
                    asset.cancelLoading()
                }
                duration = CMTimeGetSeconds(loadedDuration)
            } catch ProcessSupervisorError.cancelled {
                throw ProcessSupervisorError.cancelled
            } catch ProcessSupervisorError.deadlineExceeded {
                throw ProcessSupervisorError.deadlineExceeded
            } catch {
                return []
            }
            let seconds = frameTimes(forDuration: duration)
            var frames = [Data]()

            for second in seconds {
                try token.check()
                let time = CMTime(seconds: second, preferredTimescale: 600)
                do {
                    if let cgImage = try await cgImage(from: generatorBox, at: time),
                       let data = jpegData(from: cgImage) {
                        frames.append(data)
                    }
                } catch ProcessSupervisorError.cancelled {
                    throw ProcessSupervisorError.cancelled
                } catch ProcessSupervisorError.deadlineExceeded {
                    throw ProcessSupervisorError.deadlineExceeded
                } catch {
                    // 单帧读取失败不阻断其他时间点，避免视觉增强拖垮主流程。
                }
            }
            return frames
        }.value
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

    private static func cgImage(from generatorBox: ImageGeneratorBox, at time: CMTime) async throws -> CGImage? {
        try await withTaskCancellationHandler {
            let result = try await AsyncOperationTimeout.run(timeout: 8) {
                try await generatorBox.generator.image(at: time)
            }
            return result.image
        } onCancel: {
            generatorBox.generator.cancelAllCGImageGeneration()
        }
    }

    private final class ImageGeneratorBox: @unchecked Sendable {
        let generator: AVAssetImageGenerator

        init(_ generator: AVAssetImageGenerator) {
            self.generator = generator
        }
    }
}
