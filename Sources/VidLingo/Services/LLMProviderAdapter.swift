import Foundation
import VidLingoCore

struct LLMGenerationOptions: Sendable {
    let temperature: Double?
    let maxTokens: Int
    let translationOptions: TranslationOptions?
    let maxFrameCount: Int
    let enableThinking: Bool?

    init(
        temperature: Double?,
        maxTokens: Int,
        translationOptions: TranslationOptions? = nil,
        maxFrameCount: Int = 0,
        enableThinking: Bool? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.translationOptions = translationOptions
        self.maxFrameCount = maxFrameCount
        self.enableThinking = enableThinking
    }
}

protocol LLMProviderAdapter: Sendable {
    func sendText(
        request: URLRequest,
        model: String,
        system: String,
        userText: String,
        options: LLMGenerationOptions,
        provider: TranslationProviderID
    ) async throws -> String

    func sendVision(
        request: URLRequest,
        model: String,
        system: String,
        userText: String,
        frameJPEGData: [Data],
        options: LLMGenerationOptions,
        provider: TranslationProviderID
    ) async throws -> String
}

enum LLMProviderAdapterFactory {
    static func make(for provider: TranslationProviderID) -> any LLMProviderAdapter {
        provider.usesAnthropicMessagesAPI
            ? AnthropicMessagesProviderAdapter()
            : ChatCompletionsProviderAdapter()
    }
}

struct ChatCompletionsProviderAdapter: LLMProviderAdapter, Sendable {
    func sendText(
        request: URLRequest,
        model: String,
        system: String,
        userText: String,
        options: LLMGenerationOptions,
        provider: TranslationProviderID
    ) async throws -> String {
        let messages = system.isEmpty
            ? [ChatMessage(role: "user", content: userText)]
            : [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: userText)
            ]
        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            stream: false,
            temperature: options.temperature,
            maxTokens: options.maxTokens,
            translationOptions: options.translationOptions,
            enableThinking: options.enableThinking
        )
        return try await LLMHTTPClient.sendChat(request: request, body: body, provider: provider)
    }

    func sendVision(
        request: URLRequest,
        model: String,
        system: String,
        userText: String,
        frameJPEGData: [Data],
        options: LLMGenerationOptions,
        provider: TranslationProviderID
    ) async throws -> String {
        let body = Self.visionBody(
            model: model,
            system: system,
            userText: userText,
            frameJPEGData: frameJPEGData,
            options: options
        )
        return try await LLMHTTPClient.sendChat(request: request, body: body, provider: provider)
    }

    static func visionRequestData(
        model: String,
        system: String,
        userText: String,
        frameJPEGData: [Data],
        maxFrameCount: Int
    ) throws -> Data {
        let body = visionBody(
            model: model,
            system: system,
            userText: userText,
            frameJPEGData: frameJPEGData,
            options: LLMGenerationOptions(temperature: 0.1, maxTokens: 80, maxFrameCount: maxFrameCount)
        )
        return try JSONEncoder().encode(body)
    }

    private static func visionBody(
        model: String,
        system: String,
        userText: String,
        frameJPEGData: [Data],
        options: LLMGenerationOptions
    ) -> VisionChatCompletionRequest {
        let images = frameJPEGData.prefix(options.maxFrameCount).map { data in
            VisionContent(
                type: "image_url",
                text: nil,
                imageURL: VisionImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())")
            )
        }
        let messages = (system.isEmpty ? [] : [
            VisionChatMessage(
                role: "system",
                content: [VisionContent(type: "text", text: system, imageURL: nil)]
            )
        ]) + [
            VisionChatMessage(
                role: "user",
                content: [VisionContent(type: "text", text: userText, imageURL: nil)] + images
            )
        ]
        return VisionChatCompletionRequest(
            model: model,
            messages: messages,
            stream: false,
            temperature: options.temperature,
            maxTokens: options.maxTokens,
            enableThinking: options.enableThinking
        )
    }
}

struct AnthropicMessagesProviderAdapter: LLMProviderAdapter, Sendable {
    func sendText(
        request: URLRequest,
        model: String,
        system: String,
        userText: String,
        options: LLMGenerationOptions,
        provider: TranslationProviderID
    ) async throws -> String {
        let body = AnthropicRequest(
            model: model,
            maxTokens: options.maxTokens,
            system: system,
            messages: [AnthropicMessage(role: "user", content: userText)]
        )
        return try await LLMHTTPClient.sendAnthropic(request: request, body: body, provider: provider)
    }

    func sendVision(
        request: URLRequest,
        model: String,
        system: String,
        userText: String,
        frameJPEGData: [Data],
        options: LLMGenerationOptions,
        provider: TranslationProviderID
    ) async throws -> String {
        let images = frameJPEGData.prefix(options.maxFrameCount).map { data in
            AnthropicVisionContent(
                type: "image",
                text: nil,
                source: AnthropicImageSource(
                    type: "base64",
                    mediaType: "image/jpeg",
                    data: data.base64EncodedString()
                )
            )
        }
        let body = AnthropicVisionRequest(
            model: model,
            maxTokens: options.maxTokens,
            system: system,
            messages: [AnthropicVisionMessage(
                role: "user",
                content: [AnthropicVisionContent(type: "text", text: userText, source: nil)] + images
            )]
        )
        return try await LLMHTTPClient.sendAnthropic(request: request, body: body, provider: provider)
    }
}

private enum LLMHTTPClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    static func sendChat<Body: Encodable>(
        request: URLRequest,
        body: Body,
        provider: TranslationProviderID
    ) async throws -> String {
        let data = try await data(for: request, body: body, provider: provider)
        do {
            return try LLMResponseParser.outputText(from: data)
        } catch LLMResponseParserError.emptyOutput {
            throw LLMTranslationError.emptyOutput(provider.title)
        } catch {
            throw LLMTranslationError.invalidResponse
        }
    }

    static func sendAnthropic<Body: Encodable>(
        request: URLRequest,
        body: Body,
        provider: TranslationProviderID
    ) async throws -> String {
        let data = try await data(for: request, body: body, provider: provider)
        let output = try JSONDecoder().decode(AnthropicResponse.self, from: data).text
        guard !output.isEmpty else {
            throw LLMTranslationError.emptyOutput(provider.title)
        }
        return output
    }

    private static func data<Body: Encodable>(
        for baseRequest: URLRequest,
        body: Body,
        provider: TranslationProviderID
    ) async throws -> Data {
        var request = baseRequest
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMTranslationError.requestTimedOut(provider: provider.title)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMTranslationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(ChatErrorResponse.self, from: data)
            throw LLMTranslationError.requestFailed(
                provider: provider.title,
                statusCode: httpResponse.statusCode,
                message: errorResponse?.error.message.map(OfflineTranslationDiagnostics.sanitizedErrorDescription)
            )
        }
        return data
    }
}

struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?
    let translationOptions: TranslationOptions?
    let enableThinking: Bool?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
        case translationOptions = "translation_options"
        case enableThinking = "enable_thinking"
    }
}

struct TranslationOptions: Encodable, Sendable {
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

struct TranslationTerm: Encodable, Sendable {
    let source: String
    let target: String
}

struct TranslationMemoryEntry: Encodable, Sendable {
    let source: String
    let target: String
}

struct VisionChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [VisionChatMessage]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?
    let enableThinking: Bool?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
        case enableThinking = "enable_thinking"
    }
}

struct VisionChatMessage: Encodable, Sendable {
    let role: String
    let content: [VisionContent]
}

struct VisionContent: Encodable, Sendable {
    let type: String
    let text: String?
    let imageURL: VisionImageURL?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

struct VisionImageURL: Encodable, Sendable {
    let url: String
}

struct AnthropicRequest: Encodable, Sendable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

struct AnthropicVisionRequest: Encodable, Sendable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicVisionMessage]

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

struct AnthropicVisionMessage: Encodable, Sendable {
    let role: String
    let content: [AnthropicVisionContent]
}

struct AnthropicVisionContent: Encodable, Sendable {
    let type: String
    let text: String?
    let source: AnthropicImageSource?
}

struct AnthropicImageSource: Encodable, Sendable {
    let type: String
    let mediaType: String
    let data: String

    private enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

struct AnthropicMessage: Encodable, Sendable {
    let role: String
    let content: String
}

struct AnthropicResponse: Decodable, Sendable {
    let content: [AnthropicContentBlock]

    var text: String {
        content.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AnthropicContentBlock: Decodable, Sendable {
    let type: String?
    let text: String?
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct ChatErrorResponse: Decodable, Sendable {
    let error: ChatErrorBody
}

struct ChatErrorBody: Decodable, Sendable {
    let message: String?
}

enum LLMTranslationError: LocalizedError {
    case missingAPIKey(String)
    case missingModel
    case invalidEndpoint
    case invalidResponse
    case emptyOutput(String)
    case requestTimedOut(provider: String)
    case requestFailed(provider: String, statusCode: Int, message: String?)
    case visualFramesMissing
    case visualModelUnsupported(String)
    case visualResponseInvalid

    var allowsVisionFallback: Bool {
        switch self {
        case .visualModelUnsupported, .visualResponseInvalid:
            return true
        case let .requestFailed(_, statusCode, message):
            guard statusCode == 400, let message else { return false }
            let normalized = message.lowercased()
            return [
                "vision", "image", "multimodal", "image_url", "content type",
                "content array", "content block", "unsupported content"
            ].contains { normalized.contains($0) }
        default:
            return false
        }
    }

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
        case let .requestTimedOut(provider):
            AppText.translationRequestTimedOut(provider)
        case let .requestFailed(provider, statusCode, message):
            AppText.translationRequestFailed(provider: provider, statusCode: statusCode, message: message)
        case .visualFramesMissing:
            AppText.visualFramesMissing
        case let .visualModelUnsupported(provider):
            AppText.visualModelUnsupported(provider)
        case .visualResponseInvalid:
            AppText.translationInvalidResponse
        }
    }
}
