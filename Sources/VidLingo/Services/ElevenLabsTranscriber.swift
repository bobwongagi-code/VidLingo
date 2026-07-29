import Foundation

struct ElevenLabsQuota: Codable, Sendable {
    let tier: String
    let usedCredits: Int
    let creditLimit: Int
    let nextReset: Date?

    var remainingCredits: Int {
        max(0, creditLimit - usedCredits)
    }
}

struct ElevenLabsWord: Codable, Sendable {
    let text: String
    let start: Double?
    let end: Double?
    let type: String
    let logprob: Double?
}

struct ElevenLabsTranscript: Codable, Sendable {
    let modelID: String
    let requestID: String?
    let languageCode: String?
    let languageProbability: Double?
    let text: String
    let words: [ElevenLabsWord]
}

enum ElevenLabsTranscriber {
    static let modelID = "scribe_v2"
    private static let creditsPerMinute = 330.0
    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private static let subscriptionEndpoint = URL(string: "https://api.elevenlabs.io/v1/user/subscription")!

    static func estimatedCredits(duration: Double) -> Int {
        let baseEstimate = max(duration, 0) / 60 * creditsPerMinute
        return Int(ceil(baseEstimate * 1.15)) + 10
    }

    static func quota(apiKey: String, token: ProcessCancellationToken) async throws -> ElevenLabsQuota {
        try token.check()
        var request = URLRequest(url: subscriptionEndpoint)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(SubscriptionResponse.self, from: data)
        try token.check()
        return ElevenLabsQuota(
            tier: payload.tier,
            usedCredits: payload.characterCount,
            creditLimit: payload.characterLimit,
            nextReset: payload.nextCharacterCountResetUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    static func transcribeThai(
        audioURL: URL,
        apiKey: String,
        token: ProcessCancellationToken
    ) async throws -> ElevenLabsTranscript {
        try token.check()
        let boundary = "VidLingo-\(UUID().uuidString)"
        let uploadURL = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent("elevenlabs-\(UUID().uuidString).multipart")
        var prefix = Data()
        prefix.appendMultipartField(name: "model_id", value: modelID, boundary: boundary)
        prefix.appendMultipartField(name: "language_code", value: "tha", boundary: boundary)
        prefix.appendMultipartField(name: "timestamps_granularity", value: "word", boundary: boundary)
        prefix.appendMultipartField(name: "diarize", value: "false", boundary: boundary)
        prefix.appendMultipartField(name: "tag_audio_events", value: "false", boundary: boundary)
        prefix.appendMultipartField(name: "no_verbatim", value: "false", boundary: boundary)
        prefix.appendMultipartField(name: "temperature", value: "0", boundary: boundary)
        prefix.appendString("--\(boundary)\r\n")
        prefix.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        prefix.appendString("Content-Type: audio/wav\r\n\r\n")
        try prefix.write(to: uploadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: uploadURL) }
        let uploadHandle = try FileHandle(forWritingTo: uploadURL)
        defer {
            try? uploadHandle.close()
        }
        try uploadHandle.seekToEnd()
        let audioHandle = try FileHandle(forReadingFrom: audioURL)
        defer { try? audioHandle.close() }
        while let chunk = try audioHandle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try token.check()
            try uploadHandle.write(contentsOf: chunk)
        }
        try uploadHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try uploadHandle.close()
        let contentLength = (try uploadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(String.init)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let contentLength {
            request.setValue(contentLength, forHTTPHeaderField: "Content-Length")
        }
        request.httpBodyStream = InputStream(fileAtPath: uploadURL.path)

        let (data, response) = try await session.data(for: request)
        try token.check()
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(TranscriptResponse.self, from: data)
        let requestID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id")
        return ElevenLabsTranscript(
            modelID: modelID,
            requestID: requestID,
            languageCode: payload.languageCode,
            languageProbability: payload.languageProbability,
            text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: payload.words
        )
    }

    static func isTrustedTeacher(_ transcript: ElevenLabsTranscript) -> Bool {
        guard transcript.text.count >= 12,
              !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let languageScalars = transcript.text.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
        let thaiScalars = languageScalars.filter { (0x0E00...0x0E7F).contains(Int($0.value)) }
        guard !languageScalars.isEmpty,
              Double(thaiScalars.count) / Double(languageScalars.count) >= 0.80 else {
            return false
        }
        if let probability = transcript.languageProbability, probability < 0.70 {
            return false
        }
        let wordProbabilities = transcript.words.compactMap(\.logprob)
        if !wordProbabilities.isEmpty {
            let reliableCount = wordProbabilities.filter { $0 >= -1.0 }.count
            if Double(reliableCount) / Double(wordProbabilities.count) < 0.70 {
                return false
            }
        }
        let normalized = transcript.text.replacingOccurrences(of: " ", with: "")
        guard normalized.count >= 18 else { return true }
        let characters = Array(normalized)
        let grams = Set((0...(characters.count - 3)).map { String(characters[$0...($0 + 2)]) })
        return Double(grams.count) / Double(characters.count - 2) >= 0.25
    }

    private static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        return URLSession(configuration: configuration)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(500)
            throw ElevenLabsError.requestFailed(httpResponse.statusCode, detail.map(String.init))
        }
    }
}

private struct SubscriptionResponse: Decodable {
    let tier: String
    let characterCount: Int
    let characterLimit: Int
    let nextCharacterCountResetUnix: Int?

    enum CodingKeys: String, CodingKey {
        case tier
        case characterCount = "character_count"
        case characterLimit = "character_limit"
        case nextCharacterCountResetUnix = "next_character_count_reset_unix"
    }
}

private struct TranscriptResponse: Decodable {
    let languageCode: String?
    let languageProbability: Double?
    let text: String
    let words: [ElevenLabsWord]

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case languageProbability = "language_probability"
        case text
        case words
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8) ?? Data())
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

}

enum ElevenLabsError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "ElevenLabs 返回了无效响应。"
        case let .requestFailed(statusCode, detail):
            let safeDetail = detail.map(OfflineTranslationDiagnostics.sanitizedErrorDescription)
            return "ElevenLabs 请求失败（\(statusCode)）\(safeDetail.map { "：\($0)" } ?? "")"
        }
    }
}
