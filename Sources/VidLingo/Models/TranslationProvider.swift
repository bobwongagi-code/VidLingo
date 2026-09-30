import Foundation

enum TranslationProviderID: String, CaseIterable, Identifiable, Sendable {
    case rootify
    case deepSeek
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rootify:
            "Rootify 公司服务"
        case .deepSeek:
            "DeepSeek"
        case .custom:
            "Custom"
        }
    }

    var defaultModel: String {
        switch self {
        case .rootify:
            "gpt-5.6-luna"
        case .deepSeek:
            "deepseek-v4-flash"
        case .custom:
            ""
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .rootify:
            "https://rootifyaiapi.rootifyglobal.com/v1/chat/completions"
        case .deepSeek:
            "https://api.deepseek.com/chat/completions"
        case .custom:
            ""
        }
    }

    var keychainService: String {
        switch self {
        case .rootify:
            "VidLingo.Rootify"
        case .deepSeek:
            "VidLingo.DeepSeek"
        case .custom:
            "VidLingo.CustomLLM"
        }
    }

    var legacyKeychainServices: [String] {
        switch self {
        case .deepSeek:
            ["AirTranslate.OpenAI"]
        default:
            []
        }
    }

    func capabilities(for model: String) -> TranslationProviderCapabilities {
        let normalizedModel = model.lowercased()
        let supportsVision: Bool
        switch self {
        case .rootify:
            supportsVision = normalizedModel.contains("gpt-4o")
                || normalizedModel.contains("gpt-4.1")
                || normalizedModel.contains("gpt-5")
        case .custom, .deepSeek:
            supportsVision = normalizedModel.contains("vision")
                || normalizedModel.contains("-vl")
                || normalizedModel.contains("gpt-4o")
                || normalizedModel.contains("gpt-4.1")
                || normalizedModel.contains("gpt-5")
        }
        return TranslationProviderCapabilities(
            supportsVision: supportsVision
        )
    }
}

struct TranslationProviderCapabilities: Sendable, Equatable {
    let supportsVision: Bool
}
