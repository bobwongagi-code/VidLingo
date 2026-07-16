import Foundation

struct OfflineTranslationStageTiming: Codable, Sendable {
    let name: String
    let milliseconds: Int
}

struct OfflineTranslationDiagnosticRecord: Codable, Sendable {
    let createdAt: Date
    let languageID: String?
    let videoDurationSeconds: Int?
    let outcome: String
    let stages: [OfflineTranslationStageTiming]
    let thai: ThaiTranscriptionDiagnostics?
    let errorDescription: String?
}

enum OfflineTranslationDiagnostics {
    static func save(_ record: OfflineTranslationDiagnosticRecord) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let fileName = formatter.string(from: record.createdAt)
                .replacingOccurrences(of: ":", with: "-")
                + ".json"
            let data = try JSONEncoder.diagnostic.encode(record)
            try data.write(to: directoryURL.appendingPathComponent(fileName), options: .atomic)
        } catch {
            // 诊断写入不能阻断主翻译流程。
        }
    }

    private static var directoryURL: URL {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupportURL
            .appendingPathComponent("VidLingo", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var diagnostic: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
