import Foundation
import VidLingoCore

struct FunASRTranscription: Sendable {
    let text: String
    let segments: [TimedTranscriptSegment]
    let hasWordTimestamps: Bool
}

struct FunASRTranscriber {
    static let modelName = "fun-asr-flash-2026-06-15"
    static let maxDurationSeconds: Double = 5 * 60
    static let maxAudioBytes: Int64 = 7 * 1_024 * 1_024

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
    ) async throws -> FunASRTranscription {
        try token.check()
        let endpoint = FunASRConfiguration.endpoint
        guard let apiKey = try TranslationAPIKeyStore.readAPIKey(service: FunASRConfiguration.keychainService),
              !apiKey.isEmpty else {
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
        // The complete JSON response keeps the same word timestamps without
        // requiring the client to reconstruct a large SSE event stream.
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try requestData(
            audioData: audioData,
            productContext: productContext,
            languageHint: languageHint
        )

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FunASRTranscriptionError.requestTimedOut
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FunASRTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FunASRTranscriptionError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMessage(from: responseData)
            )
        }

        try token.check()
        let transcription: FunASRTranscription
        do {
            transcription = try Self.transcription(fromJSONData: responseData)
        } catch {
            throw FunASRTranscriptionError.invalidResponse
        }
        let segments = transcription.segments
        let text = transcription.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 空结果交给统一的无口播画面兜底流程处理。
            return FunASRTranscription(text: "", segments: [], hasWordTimestamps: false)
        }
        return FunASRTranscription(
            text: text,
            segments: segments,
            hasWordTimestamps: transcription.hasWordTimestamps
        )
    }

    private static func transcription(fromJSONData data: Data) throws -> FunASRTranscription {
        guard !data.isEmpty else {
            throw FunASRTranscriptionError.invalidResponse
        }
        return try transcription(fromSSELines: ["data:\(String(decoding: data, as: UTF8.self))"])
    }

    static func transcription(fromSSELines lines: [String]) throws -> FunASRTranscription {
        var latestText = ""
        var finalSegments = [Int: TimedTranscriptSegment]()
        var finalWords = [Int: [TimedTranscriptWord]]()
        var nextSegmentID = 1

        for line in lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8) else { continue }

            let response: FunASRResponse
            do {
                response = try JSONDecoder().decode(FunASRResponse.self, from: data)
            } catch {
                throw FunASRTranscriptionError.invalidResponse
            }

            let textCandidates = [
                response.output?.text,
                response.output?.output?.sentence?.text,
                response.output?.sentence?.text,
                response.sentence?.text,
                response.text
            ]
            if let text = textCandidates
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                latestText = text
            }

            guard let sentence = response.output?.sentence
                    ?? response.output?.output?.sentence
                    ?? response.sentence,
                  sentence.sentenceEnd == true,
                  let text = sentence.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }

            let sentenceWords = sentence.words?.compactMap { word -> TimedTranscriptWord? in
                guard let wordText = word.text?.trimmingCharacters(in: .newlines),
                      !wordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let wordBeginTime = word.beginTime,
                      let wordEndTime = word.endTime,
                      wordEndTime >= wordBeginTime else { return nil }
                return TimedTranscriptWord(
                    startMilliseconds: wordBeginTime,
                    endMilliseconds: wordEndTime,
                    text: wordText,
                    punctuation: word.punctuation ?? ""
                )
            } ?? []
            let beginTime = sentence.beginTime ?? sentenceWords.first?.startMilliseconds
            let endTime = sentence.endTime ?? sentenceWords.last?.endMilliseconds
            guard let beginTime, let endTime, endTime >= beginTime else { continue }

            let id = sentence.sentenceID ?? nextSegmentID
            nextSegmentID = max(nextSegmentID, id + 1)
            finalSegments[id] = TimedTranscriptSegment(
                id: id,
                startMilliseconds: beginTime,
                endMilliseconds: endTime,
                sourceText: text
            )

            if !sentenceWords.isEmpty {
                finalWords[id] = sentenceWords
            }
        }

        let orderedWords = finalWords
            .sorted { $0.key < $1.key }
            .flatMap(\.value)
        let segments: [TimedTranscriptSegment]
        let text: String
        if !orderedWords.isEmpty {
            segments = TimedTranscriptSegmenter.segment(orderedWords)
            text = TimedTranscriptSegmenter.renderText(from: orderedWords)
        } else {
            segments = finalSegments.values.sorted { $0.startMilliseconds < $1.startMilliseconds }
            text = latestText.isEmpty ? segments.map(\.sourceText).joined(separator: " ") : latestText
        }
        return FunASRTranscription(
            text: text,
            segments: segments,
            hasWordTimestamps: !orderedWords.isEmpty
        )
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
                    data: "data:audio/mp3;base64,\(audioData.base64EncodedString())"
                )
            )]
        ))

        return try JSONEncoder().encode(FunASRRequest(
            model: modelName,
            input: FunASRInput(messages: messages),
            parameters: FunASRParameters(
                format: "mp3",
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
    let sentenceID: Int?
    let sentenceEnd: Bool?
    let beginTime: Int?
    let endTime: Int?
    let words: [FunASRWord]?

    private enum CodingKeys: String, CodingKey {
        case text
        case sentenceID = "sentence_id"
        case sentenceEnd = "sentence_end"
        case beginTime = "begin_time"
        case endTime = "end_time"
        case words
    }
}

private struct FunASRWord: Decodable {
    let text: String?
    let beginTime: Int?
    let endTime: Int?
    let punctuation: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case beginTime = "begin_time"
        case endTime = "end_time"
        case punctuation
    }
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
            return "Fun-ASR 转写需要先保存 Fun-ASR API key。"
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
