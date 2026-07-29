import Foundation

public enum WhisperModelValidator {
    private static let minimumHeaderBytes = 44
    private static let ggmlMagic = Data([0x6c, 0x6d, 0x67, 0x67])

    /// 校验 whisper.cpp GGML 模型的结构化头部，避免把任意大文件当成模型。
    public static func hasValidGGMLHeader(_ data: Data) -> Bool {
        guard data.count >= minimumHeaderBytes,
              data.prefix(4) == ggmlMagic else {
            return false
        }

        let values = (1...10).compactMap { index -> UInt32? in
            let offset = index * MemoryLayout<UInt32>.size
            guard offset + MemoryLayout<UInt32>.size <= data.count else { return nil }
            return data.withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }
        guard values.count == 10 else { return false }

        let nVocab = values[0]
        let nAudioContext = values[1]
        let nAudioState = values[2]
        let nAudioHeads = values[3]
        let nAudioLayers = values[4]
        let nTextContext = values[5]
        let nTextState = values[6]
        let nTextHeads = values[7]
        let nTextLayers = values[8]
        let nMels = values[9]

        return (10_000...200_000).contains(nVocab)
            && (100...10_000).contains(nAudioContext)
            && (256...4_096).contains(nAudioState)
            && (1...128).contains(nAudioHeads)
            && (1...128).contains(nAudioLayers)
            && (64...8_192).contains(nTextContext)
            && (256...4_096).contains(nTextState)
            && (1...128).contains(nTextHeads)
            && (1...128).contains(nTextLayers)
            && (40...256).contains(nMels)
    }
}
