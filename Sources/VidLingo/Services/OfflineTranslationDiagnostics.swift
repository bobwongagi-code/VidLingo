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
    let errorDescription: String?
}

enum OfflineTranslationDiagnostics {
    static func save(_ record: OfflineTranslationDiagnosticRecord) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let fileName = formatter.string(from: record.createdAt)
                .replacingOccurrences(of: ":", with: "-")
                + "-\(UUID().uuidString)"
                + ".json"
            let sanitizedRecord = OfflineTranslationDiagnosticRecord(
                createdAt: record.createdAt,
                languageID: record.languageID,
                videoDurationSeconds: record.videoDurationSeconds,
                outcome: record.outcome,
                stages: record.stages,
                errorDescription: record.errorDescription.map(sanitizedErrorDescription)
            )
            let data = try JSONEncoder.diagnostic.encode(sanitizedRecord)
            try data.write(to: directoryURL.appendingPathComponent(fileName), options: .atomic)
            prune()
        } catch {
            // 诊断写入不能阻断主翻译流程。
        }
    }

    static func clear() throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
    }

    static func sanitizedErrorDescription(_ text: String) -> String {
        var sanitized = text
            .replacingOccurrences(of: #"(?:/Users|/private/var|/var/folders|/tmp)/[^\s:\"']+"#, with: "<local-path>", options: .regularExpression)
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._-]+"#, with: "Bearer <redacted>", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?i)(?:api[-_ ]?key|xi-api-key|authorization)\s*[:=]\s*[^\s,;\"']+"#, with: "<credential-redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bsk[-_][A-Za-z0-9_-]{16,}\b"#, with: "<credential-redacted>", options: .regularExpression)
        if sanitized.count > 600 {
            sanitized = String(sanitized.prefix(600)) + "..."
        }
        return sanitized
    }

    private static func prune() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let sortedFiles = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        var totalBytes: Int64 = 0
        for (index, file) in sortedFiles.enumerated() {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            let fileSize = Int64(values?.fileSize ?? 0)
            let shouldRemove = modifiedAt < cutoff || index >= 100 || totalBytes + fileSize > 5 * 1_024 * 1_024
            if shouldRemove {
                try? fileManager.removeItem(at: file)
            } else {
                totalBytes += fileSize
            }
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
