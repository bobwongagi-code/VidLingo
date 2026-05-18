import Foundation

actor DeepSeekTranslationService {
    private let deepSeekChatCompletionsEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    func translateShortVideoTranscript(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        productContext: String
    ) async throws -> String {
        guard !text.isEmpty else { return text }
        guard let apiKey = try DeepSeekAPIKeyStore.readAPIKey(), !apiKey.isEmpty else {
            throw DeepSeekTranslationError.missingAPIKey
        }

        var request = URLRequest(url: deepSeekChatCompletionsEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

        request.httpBody = try JSONEncoder().encode(
            DeepSeekChatCompletionRequest(
                model: "deepseek-chat",
                messages: [
                    DeepSeekChatMessage(role: "system", content: shortVideoTranslationInstructions),
                    DeepSeekChatMessage(role: "user", content: userPrompt)
                ],
                stream: false,
                temperature: 0.2,
                maxTokens: 2500
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekTranslationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(DeepSeekErrorResponse.self, from: data)
            throw DeepSeekTranslationError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorResponse?.error.message
            )
        }

        let outputText = try JSONDecoder()
            .decode(DeepSeekChatCompletionResponse.self, from: data)
            .firstOutputText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !outputText.isEmpty else {
            throw DeepSeekTranslationError.emptyOutput
        }
        return outputText
    }

    private var shortVideoTranslationInstructions: String {
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

private struct DeepSeekChatCompletionRequest: Encodable {
    let model: String
    let messages: [DeepSeekChatMessage]
    let stream: Bool
    let temperature: Double
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct DeepSeekChatMessage: Codable {
    let role: String
    let content: String
}

private struct DeepSeekChatCompletionResponse: Decodable {
    let choices: [DeepSeekChoice]

    var firstOutputText: String? {
        choices.map(\.message.content).first { !$0.isEmpty }
    }
}

private struct DeepSeekChoice: Decodable {
    let message: DeepSeekChatMessage
}

private struct DeepSeekErrorResponse: Decodable {
    let error: DeepSeekErrorBody
}

private struct DeepSeekErrorBody: Decodable {
    let message: String
}

enum DeepSeekTranslationError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case emptyOutput
    case requestFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            AppText.deepSeekAPIKeyMissing
        case .invalidResponse:
            AppText.deepSeekInvalidResponse
        case .emptyOutput:
            AppText.deepSeekEmptyOutput
        case let .requestFailed(statusCode, message):
            AppText.deepSeekRequestFailed(statusCode: statusCode, message: message)
        }
    }
}
