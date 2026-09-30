import Foundation

enum FunASRConfiguration {
    static let endpoint = URL(string: "https://llm-ltudqs3p2y3jjvo5.ap-southeast-1.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
    // 沿用已有东南亚凭据项，不迁移或覆盖已保存的密钥。
    static let keychainService = "VidLingo.QwenSoutheastAsia"
}
