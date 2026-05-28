import Foundation

enum TranslationProviderID: String, CaseIterable, Identifiable, Sendable {
    case deepSeek
    case openAI
    case qwen
    case claudeCompatible
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepSeek:
            "DeepSeek"
        case .openAI:
            "OpenAI"
        case .qwen:
            "Qwen / 千问"
        case .claudeCompatible:
            "Claude"
        case .custom:
            "Custom"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek:
            "deepseek-v4-flash"
        case .openAI:
            "gpt-4o-mini"
        case .qwen:
            "qwen-plus"
        case .claudeCompatible:
            "claude-sonnet-4-5-20250929"
        case .custom:
            ""
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek:
            "https://api.deepseek.com/chat/completions"
        case .openAI:
            "https://api.openai.com/v1/chat/completions"
        case .qwen:
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .claudeCompatible:
            "https://openrouter.ai/api/v1/chat/completions"
        case .custom:
            ""
        }
    }

    var keychainService: String {
        switch self {
        case .deepSeek:
            "VidLingo.DeepSeek"
        case .openAI:
            "VidLingo.OpenAI"
        case .qwen:
            "VidLingo.Qwen"
        case .claudeCompatible:
            "VidLingo.Claude"
        case .custom:
            "VidLingo.CustomLLM"
        }
    }

    var legacyKeychainServices: [String] {
        switch self {
        case .deepSeek:
            ["VidLingo.OpenAI", "AirTranslate.OpenAI"]
        default:
            []
        }
    }
}
