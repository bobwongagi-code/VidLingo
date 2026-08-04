import Foundation

public enum TranscriptArtifactKind: String, Codable, Sendable, Equatable {
    case transcriptionTranslation
    case visualGeneratedCopy
}

public struct TranscriptArtifactManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let createdAt: Date
    public let kind: TranscriptArtifactKind
    public let sourceLanguageID: String?
    public let targetLanguageID: String?
    public let providerID: String?
    public let modelName: String?
    public let videoFileName: String?
    public let sourceIdentity: String?
    public let frameCount: Int?
    public let frameDigest: String?
    public let timelineFileName: String?

    public init(
        id: String,
        createdAt: Date,
        kind: TranscriptArtifactKind,
        sourceLanguageID: String?,
        targetLanguageID: String?,
        providerID: String?,
        modelName: String?,
        videoFileName: String?,
        sourceIdentity: String? = nil,
        frameCount: Int? = nil,
        frameDigest: String? = nil,
        timelineFileName: String? = nil
    ) {
        self.schemaVersion = 2
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sourceLanguageID = sourceLanguageID
        self.targetLanguageID = targetLanguageID
        self.providerID = providerID
        self.modelName = modelName
        self.videoFileName = videoFileName
        self.sourceIdentity = sourceIdentity
        self.frameCount = frameCount
        self.frameDigest = frameDigest
        self.timelineFileName = timelineFileName
    }
}

public struct PublishedTranscriptArtifact: Sendable {
    public let id: String
    public let directoryURL: URL
    public let sourceFileURL: URL
    public let translationFileURL: URL
    public let manifestFileURL: URL
    public let timelineFileURL: URL?
    public let manifest: TranscriptArtifactManifest
}

public enum ArtifactPublisherError: LocalizedError, Sendable {
    case invalidContent
    case destinationUnavailable
    case destinationAlreadyExists
    case commitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidContent:
            "原文和译文不能为空。"
        case .destinationUnavailable:
            "资料库目录不可用。"
        case .destinationAlreadyExists:
            "资料库中已存在同名结果。"
        case let .commitFailed(message):
            "资料库提交失败：\(message)"
        }
    }
}

public enum ArtifactPublisher {
    public static func publish(
        sourceText: String,
        translatedText: String,
        manifest: TranscriptArtifactManifest,
        in directoryURL: URL,
        timelineText: String? = nil,
        fileManager: FileManager = .default
    ) throws -> PublishedTranscriptArtifact {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtifactPublisherError.invalidContent
        }

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let artifactID = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artifactID.isEmpty,
              artifactID.range(of: #"[/\\]"#, options: .regularExpression) == nil else {
            throw ArtifactPublisherError.destinationUnavailable
        }

        let finalDirectoryURL = directoryURL.appendingPathComponent(artifactID, isDirectory: true)
        guard !fileManager.fileExists(atPath: finalDirectoryURL.path) else {
            throw ArtifactPublisherError.destinationAlreadyExists
        }

        let stagingDirectoryURL = directoryURL.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
            let sourceFileURL = stagingDirectoryURL.appendingPathComponent("original.txt")
            let translationFileURL = stagingDirectoryURL.appendingPathComponent("translation.txt")
            let manifestFileURL = stagingDirectoryURL.appendingPathComponent("manifest.json")
            try sourceText.write(to: sourceFileURL, atomically: true, encoding: .utf8)
            try translatedText.write(to: translationFileURL, atomically: true, encoding: .utf8)
            let timelineFileURL: URL?
            if let timelineText,
               !timelineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let timelineFileName = manifest.timelineFileName {
                guard timelineFileName.range(of: #"[/\\]"#, options: .regularExpression) == nil,
                      !timelineFileName.isEmpty else {
                    throw ArtifactPublisherError.destinationUnavailable
                }
                let url = stagingDirectoryURL.appendingPathComponent(timelineFileName)
                try timelineText.write(to: url, atomically: true, encoding: .utf8)
                timelineFileURL = url
            } else {
                timelineFileURL = nil
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestFileURL, options: .atomic)
            try fileManager.moveItem(at: stagingDirectoryURL, to: finalDirectoryURL)

            return PublishedTranscriptArtifact(
                id: artifactID,
                directoryURL: finalDirectoryURL,
                sourceFileURL: finalDirectoryURL.appendingPathComponent("original.txt"),
                translationFileURL: finalDirectoryURL.appendingPathComponent("translation.txt"),
                manifestFileURL: finalDirectoryURL.appendingPathComponent("manifest.json"),
                timelineFileURL: timelineFileURL.map { finalDirectoryURL.appendingPathComponent($0.lastPathComponent) },
                manifest: manifest
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw ArtifactPublisherError.commitFailed(error.localizedDescription)
        }
    }

    public static func removeStaleStagingDirectories(
        in directoryURL: URL,
        olderThan age: TimeInterval = 60 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= age else {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }
}
