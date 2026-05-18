import Foundation

struct SavedTranscript: Identifiable, Equatable {
    let id: String
    var title: String
    var sourceText: String
    var translatedText: String?
    var sourceFileName: String
    var translationFileName: String?
    var sourceFileURL: URL
    var translationFileURL: URL?
    var updatedAt: Date

    var isOriginalAndTranslation: Bool {
        translatedText != nil && translationFileName != nil
    }

    init(
        fileURL: URL,
        sourceText: String,
        updatedAt: Date
    ) {
        let fileName = fileURL.lastPathComponent
        self.id = fileName
        self.title = SavedTranscript.title(from: sourceText, fallback: fileName)
        self.sourceText = sourceText
        self.translatedText = nil
        self.sourceFileName = fileName
        self.translationFileName = nil
        self.sourceFileURL = fileURL
        self.translationFileURL = nil
        self.updatedAt = updatedAt
    }

    init(
        id: String,
        sourceFileURL: URL,
        translationFileURL: URL,
        sourceText: String,
        translatedText: String,
        updatedAt: Date
    ) {
        self.id = id
        self.title = SavedTranscript.title(from: sourceText, fallback: id)
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceFileName = sourceFileURL.lastPathComponent
        self.translationFileName = translationFileURL.lastPathComponent
        self.sourceFileURL = sourceFileURL
        self.translationFileURL = translationFileURL
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
