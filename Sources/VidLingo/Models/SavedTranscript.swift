import Foundation
import VidLingoCore

enum TranscriptOrigin: String, Sendable {
    case current
    case legacyAirTranslate
}

struct SavedTranscript: Identifiable, Equatable {
    let id: String
    let origin: TranscriptOrigin
    let artifactKind: TranscriptArtifactKind
    let manifest: TranscriptArtifactManifest?
    var title: String
    var sourceText: String
    var translatedText: String?
    var sourceFileName: String
    var translationFileName: String?
    var sourceFileURL: URL
    var translationFileURL: URL?
    var timedSegments: [TimedTranscriptSegment]
    var updatedAt: Date

    var isLegacy: Bool { origin == .legacyAirTranslate }
    var isVisualGeneratedCopy: Bool { artifactKind == .visualGeneratedCopy }
    var hasTimeline: Bool { !timedSegments.isEmpty }

    var isOriginalAndTranslation: Bool {
        translatedText != nil && translationFileName != nil
    }

    init(
        fileURL: URL,
        sourceText: String,
        updatedAt: Date,
        origin: TranscriptOrigin = .current,
        artifactKind: TranscriptArtifactKind = .transcriptionTranslation,
        manifest: TranscriptArtifactManifest? = nil,
        timedSegments: [TimedTranscriptSegment] = []
    ) {
        let fileName = fileURL.lastPathComponent
        self.id = "\(origin.rawValue):\(fileURL.standardizedFileURL.path)"
        self.origin = origin
        self.artifactKind = artifactKind
        self.manifest = manifest
        self.title = SavedTranscript.title(from: sourceText, fallback: fileName)
        self.sourceText = sourceText
        self.translatedText = nil
        self.sourceFileName = fileName
        self.translationFileName = nil
        self.sourceFileURL = fileURL
        self.translationFileURL = nil
        self.timedSegments = timedSegments
        self.updatedAt = updatedAt
    }

    init(
        id: String,
        sourceFileURL: URL,
        translationFileURL: URL,
        sourceText: String,
        translatedText: String,
        updatedAt: Date,
        origin: TranscriptOrigin = .current,
        artifactKind: TranscriptArtifactKind = .transcriptionTranslation,
        manifest: TranscriptArtifactManifest? = nil,
        timedSegments: [TimedTranscriptSegment] = []
    ) {
        self.id = id
        self.origin = origin
        self.artifactKind = artifactKind
        self.manifest = manifest
        self.title = SavedTranscript.title(from: sourceText, fallback: id)
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceFileName = sourceFileURL.lastPathComponent
        self.translationFileName = translationFileURL.lastPathComponent
        self.sourceFileURL = sourceFileURL
        self.translationFileURL = translationFileURL
        self.timedSegments = timedSegments
        self.updatedAt = updatedAt
    }

    private static func title(from text: String, fallback: String) -> String {
        let title = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            return fallback.replacingOccurrences(of: ".txt", with: "")
        }

        return String(title.prefix(48))
    }
}
