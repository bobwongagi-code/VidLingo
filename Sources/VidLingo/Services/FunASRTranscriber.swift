import Foundation

struct FunASRTranscriber {
    static let modelName = "fun-asr-flash-2026-06-15"
    static let maxDurationSeconds: Double = 5 * 60
    static let maxAudioBytes: Int64 = 7 * 1_024 * 1_024

    private static let endpoint = URL(string: "https://llm-nlx73tfv3mm6w67e.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    static func transcribe(
        audioFileURL: URL,
        productContext: String,
        token: ProcessCancellationToken,
        languageHint: String? = nil
    ) async throws -> String {
        try token.check()
        guard let apiKey = try TranslationAPIKeyStore.readAPIKey(for: .qwen), !apiKey.isEmpty else {
            throw FunASRTranscriptionError.missingAPIKey
        }

        let resourceValues = try audioFileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = resourceValues.fileSize, fileSize > 0 else {
            throw FunASRTranscriptionError.emptyAudio
        }
        guard Int64(fileSize) <= maxAudioBytes else {
            throw FunASRTranscriptionError.audioTooLarge
        }

        let audioData = try Data(contentsOf: audioFileURL, options: .mappedIfSafe)
        guard !audioData.isEmpty else {
            throw FunASRTranscriptionError.emptyAudio
        }
        try token.check()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try requestData(
            audioData: audioData,
            productContext: productContext,
            languageHint: languageHint
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FunASRTranscriptionError.requestTimedOut
        }
        try token.check()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FunASRTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FunASRTranscriptionError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMessage(from: data)
            )
        }

        do {
            return try recognizedText(from: data)
        } catch FunASRTranscriptionError.emptyOutput {
            // 空结果交给统一的无口播画面兜底流程处理。
            return ""
        }
    }

    static func requestData(
        audioData: Data,
        productContext: String,
        languageHint: String? = nil
    ) throws -> Data {
        guard !audioData.isEmpty else {
            throw FunASRTranscriptionError.emptyAudio
        }
        guard Int64(audioData.count) <= maxAudioBytes else {
            throw FunASRTranscriptionError.audioTooLarge
        }

        let context = productContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var messages = [FunASRMessage]()
        if !context.isEmpty {
            let limitedContext = String(context.prefix(360))
            messages.append(FunASRMessage(
                role: "user",
                content: [FunASRContent(
                    type: "input_text",
                    text: "这是短视频带货口播。商品类型：\(limitedContext)",
                    inputAudio: nil
                )]
            ))
        }
        messages.append(FunASRMessage(
            role: "user",
            content: [FunASRContent(
                type: "input_audio",
                text: nil,
                inputAudio: FunASRInputAudio(
                    data: "data:audio/wav;base64,\(audioData.base64EncodedString())"
                )
            )]
        ))

        return try JSONEncoder().encode(FunASRRequest(
            model: modelName,
            input: FunASRInput(messages: messages),
            parameters: FunASRParameters(
                format: "wav",
                sampleRate: 16_000,
                languageHints: languageHint.map { [$0] }
            )
        ))
    }

    static func languageCode(for language: LanguageOption) -> String? {
        let code = language.id
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init)
        guard let code, supportedLanguageCodes.contains(code) else { return nil }
        return code
    }

    private static let supportedLanguageCodes: Set<String> = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "tl", "hi", "ar",
        "fr", "de", "es", "pt", "ru", "it", "nl", "sv", "da", "fi", "no",
        "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk"
    ]

    static func recognizedText(from data: Data) throws -> String {
        let response: FunASRResponse
        do {
            response = try JSONDecoder().decode(FunASRResponse.self, from: data)
        } catch {
            throw FunASRTranscriptionError.invalidResponse
        }

        let candidates = [
            response.output?.output?.sentence?.text,
            response.output?.sentence?.text,
            response.output?.text,
            response.sentence?.text,
            response.text
        ]
        guard let text = candidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            throw FunASRTranscriptionError.emptyOutput
        }
        return text
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(FunASRErrorResponse.self, from: data) else {
            return nil
        }
        let message = response.message ?? response.error?.message ?? response.code
        guard let message, !message.isEmpty else { return nil }
        return OfflineTranslationDiagnostics.sanitizedErrorDescription(message)
    }
}

private struct FunASRRequest: Encodable {
    let model: String
    let input: FunASRInput
    let parameters: FunASRParameters
}

private struct FunASRInput: Encodable {
    let messages: [FunASRMessage]
}

private struct FunASRMessage: Encodable {
    let role: String
    let content: [FunASRContent]
}

private struct FunASRContent: Encodable {
    let type: String
    let text: String?
    let inputAudio: FunASRInputAudio?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputAudio = "input_audio"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(inputAudio, forKey: .inputAudio)
    }
}

private struct FunASRInputAudio: Encodable {
    let data: String
}

private struct FunASRParameters: Encodable {
    let format: String
    let sampleRate: Int
    let languageHints: [String]?

    private enum CodingKeys: String, CodingKey {
        case format
        case sampleRate = "sample_rate"
        case languageHints = "language_hints"
    }
}

private struct FunASRResponse: Decodable {
    let output: FunASROutput?
    let text: String?
    let sentence: FunASRSentence?
}

private struct FunASROutput: Decodable {
    let text: String?
    let sentence: FunASRSentence?
    let output: FunASRNestedOutput?
}

private struct FunASRNestedOutput: Decodable {
    let sentence: FunASRSentence?
}

private struct FunASRSentence: Decodable {
    let text: String?
}

private struct FunASRErrorResponse: Decodable {
    let code: String?
    let message: String?
    let error: FunASRErrorDetail?
}

private struct FunASRErrorDetail: Decodable {
    let code: String?
    let message: String?
}

enum FunASRTranscriptionError: LocalizedError {
    case missingAPIKey
    case emptyAudio
    case audioTooLarge
    case requestTimedOut
    case requestFailed(statusCode: Int, message: String?)
    case invalidResponse
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Fun-ASR 转写需要先保存 Qwen / 千问 API key。"
        case .emptyAudio:
            return "没有可发送给 Fun-ASR 的音频。"
        case .audioTooLarge:
            return "音频超过 Fun-ASR 的 Base64 上传大小限制。"
        case .requestTimedOut:
            return "Fun-ASR 请求超时。模型服务响应过慢或网络连接中断，请稍后重试。"
        case let .requestFailed(statusCode, message):
            let detail = message.map { "：\($0)" } ?? ""
            return "Fun-ASR 请求失败（\(statusCode)）\(detail)"
        case .invalidResponse:
            return "Fun-ASR 返回了无法解析的转写结果。"
        case .emptyOutput:
            return "Fun-ASR 没有返回有效口播。"
        }
    }
}
