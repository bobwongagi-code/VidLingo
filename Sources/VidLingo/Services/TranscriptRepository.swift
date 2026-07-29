import CryptoKit
import Foundation
import VidLingoCore

struct TranscriptRepository {
    let currentDirectoryURL: URL
    let legacyDirectoryURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        currentDirectoryURL = applicationSupportURL
            .appendingPathComponent("VidLingo", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
        legacyDirectoryURL = applicationSupportURL
            .appendingPathComponent("AirTranslate", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
        self.fileManager = fileManager
    }

    init(
        currentDirectoryURL: URL,
        legacyDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.currentDirectoryURL = currentDirectoryURL
        self.legacyDirectoryURL = legacyDirectoryURL
        self.fileManager = fileManager
    }

    func load() throws -> [SavedTranscript] {
        try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
        try ArtifactPublisher.removeStaleStagingDirectories(in: currentDirectoryURL, fileManager: fileManager)
        return (try loadArtifacts(in: currentDirectoryURL, origin: .current)
            + loadArtifacts(in: legacyDirectoryURL, origin: .legacyAirTranslate))
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
        sourceIdentity: String? = nil
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
            sourceIdentity: sourceIdentity,
            frameCount: frameData.isEmpty ? nil : frameData.count,
            frameDigest: Self.frameDigest(frameData)
        )
        return try ArtifactPublisher.publish(
            sourceText: sourceText,
            translatedText: translatedText,
            manifest: manifest,
            in: currentDirectoryURL,
            fileManager: fileManager
        )
    }

    func saveEdits(
        for transcript: SavedTranscript,
        sourceText: String,
        translatedText: String
    ) throws {
        guard !transcript.isLegacy else {
            throw TranscriptRepositoryError.legacyReadOnly
        }
        guard let translationFileURL = transcript.translationFileURL else {
            throw TranscriptRepositoryError.translationMissing
        }

        let oldManifest = transcript.manifest
        let manifest = TranscriptArtifactManifest(
            id: UUID().uuidString,
            createdAt: Date(),
            kind: oldManifest?.kind ?? transcript.artifactKind,
            sourceLanguageID: oldManifest?.sourceLanguageID,
            targetLanguageID: oldManifest?.targetLanguageID ?? "zh-CN",
            providerID: oldManifest?.providerID,
            modelName: oldManifest?.modelName,
            videoFileName: oldManifest?.videoFileName,
            sourceIdentity: oldManifest?.sourceIdentity,
            frameCount: oldManifest?.frameCount,
            frameDigest: oldManifest?.frameDigest
        )
        let published = try ArtifactPublisher.publish(
            sourceText: sourceText,
            translatedText: translatedText,
            manifest: manifest,
            in: currentDirectoryURL,
            fileManager: fileManager
        )

        do {
            if oldManifest != nil {
                try fileManager.removeItem(at: transcript.sourceFileURL.deletingLastPathComponent())
            } else {
                try FilePairTransaction.retire(
                    sourceURL: transcript.sourceFileURL,
                    translationURL: translationFileURL,
                    fileManager: fileManager
                )
            }
        } catch {
            do {
                try fileManager.removeItem(at: published.directoryURL)
            } catch {
                throw TranscriptRepositoryError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    func delete(_ transcript: SavedTranscript) throws {
        guard !transcript.isLegacy else {
            throw TranscriptRepositoryError.legacyReadOnly
        }
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

    func deleteAllCurrent(_ transcripts: [SavedTranscript]) -> Int {
        var failures = 0
        for transcript in transcripts where !transcript.isLegacy {
            do {
                try delete(transcript)
            } catch {
                failures += 1
            }
        }
        return failures
    }

    func importLegacy(_ transcripts: [SavedTranscript]) -> (imported: Int, skipped: Int, failed: Int) {
        var imported = 0
        var skipped = 0
        var failed = 0
        for transcript in transcripts where transcript.isLegacy {
            do {
                let sourceIdentity = transcript.sourceFileURL.standardizedFileURL.path
                let manifest = TranscriptArtifactManifest(
                    id: Self.legacyImportID(for: sourceIdentity),
                    createdAt: Date(),
                    kind: transcript.artifactKind,
                    sourceLanguageID: nil,
                    targetLanguageID: "zh-CN",
                    providerID: "legacy-airtranslate",
                    modelName: nil,
                    videoFileName: nil,
                    sourceIdentity: sourceIdentity
                )
                _ = try ArtifactPublisher.publish(
                    sourceText: transcript.sourceText,
                    translatedText: transcript.translatedText ?? "",
                    manifest: manifest,
                    in: currentDirectoryURL,
                    fileManager: fileManager
                )
                imported += 1
            } catch ArtifactPublisherError.destinationAlreadyExists {
                skipped += 1
            } catch {
                failed += 1
            }
        }
        return (imported, skipped, failed)
    }

    private func loadArtifacts(in directoryURL: URL, origin: TranscriptOrigin) throws -> [SavedTranscript] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let artifactRecords = entries.compactMap { loadArtifact(at: $0, origin: origin) }
        let flatRecords = entries
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent.hasSuffix("_original.txt") }
            .compactMap { loadFlatTranscript(at: $0, origin: origin) }
        return artifactRecords + flatRecords
    }

    private func loadArtifact(at directoryURL: URL, origin: TranscriptOrigin) -> SavedTranscript? {
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
        return SavedTranscript(
            id: "\(origin.rawValue):\(manifest.id)",
            sourceFileURL: sourceURL,
            translationFileURL: translationURL,
            sourceText: sourceText,
            translatedText: translatedText,
            updatedAt: updatedAt,
            origin: origin,
            artifactKind: manifest.kind,
            manifest: manifest
        )
    }

    private func loadFlatTranscript(at originalURL: URL, origin: TranscriptOrigin) -> SavedTranscript? {
        let suffix = "_original.txt"
        let stem = String(originalURL.lastPathComponent.dropLast(suffix.count))
        let translationURL = originalURL.deletingLastPathComponent().appendingPathComponent("\(stem)_translation.txt")
        guard let sourceText = try? String(contentsOf: originalURL, encoding: .utf8),
              let translatedText = try? String(contentsOf: translationURL, encoding: .utf8) else {
            return nil
        }
        let updatedAt = (try? originalURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return SavedTranscript(
            id: "\(origin.rawValue):\(originalURL.standardizedFileURL.path)",
            sourceFileURL: originalURL,
            translationFileURL: translationURL,
            sourceText: sourceText,
            translatedText: translatedText,
            updatedAt: updatedAt,
            origin: origin
        )
    }

    private func decodeManifest(_ data: Data) throws -> TranscriptArtifactManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptArtifactManifest.self, from: data)
    }

    private static func frameDigest(_ frames: [Data]) -> String? {
        guard !frames.isEmpty else { return nil }
        var hasher = SHA256()
        for frame in frames {
            hasher.update(data: frame)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyImportID(for sourceIdentity: String) -> String {
        let digest = SHA256.hash(data: Data(sourceIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "legacy-\(digest)"
    }
}

enum TranscriptRepositoryError: LocalizedError {
    case translationMissing
    case legacyReadOnly
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .translationMissing:
            AppText.translationMissing
        case .legacyReadOnly:
            AppText.legacyTranscriptReadOnly
        case let .rollbackFailed(message):
            "资料库保存失败，旧记录仍需人工检查：\(message)"
        }
    }
}
