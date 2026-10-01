import CryptoKit
import Foundation
import VidLingoCore

struct TranscriptRepository {
    let currentDirectoryURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        currentDirectoryURL = applicationSupportURL
            .appendingPathComponent("VidLingo", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
        self.fileManager = fileManager
    }

    init(
        currentDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.currentDirectoryURL = currentDirectoryURL
        self.fileManager = fileManager
    }

    func load() throws -> [SavedTranscript] {
        try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
        try ArtifactPublisher.removeStaleStagingDirectories(in: currentDirectoryURL, fileManager: fileManager)
        return try loadArtifacts(in: currentDirectoryURL)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func publish(
        sourceText: String,
        translatedText: String,
        sourceLanguage: LanguageOption?,
        targetLanguage: LanguageOption,
        provider: TranslationProviderID,
        modelName: String,
        videoFileName: String,
        kind: TranscriptArtifactKind,
        frameData: [Data] = [],
        timedSegments: [TimedTranscriptSegment] = []
    ) throws -> PublishedTranscriptArtifact {
        let manifest = TranscriptArtifactManifest(
            id: UUID().uuidString,
            createdAt: Date(),
            kind: kind,
            sourceLanguageID: sourceLanguage?.id,
            targetLanguageID: targetLanguage.id,
            providerID: provider.rawValue,
            modelName: modelName,
            videoFileName: videoFileName,
            frameCount: frameData.isEmpty ? nil : frameData.count,
            frameDigest: Self.frameDigest(frameData),
            timelineFileName: timedSegments.isEmpty ? nil : "bilingual.srt"
        )
        return try ArtifactPublisher.publish(
            sourceText: sourceText,
            translatedText: translatedText,
            manifest: manifest,
            in: currentDirectoryURL,
            timelineText: timedSegments.isEmpty ? nil : SRTTimelineCodec.encode(timedSegments),
            fileManager: fileManager
        )
    }

    @discardableResult
    func saveEdits(
        for transcript: SavedTranscript,
        sourceText: String,
        translatedText: String
    ) throws -> String {
        guard let translationFileURL = transcript.translationFileURL else {
            throw TranscriptRepositoryError.translationMissing
        }

        let oldManifest = transcript.manifest
        let timedSegments: [TimedTranscriptSegment]
        if sourceText == transcript.sourceText {
            timedSegments = translatedText == transcript.translatedText
                ? transcript.timedSegments
                : transcript.timedSegments.map { segment in
                    var sourceOnlySegment = segment
                    sourceOnlySegment.translatedText = nil
                    return sourceOnlySegment
                }
        } else {
            timedSegments = []
        }
        let manifest = TranscriptArtifactManifest(
            id: UUID().uuidString,
            createdAt: Date(),
            kind: oldManifest?.kind ?? transcript.artifactKind,
            sourceLanguageID: oldManifest?.sourceLanguageID,
            targetLanguageID: oldManifest?.targetLanguageID ?? "zh-CN",
            providerID: oldManifest?.providerID,
            modelName: oldManifest?.modelName,
            videoFileName: oldManifest?.videoFileName,
            frameCount: oldManifest?.frameCount,
            frameDigest: oldManifest?.frameDigest,
            timelineFileName: timedSegments.isEmpty ? nil : "bilingual.srt"
        )
        let publishedArtifact = try ArtifactPublisher.publish(
            sourceText: sourceText,
            translatedText: translatedText,
            manifest: manifest,
            in: currentDirectoryURL,
            timelineText: timedSegments.isEmpty ? nil : SRTTimelineCodec.encode(timedSegments),
            fileManager: fileManager
        )
        let publishedRecordID = "current:\(publishedArtifact.id)"

        do {
            if oldManifest != nil {
                try retireArtifactDirectory(at: transcript.sourceFileURL.deletingLastPathComponent())
            } else {
                try FilePairTransaction.retire(
                    sourceURL: transcript.sourceFileURL,
                    translationURL: translationFileURL,
                    fileManager: fileManager
                )
            }
        } catch {
            throw TranscriptRepositoryError.savedButRetirementFailed(
                recordID: publishedRecordID,
                message: error.localizedDescription
            )
        }
        return publishedRecordID
    }

    func delete(_ transcript: SavedTranscript) throws {
        if transcript.manifest != nil {
            try fileManager.removeItem(at: transcript.sourceFileURL.deletingLastPathComponent())
        } else {
            if let translationFileURL = transcript.translationFileURL {
                try FilePairTransaction.retire(
                    sourceURL: transcript.sourceFileURL,
                    translationURL: translationFileURL,
                    fileManager: fileManager
                )
            } else {
                try fileManager.removeItem(at: transcript.sourceFileURL)
            }
        }
    }

    func deleteAllCurrent(_ transcripts: [SavedTranscript]) -> TranscriptDeletionResult {
        var deletedIDs = [String]()
        var failedIDs = [String]()
        for transcript in transcripts {
            do {
                try delete(transcript)
                deletedIDs.append(transcript.id)
            } catch {
                failedIDs.append(transcript.id)
            }
        }
        return TranscriptDeletionResult(deletedIDs: deletedIDs, failedIDs: failedIDs)
    }

    private func loadArtifacts(in directoryURL: URL) throws -> [SavedTranscript] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let artifactRecords = entries.compactMap { loadArtifact(at: $0) }
        let flatRecords = entries
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent.hasSuffix("_original.txt") }
            .compactMap { loadFlatTranscript(at: $0) }
        return artifactRecords + flatRecords
    }

    private func retireArtifactDirectory(at directoryURL: URL) throws {
        let retiredDirectoryURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent(".staging-retired-\(UUID().uuidString)", isDirectory: true)
        // 新 artifact 已完整发布后，同目录改名隔离旧记录；过期暂存清理会回收残留目录。
        try fileManager.moveItem(at: directoryURL, to: retiredDirectoryURL)
        try fileManager.removeItem(at: retiredDirectoryURL)
    }

    private func loadArtifact(at directoryURL: URL) -> SavedTranscript? {
        guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let sourceURL = directoryURL.appendingPathComponent("original.txt")
        let translationURL = directoryURL.appendingPathComponent("translation.txt")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? decodeManifest(manifestData),
              let sourceText = try? String(contentsOf: sourceURL, encoding: .utf8),
              let translatedText = try? String(contentsOf: translationURL, encoding: .utf8) else {
            return nil
        }
        let updatedAt = (try? directoryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? manifest.createdAt
        let timedSegments = loadTimeline(from: directoryURL, manifest: manifest)
        return SavedTranscript(
            id: "current:\(manifest.id)",
            sourceFileURL: sourceURL,
            translationFileURL: translationURL,
            sourceText: sourceText,
            translatedText: translatedText,
            updatedAt: updatedAt,
            artifactKind: manifest.kind,
            manifest: manifest,
            timedSegments: timedSegments
        )
    }

    private func loadFlatTranscript(at originalURL: URL) -> SavedTranscript? {
        let suffix = "_original.txt"
        let stem = String(originalURL.lastPathComponent.dropLast(suffix.count))
        let translationURL = originalURL.deletingLastPathComponent().appendingPathComponent("\(stem)_translation.txt")
        guard let sourceText = try? String(contentsOf: originalURL, encoding: .utf8),
              let translatedText = try? String(contentsOf: translationURL, encoding: .utf8) else {
            return nil
        }
        let updatedAt = (try? originalURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return SavedTranscript(
            id: "current:\(originalURL.standardizedFileURL.path)",
            sourceFileURL: originalURL,
            translationFileURL: translationURL,
            sourceText: sourceText,
            translatedText: translatedText,
            updatedAt: updatedAt
        )
    }

    private func decodeManifest(_ data: Data) throws -> TranscriptArtifactManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptArtifactManifest.self, from: data)
    }

    private func loadTimeline(
        from directoryURL: URL,
        manifest: TranscriptArtifactManifest
    ) -> [TimedTranscriptSegment] {
        guard let fileName = manifest.timelineFileName,
              fileName.range(of: #"[/\\]"#, options: .regularExpression) == nil,
              let text = try? String(
                contentsOf: directoryURL.appendingPathComponent(fileName),
                encoding: .utf8
              ),
              let segments = try? SRTTimelineCodec.decode(text) else {
            return []
        }
        return segments
    }

    private static func frameDigest(_ frames: [Data]) -> String? {
        guard !frames.isEmpty else { return nil }
        var hasher = SHA256()
        for frame in frames {
            hasher.update(data: frame)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

}

struct TranscriptDeletionResult: Sendable, Equatable {
    let deletedIDs: [String]
    let failedIDs: [String]
}

enum TranscriptRepositoryError: LocalizedError, Equatable {
    case translationMissing
    case savedButRetirementFailed(recordID: String, message: String)

    var errorDescription: String? {
        switch self {
        case .translationMissing:
            AppText.translationMissing
        case let .savedButRetirementFailed(_, message):
            "修改已保存，但旧记录清理失败：\(message)"
        }
    }
}
