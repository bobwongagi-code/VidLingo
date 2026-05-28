import Foundation

struct CaptionLine: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let translatedSourceText: String
    let createdAt: Date
    let isFinal: Bool
    let revision: Int

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        translatedSourceText: String = "",
        createdAt: Date,
        isFinal: Bool,
        revision: Int = 0
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.translatedSourceText = translatedSourceText
        self.createdAt = createdAt
        self.isFinal = isFinal
        self.revision = revision
    }
}
