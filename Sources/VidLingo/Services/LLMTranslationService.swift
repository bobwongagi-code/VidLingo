import Foundation

actor LLMTranslationService {
    func translateShortVideoTranscript(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        productContext: String,
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String
    ) async throws -> String {
        guard !text.isEmpty else { return text }

        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw LLMTranslationError.missingModel
        }

        guard let apiKey = try TranslationAPIKeyStore.readAPIKey(for: provider), !apiKey.isEmpty else {
            throw LLMTranslationError.missingAPIKey(provider.title)
        }

        let endpointText = provider == .custom ? customBaseURL : provider.defaultBaseURL
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)),
              endpoint.scheme?.hasPrefix("http") == true else {
            throw LLMTranslationError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        request.httpBody = try JSONEncoder().encode(
            chatCompletionRequest(
                text,
                source: source,
                target: target,
                productContext: productContext,
                provider: provider,
                model: model
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMTranslationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(ChatErrorResponse.self, from: data)
            throw LLMTranslationError.requestFailed(
                provider: provider.title,
                statusCode: httpResponse.statusCode,
                message: errorResponse?.error.message
            )
        }

        let outputText = try JSONDecoder()
            .decode(ChatCompletionResponse.self, from: data)
            .firstOutputText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !outputText.isEmpty else {
            throw LLMTranslationError.emptyOutput(provider.title)
        }
        return outputText
    }

    private func chatCompletionRequest(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        productContext: String,
        provider: TranslationProviderID,
        model: String
    ) -> ChatCompletionRequest {
        if provider == .qwen, model.lowercased().hasPrefix("qwen-mt-") {
            return ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(role: "user", content: text)
                ],
                stream: false,
                temperature: nil,
                maxTokens: nil,
                translationOptions: TranslationOptions(
                    sourceLanguage: "auto",
                    targetLanguage: qwenMTLanguageName(for: target),
                    terms: qwenMTTerms,
                    domains: qwenMTDomainPrompt(productContext),
                    translationMemory: qwenMTTranslationMemory
                )
            )
        }

        let context = productContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = """
        源语言：\(source.localizedTitle)
        目标语言：\(target.localizedTitle)
        视频类型：TikTok / 短视频带货口播
        商品类型：\(context.isEmpty ? "未知商品，请根据原文谨慎判断" : context)

        请把下面的 Whisper 转写原文翻译成自然、易懂的简体中文。

        原文：
        \(text)
        """

        return ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt)
            ],
            stream: false,
            temperature: 0.2,
            maxTokens: 2500,
            translationOptions: nil
        )
    }

    private func qwenMTLanguageName(for language: LanguageOption) -> String {
        switch language.id {
        case "zh-CN":
            "Chinese"
        case "en-US":
            "English"
        case "ms-MY":
            "Malay"
        case "id-ID":
            "Indonesian"
        case "th-TH":
            "Thai"
        case "ko-KR":
            "Korean"
        case "ja-JP":
            "Japanese"
        case "es-ES":
            "Spanish"
        case "fr-FR":
            "French"
        case "de-DE":
            "German"
        default:
            language.title
        }
    }

    private func qwenMTDomainPrompt(_ productContext: String) -> String? {
        let context = productContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let productLine = context.isEmpty
            ? ""
            : "\nProduct context: \(context)"
        return """
        This is a Southeast Asian e-commerce live streaming script from TikTok Shop or Shopee.
        The speaker is a product host demonstrating household or consumer products while talking.
        Translation requirements:
        1. Use casual, conversational Chinese suitable for short video subtitles.
        2. Preserve short sentence rhythm, do not merge short sentences into long ones.
        3. Preserve repeated phrases that reflect live demonstration rhythm.
        4. Translate filler words like lah, kan, tau, and haa into natural Chinese equivalents like 嘛, 对吧, 哦, and 哈.
        5. If an opening noun contradicts the product being demonstrated, translate it as a neutral product reference like 就这款 instead of its literal meaning.
        6. Translate the call-to-action sentence at the end with clear purchase intent.
        \(productLine)
        """
    }

    private var qwenMTTerms: [TranslationTerm] {
        [
            .init(source: "back kuning", target: "黄色购物车"),
            .init(source: "beg kuning", target: "黄色购物车"),
            .init(source: "jebag kuning", target: "黄色购物车"),
            .init(source: "bakul kuning", target: "黄色购物车"),
            .init(source: "keranjang kuning", target: "黄色购物车"),
            .init(source: "link di bawah", target: "下方链接"),
            .init(source: "Bruce", target: "刷头"),
            .init(source: "brus", target: "刷头"),
            .init(source: "nozzle", target: "吸嘴"),
            .init(source: "kipas", target: "风扇"),
            .init(source: "kipar", target: "风扇"),
            .init(source: "karpet", target: "地毯"),
            .init(source: "kapek", target: "地毯"),
            .init(source: "tilam", target: "床垫")
        ]
    }

    private var qwenMTTranslationMemory: [TranslationMemoryEntry] {
        [
            .init(
                source: "Klik back kuning untuk beli sekarang.",
                target: "点击黄色购物车立即下单。"
            ),
            .init(
                source: "Haa senang kan?",
                target: "哈，简单吧？"
            ),
            .init(
                source: "Yang ni memang terbaik.",
                target: "这款真的是最好的。"
            ),
            .init(
                source: "Harga dia pun murah.",
                target: "价格也很便宜。"
            ),
            .init(
                source: "Tengok ni, senang je.",
                target: "你看，很简单的。"
            )
        ]
    }

    private var systemPrompt: String {
        if let url = Bundle.main.url(forResource: "TranslationSystemPrompt", withExtension: "md"),
           let prompt = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            return prompt
        }
        return fallbackSystemPrompt
    }

    private var fallbackSystemPrompt: String {
        """
        你是一个跨境电商短视频字幕翻译助手。

        输入是一段由 Whisper 转写得到的短视频口播原文，可能来自泰语、马来语、印尼语或英语。内容通常是 TikTok / 短视频带货，涉及产品展示、功能介绍、价格、优惠、使用方法、卖点、口语表达。

        你的任务是把它翻译成自然、易懂的简体中文，帮助中文用户快速理解视频在卖什么、产品有什么功能、主播在强调什么。

        要求：
        1. 不要逐字硬翻，要按中文短视频/电商口播习惯翻译。
        2. 保留原意，不要编造价格、品牌、功效、参数或主播没说过的信息。
        3. 如果原文有明显语音识别错误，请结合上下文合理纠正。
        4. 商品名、品牌名、数字、容量、价格、折扣、时间等信息要尽量保留。
        5. 语气要口语化、简洁，适合字幕阅读。
        6. 不要输出解释，不要总结，不要加标题。
        7. 只输出中文译文，不要输出原文，不要使用“原文：”或“中文：”标签。
        8. 保持原文顺序，按适合字幕阅读的短段落换行。
        """
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?
    let translationOptions: TranslationOptions?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
        case translationOptions = "translation_options"
    }
}

private struct TranslationOptions: Encodable {
    let sourceLanguage: String
    let targetLanguage: String
    let terms: [TranslationTerm]?
    let domains: String?
    let translationMemory: [TranslationMemoryEntry]?

    private enum CodingKeys: String, CodingKey {
        case sourceLanguage = "source_lang"
        case targetLanguage = "target_lang"
        case terms
        case domains
        case translationMemory = "tm_list"
    }
}

private struct TranslationTerm: Encodable {
    let source: String
    let target: String
}

private struct TranslationMemoryEntry: Encodable {
    let source: String
    let target: String
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatChoice]

    var firstOutputText: String? {
        choices.map(\.message.content).first { !$0.isEmpty }
    }
}

private struct ChatChoice: Decodable {
    let message: ChatMessage
}

private struct ChatErrorResponse: Decodable {
    let error: ChatErrorBody
}

private struct ChatErrorBody: Decodable {
    let message: String
}

enum LLMTranslationError: LocalizedError {
    case missingAPIKey(String)
    case missingModel
    case invalidEndpoint
    case invalidResponse
    case emptyOutput(String)
    case requestFailed(provider: String, statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider):
            AppText.translationAPIKeyMissing(provider)
        case .missingModel:
            AppText.translationModelMissing
        case .invalidEndpoint:
            AppText.translationEndpointInvalid
        case .invalidResponse:
            AppText.translationInvalidResponse
        case let .emptyOutput(provider):
            AppText.translationEmptyOutput(provider)
        case let .requestFailed(provider, statusCode, message):
            AppText.translationRequestFailed(provider: provider, statusCode: statusCode, message: message)
        }
    }
}
