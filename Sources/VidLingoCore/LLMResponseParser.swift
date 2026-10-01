import Foundation

public enum LLMResponseParserError: LocalizedError, Sendable, Equatable {
    case invalidJSON
    case emptyOutput
    case incompleteOutput

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "模型返回的 JSON 无法解析。"
        case .emptyOutput:
            "模型返回了空文本。"
        case .incompleteOutput:
            "模型服务返回的结果不完整或被截断，无法作为完整结果使用，请重试。"
        }
    }
}

/// 解析常见的 Chat Completions、Responses 和 content block 文本结构。
public enum LLMResponseParser {
    public static func outputText(from data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMResponseParserError.invalidJSON
        }

        guard let payload = object as? [String: Any] else {
            throw LLMResponseParserError.invalidJSON
        }
        if let status = payload["status"] as? String,
           ["incomplete", "failed", "cancelled", "canceled", "queued", "in_progress"].contains(status.lowercased()) {
            throw LLMResponseParserError.incompleteOutput
        }
        if let details = payload["incomplete_details"], !(details is NSNull) {
            throw LLMResponseParserError.incompleteOutput
        }
        if let error = payload["error"], !(error is NSNull) {
            throw LLMResponseParserError.incompleteOutput
        }
        if let choices = payload["choices"] as? [[String: Any]],
           choices.contains(where: { choice in
               guard let finishReason = choice["finish_reason"] as? String else { return false }
               return ["length", "content_filter", "tool_calls", "function_call"].contains(finishReason.lowercased())
           }) {
            throw LLMResponseParserError.incompleteOutput
        }

        let candidates: [Any?] = [
            payload["output_text"],
            payload["choices"],
            payload["output"]
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let text = extractText(candidate), !text.isEmpty {
                return text
            }
        }
        throw LLMResponseParserError.emptyOutput
    }

    private static func extractText(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let values = value as? [Any] {
            let parts = values.compactMap(extractText)
            let combined = parts.joined()
            return combined.isEmpty ? nil : combined
        }

        guard let dictionary = value as? [String: Any] else { return nil }

        if let message = dictionary["message"], let text = extractText(message) {
            return text
        }
        for key in ["text", "output_text", "content", "value"] {
            if let nested = dictionary[key], let text = extractText(nested) {
                return text
            }
        }
        return nil
    }
}
