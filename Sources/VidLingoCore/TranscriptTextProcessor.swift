import Foundation

package enum TranscriptTextProcessor {
    package static func organizeTranscript(_ text: String, languageID: String) -> String {
        paragraphParts(from: text)
            .map { organizeParagraph($0, languageID: languageID) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    package static func organizeParagraph(_ text: String, languageID: String) -> String {
        var organized = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        organized = organized.replacingOccurrences(
            of: #"([.!?。！？]+)\s+"#,
            with: "$1\n",
            options: .regularExpression
        )

        if languageID == "ko-KR" {
            organized = organized.replacingOccurrences(
                of: #"(습니다|니다|어요|아요|세요|군요|네요|죠|지요|다)\s+"#,
                with: "$1\n",
                options: .regularExpression
            )
        }

        return organized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    package static func paragraphParts(from text: String) -> [String] {
        let marker = "\u{1E}"
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]*\n{2,}[ \t]*"#, with: marker, options: .regularExpression)

        return normalized
            .components(separatedBy: marker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    package static func normalizedForComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
