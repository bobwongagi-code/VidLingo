import Foundation

enum TranslationProviderID: String, CaseIterable, Identifiable, Sendable {
    case deepSeek
    case openAI
    case qwen
    case claudeCompatible
    case anthropic
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
            "OpenRouter / Claude"
        case .anthropic:
            "Anthropic / Claude"
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
            "qwen3.6-plus"
        case .claudeCompatible:
            "anthropic/claude-sonnet-4.5"
        case .anthropic:
            "claude-sonnet-4-5"
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
            "https://llm-nlx73tfv3mm6w67e.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .claudeCompatible:
            "https://openrouter.ai/api/v1/chat/completions"
        case .anthropic:
            "https://api.anthropic.com/v1/messages"
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
            "VidLingo.OpenRouterClaude"
        case .anthropic:
            "VidLingo.Anthropic"
        case .custom:
            "VidLingo.CustomLLM"
        }
    }

    var legacyKeychainServices: [String] {
        switch self {
        case .deepSeek:
            ["AirTranslate.OpenAI"]
        case .claudeCompatible:
            ["VidLingo.Claude"]
        default:
            []
        }
    }

    var usesAnthropicMessagesAPI: Bool {
        self == .anthropic
    }

    func capabilities(for model: String) -> TranslationProviderCapabilities {
        let normalizedModel = model.lowercased()
        let supportsVision: Bool
        switch self {
        case .qwen:
            supportsVision = normalizedModel.contains("-vl")
                || normalizedModel.hasPrefix("qwen-vl")
                || normalizedModel.hasPrefix("qwen3-vl")
        case .openAI:
            supportsVision = normalizedModel.contains("gpt-4o")
                || normalizedModel.contains("gpt-4.1")
                || normalizedModel.contains("gpt-5")
        case .claudeCompatible:
            supportsVision = normalizedModel.contains("claude-3")
                || normalizedModel.contains("claude-4")
                || normalizedModel.contains("claude-sonnet-4")
                || normalizedModel.contains("claude-opus-4")
                || normalizedModel.contains("claude-haiku-4")
        case .anthropic:
            supportsVision = normalizedModel.contains("claude-3")
                || normalizedModel.contains("claude-4")
                || normalizedModel.contains("claude-sonnet-4")
                || normalizedModel.contains("claude-opus-4")
                || normalizedModel.contains("claude-haiku-4")
        case .custom, .deepSeek:
            supportsVision = normalizedModel.contains("vision")
                || normalizedModel.contains("-vl")
                || normalizedModel.contains("gpt-4o")
                || normalizedModel.contains("gpt-4.1")
                || normalizedModel.contains("gpt-5")
        }
        return TranslationProviderCapabilities(
            supportsVision: supportsVision,
            isTranslationOnly: self == .qwen && normalizedModel.hasPrefix("qwen-mt-")
        )
    }
}

struct TranslationProviderCapabilities: Sendable, Equatable {
    let supportsVision: Bool
    let isTranslationOnly: Bool
}
