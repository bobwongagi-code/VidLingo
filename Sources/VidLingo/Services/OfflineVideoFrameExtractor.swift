import AppKit
import AVFoundation
import Foundation

enum OfflineVideoFrameExtractor {
    static func extractProductContextFrames(from videoURL: URL) async -> [Data] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)

            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let seconds = frameTimes(forDuration: duration)
            var frames = [Data]()

            for second in seconds {
                let time = CMTime(seconds: second, preferredTimescale: 600)
                if let cgImage = await cgImage(from: generator, at: time),
                   let data = jpegData(from: cgImage) {
                    frames.append(data)
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

    private static func cgImage(from generator: AVAssetImageGenerator, at time: CMTime) async -> CGImage? {
        guard let result = try? await generator.image(at: time) else { return nil }
        return result.image
    }
}
