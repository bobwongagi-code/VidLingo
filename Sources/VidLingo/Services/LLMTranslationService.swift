import Foundation

actor LLMTranslationService {
    static func supportsProductContextFrames(provider: TranslationProviderID, modelName: String) -> Bool {
        productContextVisionModel(provider: provider, currentModel: modelName) != nil
    }

    func inferProductContext(
        from text: String,
        fileName: String,
        frameJPEGData: [Data],
        source: LanguageOption,
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String
    ) async throws -> String {
        guard !text.isEmpty else { return "" }

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

        let prompt = productContextPrompt(text, fileName: fileName, source: source)
        let visionModel = Self.productContextVisionModel(provider: provider, currentModel: model)
        let shouldUseFrames = visionModel != nil && !frameJPEGData.isEmpty
        if shouldUseFrames {
            request.httpBody = try JSONEncoder().encode(
                visionProductContextRequest(
                    prompt: prompt,
                    frameJPEGData: frameJPEGData,
                    model: visionModel ?? model
                )
            )
            do {
                let outputText = try await sendChatCompletionRequest(request, provider: provider)
                return sanitizeProductContext(outputText)
            } catch LLMTranslationError.requestFailed {
                request.httpBody = try JSONEncoder().encode(
                    productContextRequest(
                        prompt: prompt,
                        source: source,
                        provider: provider,
                        model: model
                    )
                )
            }
        } else {
            request.httpBody = try JSONEncoder().encode(
                productContextRequest(
                    prompt: prompt,
                    source: source,
                    provider: provider,
                    model: model
                )
            )
        }

        let outputText = try await sendChatCompletionRequest(request, provider: provider)
        return sanitizeProductContext(outputText)
    }

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

        return try await sendChatCompletionRequest(request, provider: provider)
    }

    func generateVisualSalesCopy(
        fileName: String,
        durationText: String,
        productContext: String,
        frameJPEGData: [Data],
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String
    ) async throws -> String {
        guard !frameJPEGData.isEmpty else {
            throw LLMTranslationError.visualFramesMissing
        }

        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw LLMTranslationError.missingModel
        }

        guard let visionModel = Self.productContextVisionModel(provider: provider, currentModel: model) else {
            throw LLMTranslationError.visualModelUnsupported(provider.title)
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
            visionVideoAnalysisRequest(
                prompt: visualVideoAnalysisPrompt(fileName: fileName),
                frameJPEGData: frameJPEGData,
                model: visionModel
            )
        )
        let analysisText = try await sendChatCompletionRequest(request, provider: provider)
        let analysis = try parseVisualVideoAnalysis(from: analysisText)

        request.httpBody = try JSONEncoder().encode(
            visionSalesCopyRequest(
                prompt: visualSalesCopyPrompt(
                    fileName: fileName,
                    durationText: durationText,
                    productContext: productContext,
                    analysis: analysis
                ),
                frameJPEGData: frameJPEGData,
                model: visionModel
            )
        )
        return try await sendChatCompletionRequest(request, provider: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendChatCompletionRequest(
        _ request: URLRequest,
        provider: TranslationProviderID
    ) async throws -> String {
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

    private func productContextRequest(
        prompt: String,
        source: LanguageOption,
        provider: TranslationProviderID,
        model: String
    ) -> ChatCompletionRequest {
        if provider == .qwen, model.lowercased().hasPrefix("qwen-mt-") {
            return ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(role: "user", content: prompt)
                ],
                stream: false,
                temperature: nil,
                maxTokens: nil,
                translationOptions: TranslationOptions(
                    sourceLanguage: "auto",
                    targetLanguage: "Chinese",
                    terms: nil,
                    domains: "Infer the product category from a short e-commerce video transcript. Output one concise Chinese category label only.",
                    translationMemory: nil
                )
            )
        }

        return ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: productContextSystemPrompt),
                ChatMessage(role: "user", content: prompt)
            ],
            stream: false,
            temperature: 0.1,
            maxTokens: 80,
            translationOptions: nil
        )
    }

    private func visionProductContextRequest(
        prompt: String,
        frameJPEGData: [Data],
        model: String
    ) -> VisionChatCompletionRequest {
        let imageContents = frameJPEGData.prefix(3).map { data in
            VisionContent(
                type: "image_url",
                text: nil,
                imageURL: VisionImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())")
            )
        }
        return VisionChatCompletionRequest(
            model: model,
            messages: [
                VisionChatMessage(
                    role: "system",
                    content: [
                        VisionContent(type: "text", text: productContextSystemPrompt, imageURL: nil)
                    ]
                ),
                VisionChatMessage(
                    role: "user",
                    content: [
                        VisionContent(type: "text", text: prompt, imageURL: nil)
                    ] + imageContents
                )
            ],
            stream: false,
            temperature: 0.1,
            maxTokens: 80
        )
    }

    private func visionSalesCopyRequest(
        prompt: String,
        frameJPEGData: [Data],
        model: String
    ) -> VisionChatCompletionRequest {
        let imageContents = frameJPEGData.prefix(12).map { data in
            VisionContent(
                type: "image_url",
                text: nil,
                imageURL: VisionImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())")
            )
        }
        return VisionChatCompletionRequest(
            model: model,
            messages: [
                VisionChatMessage(
                    role: "system",
                    content: [
                        VisionContent(type: "text", text: visualSalesCopySystemPrompt, imageURL: nil)
                    ]
                ),
                VisionChatMessage(
                    role: "user",
                    content: [
                        VisionContent(type: "text", text: prompt, imageURL: nil)
                    ] + imageContents
                )
            ],
            stream: false,
            temperature: 0.35,
            maxTokens: 520
        )
    }

    private func visionVideoAnalysisRequest(
        prompt: String,
        frameJPEGData: [Data],
        model: String
    ) -> VisionChatCompletionRequest {
        let imageContents = frameJPEGData.prefix(12).map { data in
            VisionContent(
                type: "image_url",
                text: nil,
                imageURL: VisionImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())")
            )
        }
        return VisionChatCompletionRequest(
            model: model,
            messages: [
                VisionChatMessage(
                    role: "user",
                    content: [
                        VisionContent(type: "text", text: prompt, imageURL: nil)
                    ] + imageContents
                )
            ],
            stream: false,
            temperature: 0.1,
            maxTokens: 360
        )
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

    private func productContextPrompt(_ text: String, fileName: String, source: LanguageOption) -> String {
        """
        来源语言：\(source.localizedTitle)
        视频文件名：\(fileName)

        请根据下面的带货短视频口播原文，推断商品类型。
        只输出一个简短中文商品类型，格式为：一级类目 / 具体品类。
        视频文件名只能作为辅助线索，不能单独决定商品类型。
        如果文件名和口播内容冲突，以口播内容为准。
        只有文件名和口播内容互相印证时，才输出更具体的品类。
        如果口播只描述外观、形状、动作，但没有明确商品名称，不要根据形状强行猜具体品类。
        对小众产品宁可输出较宽泛的类型，例如“农用工具 / 未确认产品”，不要输出看似具体但证据不足的品类。
        如果无法判断，输出：未知商品。
        不要解释，不要加引号，不要输出多行。
        如果同时提供了视频画面，画面只能用于确认商品外观和使用场景，不能添加口播和文件名都没有的信息。
        画面中的人物、衣服、头发、眼镜、背景和装饰物，不等于商品。
        只有主播正在展示、拿在手里、反复讲解或引导购买的物品，才可以作为商品类型。

        原文：
        \(text)
        """
    }

    private var productContextSystemPrompt: String {
        """
        你是一个跨境电商短视频商品分类助手。你根据口播原文判断视频在卖什么，视频文件名和视频画面只能作为辅助线索。不要补充原文没有的品牌、功效、价格或参数。文件名和口播冲突时以口播为准；证据不足时输出宽泛类型或未知商品，不要自信猜测具体品类。画面中的人物穿着、发型、眼镜、背景和装饰物不是商品，除非口播明确在卖它。输出必须是一行简体中文商品类型。
        """
    }

    private func visualVideoAnalysisPrompt(fileName: String) -> String {
        """
        视频文件名：\(fileName)

        你是一个短视频分析助手。根据这组视频截图，回答以下问题，用 JSON 格式输出：

        {
          "category": "视频类型，从以下选一个：美妆护肤/穿搭展示/美食探店/好物分享/数码科技/家居生活/旅行风景/健身运动/宠物/其他",
          "product": "视频中的核心产品或主题，没有则填 null",
          "scene": "拍摄场景，如室内/户外/店铺/厨房等",
          "action": "博主在做什么，用一句话描述",
          "mood": "视频整体氛围：轻松/专业/搞笑/种草/测评"
        }

        只输出 JSON，不要解释。
        """
    }

    private func visualSalesCopyPrompt(
        fileName: String,
        durationText: String,
        productContext: String,
        analysis: VisualVideoAnalysis
    ) -> String {
        let context = productContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = analysis.product?.trimmingCharacters(in: .whitespacesAndNewlines)
        let productText = product?.isEmpty == false ? product! : "未确认"
        let finalProduct = context.isEmpty ? productText : context
        let duration = durationText.isEmpty ? "未知" : durationText
        return """
        视频文件名：\(fileName)

        你是一个短视频带货口播文案写手，擅长把画面内容转化为自然、有感染力的中文口播稿。

        ## 视频背景
        - 来源平台：TikTok
        - 视频时长：约 \(duration)
        - 内容类型：\(analysis.category)
        - 核心产品/主题：\(finalProduct)
        - 拍摄场景：\(analysis.scene)
        - 博主动作：\(analysis.action)
        - 整体氛围：\(analysis.mood)

        ## 任务
        根据以上信息和这组视频截图，写一段中文口播文案。这条视频没有语音，你需要“替视频说话”。

        ## 风格要求
        - 像真人对着镜头聊天，不是写文章
        - 短句为主，每句不超过 20 个字
        - 第一句必须有吸引力，让人想继续听
        - 用“你”“姐妹们”“兄弟们”等称呼拉近距离
        - 多用感受词：舒服、绝了、真的香、太可了
        - 适当加语气词：吧、啊、了、嘛
        - 节奏感：长短句交替，别全是一样长的句子
        - 根据氛围调整语气：种草要热情，测评要客观但口语化，搞笑要俏皮

        ## 禁止项
        - 不要出现“视频中”“画面显示”“可以看到”等描述词
        - 不要用书面语和长定语从句
        - 不要总结、不要分析、不要加标题
        - 不要加 emoji
        - 只能基于画面中能看见的内容写，不得编造品牌、价格、折扣、库存、成分、功效、参数
        - 商品不确定时，用宽泛说法，不要假装确定

        ## 输出格式
        直接输出口播文案，一段连续的文字，不要分点、不要编号。控制在 80-150 字之间。
        """
    }

    private var visualSalesCopySystemPrompt: String {
        """
        你是一个短视频带货口播文案写手。你必须基于视频截图和结构化分析写中文口播稿，不编造品牌、价格、折扣、库存、成分、功效或参数。不要输出解释、标题、编号或 emoji。
        """
    }

    private func parseVisualVideoAnalysis(from text: String) throws -> VisualVideoAnalysis {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = extractJSONObject(from: trimmedText) ?? trimmedText
        guard let data = jsonText.data(using: .utf8) else {
            throw LLMTranslationError.invalidResponse
        }
        return try JSONDecoder().decode(VisualVideoAnalysis.self, from: data)
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    private func sanitizeProductContext(_ text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`：: "))
    }

    private static func productContextVisionModel(provider: TranslationProviderID, currentModel model: String) -> String? {
        let normalizedModel = model.lowercased()
        switch provider {
        case .qwen:
            return "qwen-vl-plus"
        case .openAI:
            let supportsVision = normalizedModel.contains("gpt-4o")
                || normalizedModel.contains("gpt-4.1")
                || normalizedModel.contains("gpt-5")
            return supportsVision ? model : nil
        case .custom, .deepSeek, .claudeCompatible:
            return nil
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

private struct VisionChatCompletionRequest: Encodable {
    let model: String
    let messages: [VisionChatMessage]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct VisionChatMessage: Encodable {
    let role: String
    let content: [VisionContent]
}

private struct VisionContent: Encodable {
    let type: String
    let text: String?
    let imageURL: VisionImageURL?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct VisionImageURL: Encodable {
    let url: String
}

private struct VisualVideoAnalysis: Decodable {
    let category: String
    let product: String?
    let scene: String
    let action: String
    let mood: String
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
    case visualFramesMissing
    case visualModelUnsupported(String)

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
        case .visualFramesMissing:
            AppText.visualFramesMissing
        case let .visualModelUnsupported(provider):
            AppText.visualModelUnsupported(provider)
        }
    }
}
