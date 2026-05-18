import Foundation

enum SavedTranscriptContentMode: String, CaseIterable, Identifiable {
    case original
    case originalAndTranslation
    case translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:
            AppText.originalOnly
        case .originalAndTranslation:
            AppText.originalAndTranslation
        case .translation:
            AppText.translationOnly
        }
    }
}
