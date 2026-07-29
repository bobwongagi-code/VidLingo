import Foundation
import VidLingoCore

actor LLMTranslationService {
    private enum RequestTimeout {
        static let productContext: TimeInterval = 90
        static let transcriptTranslation: TimeInterval = 240
        static let visualAnalysis: TimeInterval = 120
        static let visualSalesCopy: TimeInterval = 180
    }

    static func supportsProductContextFrames(provider: TranslationProviderID, modelName: String) -> Bool {
        productContextVisionModel(provider: provider, currentModel: modelName) != nil
    }

    static func isTranslationOnlyModel(provider: TranslationProviderID, modelName: String) -> Bool {
        provider.capabilities(for: modelName).isTranslationOnly
    }

    private func adapter(for provider: TranslationProviderID) -> any LLMProviderAdapter {
        LLMProviderAdapterFactory.make(for: provider)
    }

    // MARK: - 公共校验和请求构建

    private func preparedRequest(
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String,
        timeout: TimeInterval
    ) throws -> (request: URLRequest, model: String) {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LLMTranslationError.missingModel }

        guard let apiKey = try TranslationAPIKeyStore.readAPIKey(for: provider), !apiKey.isEmpty else {
            throw LLMTranslationError.missingAPIKey(provider.title)
        }

        let endpointText = provider == .custom ? customBaseURL : provider.defaultBaseURL
        let allowLocalHTTP = ProcessInfo.processInfo.environment["VIDLINGO_ALLOW_LOCAL_HTTP"] == "1"
        let endpoint: URL
        do {
            endpoint = try EndpointValidator.validate(
                endpointText,
                allowLoopbackHTTP: provider == .custom && allowLocalHTTP
            ).url
        } catch {
            throw LLMTranslationError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider.usesAnthropicMessagesAPI {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return (request, model)
    }

    // MARK: - 公开 API

    func inferProductContext(
        from text: String,
        fileName: String,
        frameJPEGData: [Data],
        source: LanguageOption,
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String,
        token: ProcessCancellationToken
    ) async throws -> String {
        guard !text.isEmpty else { return "" }
        guard !Self.isTranslationOnlyModel(provider: provider, modelName: modelName) else {
            return ""
        }
        try token.check()

        let (request, model) = try preparedRequest(
            provider: provider,
            modelName: modelName,
            customBaseURL: customBaseURL,
            timeout: RequestTimeout.productContext
        )
        let prompt = productContextPrompt(text, fileName: fileName, source: source)
        let adapter = adapter(for: provider)

        // 优先尝试视觉模型，失败则 fallback 到纯文本
        let visionModel = Self.productContextVisionModel(provider: provider, currentModel: model)
        if let visionModel, !frameJPEGData.isEmpty {
            do {
                let output: String
                output = try await adapter.sendVision(
                    request: request,
                    model: visionModel,
                    system: productContextSystemPrompt,
                    userText: prompt,
                    frameJPEGData: frameJPEGData,
                    options: LLMGenerationOptions(temperature: 0.1, maxTokens: 80, maxFrameCount: 3),
                    provider: provider
                )
                try token.check()
                return sanitizeProductContext(output)
            } catch let error as LLMTranslationError where error.allowsVisionFallback {
                // 仅对明确的视觉能力或 schema 不兼容降级，鉴权、额度和超时直接返回。
            }
        }

        let output = try await adapter.sendText(
            request: request,
            model: model,
            system: productContextSystemPrompt,
            userText: prompt,
            options: LLMGenerationOptions(temperature: 0.1, maxTokens: 80),
            provider: provider
        )
        try token.check()
        return sanitizeProductContext(output)
    }

    func translateShortVideoTranscript(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        productContext: String,
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String,
        token: ProcessCancellationToken
    ) async throws -> String {
        guard !text.isEmpty else { return text }
        try token.check()

        let (request, model) = try preparedRequest(
            provider: provider,
            modelName: modelName,
            customBaseURL: customBaseURL,
            timeout: RequestTimeout.transcriptTranslation
        )
        let translationRequest = translationRequestConfiguration(
            text,
            source: source,
            target: target,
            productContext: productContext,
            provider: provider,
            modelName: model
        )
        let output = try await adapter(for: provider).sendText(
            request: request,
            model: model,
            system: translationRequest.system,
            userText: translationRequest.userText,
            options: translationRequest.options,
            provider: provider
        )
        try token.check()
        return output
    }

    func generateVisualSalesCopy(
        fileName: String,
        durationText: String,
        productContext: String,
        frameJPEGData: [Data],
        provider: TranslationProviderID,
        modelName: String,
        customBaseURL: String,
        token: ProcessCancellationToken
    ) async throws -> String {
        guard !frameJPEGData.isEmpty else { throw LLMTranslationError.visualFramesMissing }
        try token.check()

        var (request, model) = try preparedRequest(
            provider: provider,
            modelName: modelName,
            customBaseURL: customBaseURL,
            timeout: RequestTimeout.visualAnalysis
        )
        guard let visionModel = Self.productContextVisionModel(provider: provider, currentModel: model) else {
            throw LLMTranslationError.visualModelUnsupported(provider.title)
        }

        // 第一轮：视频画面分析
        let analysisResponse: String
        do {
            analysisResponse = try await adapter(for: provider).sendVision(
                request: request,
                model: visionModel,
                system: visualAnalysisSystemPrompt,
                userText: visualVideoAnalysisPrompt(fileName: fileName),
                frameJPEGData: frameJPEGData,
                options: LLMGenerationOptions(temperature: 0.1, maxTokens: 360, maxFrameCount: 12),
                provider: provider
            )
        } catch let error as LLMTranslationError {
            switch error {
            case .emptyOutput, .invalidResponse:
                throw LLMTranslationError.visualResponseInvalid
            default:
                throw error
            }
        }
        try token.check()
        let analysis = try parseVisualVideoAnalysis(from: analysisResponse)

        // 第二轮：生成口播文案
        request.timeoutInterval = RequestTimeout.visualSalesCopy
        let salesCopyPrompt = visualSalesCopyPrompt(
            fileName: fileName,
            durationText: durationText,
            productContext: productContext,
            analysis: analysis
        )
        let output: String
        do {
            output = try await adapter(for: provider).sendVision(
                request: request,
                model: visionModel,
                system: visualSalesCopySystemPrompt,
                userText: salesCopyPrompt,
                frameJPEGData: frameJPEGData,
                options: LLMGenerationOptions(temperature: 0.35, maxTokens: 520, maxFrameCount: 12),
                provider: provider
            )
        } catch let error as LLMTranslationError {
            switch error {
            case .emptyOutput, .invalidResponse:
                throw LLMTranslationError.visualResponseInvalid
            default:
                throw error
            }
        }
        try token.check()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translationRequestConfiguration(
        _ text: String,
        source: LanguageOption,
        target: LanguageOption,
        productContext: String,
        provider: TranslationProviderID,
        modelName: String
    ) -> (system: String, userText: String, options: LLMGenerationOptions) {
        if provider == .qwen, modelName.lowercased().hasPrefix("qwen-mt-") {
            return (
                system: "",
                userText: text,
                options: LLMGenerationOptions(
                    temperature: nil,
                    maxTokens: 2_500,
                    translationOptions: TranslationOptions(
                    sourceLanguage: "auto",
                    targetLanguage: "Chinese",
                    terms: qwenMTTerms,
                    domains: qwenMTDomainPrompt(productContext),
                    translationMemory: qwenMTTranslationMemory
                    )
                )
            )
        }

        let context = productContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let guardrails = translationGuardrails(for: source)
        let userPrompt = """
        源语言：\(source.localizedTitle)
        目标语言：\(target.localizedTitle)
        视频类型：TikTok / 短视频带货口播
        商品类型：\(context.isEmpty ? "未知商品，请根据原文谨慎判断" : context)

        \(guardrails)

        请把下面的 Whisper 转写原文翻译成自然、易懂的简体中文。

        原文：
        \(text)
        """

        return (
            system: systemPrompt,
            userText: userPrompt,
            options: LLMGenerationOptions(temperature: 0.2, maxTokens: 2_500)
        )
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

    private var visualAnalysisSystemPrompt: String {
        "你是一个短视频分析助手。只根据截图中能确认的内容回答，不要猜测品牌、价格、功效或参数。"
    }

    private func parseVisualVideoAnalysis(from text: String) throws -> VisualVideoAnalysis {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = extractJSONObject(from: trimmedText) ?? trimmedText
        guard let data = jsonText.data(using: .utf8) else {
            throw LLMTranslationError.visualResponseInvalid
        }
        do {
            return try JSONDecoder().decode(VisualVideoAnalysis.self, from: data)
        } catch {
            throw LLMTranslationError.visualResponseInvalid
        }
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
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
        provider.capabilities(for: model).supportsVision ? model : nil
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
        7. Do not add product specs, ratings, effects, accessories, discounts, or urgency words that are not present in the transcript.
        8. If the ASR text is unclear, keep the translation broad and natural instead of inventing details.
        \(productLine)
        """
    }

    private func translationGuardrails(for source: LanguageOption) -> String {
        switch source.id {
        case "th-TH":
            """
            泰语专项要求：
            - 当前原文来自 Whisper 泰语转写，可能有错词、粘连或漏字。先保留原文能确认的事实信息。
            - 可以把明确的使用场景、感受和语气，转成自然的中文带货表达，让译文更顺、更有口播感。
            - 允许强化语气、节奏和感受，例如“更安心”“更省心”“用起来方便”“真的舒服”，但不能新增硬事实。
            - 不要补充原文没有明确说出的品牌、型号、价格、折扣、库存、IP 等级、续航、材质、成分、功效、参数。
            - 如果 ASR 文字不清楚，只做宽泛处理，不要写成确定事实。
            - 输出只保留译文正文，不要翻译说明、判断依据、标题或括号注释。
            """
        case "ms-MY":
            """
            马来语专项要求：
            - 保留马来语带货口语节奏，但不要添加原文没有的参数、功效、配件、折扣或库存。
            - 对明显 ASR 错词可以按上下文纠正；证据不足时用宽泛译法，不要过度补写。
            - 输出只保留译文正文，不要翻译说明、判断依据、标题或括号注释。
            """
        default:
            """
            忠实翻译要求：
            - 不添加原文没有的品牌、参数、功效、价格、折扣、库存或时间限定词。
            - 输出只保留译文正文，不要翻译说明、判断依据、标题或括号注释。
            """
        }
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

private struct VisualVideoAnalysis: Decodable {
    let category: String
    let product: String?
    let scene: String
    let action: String
    let mood: String
}
