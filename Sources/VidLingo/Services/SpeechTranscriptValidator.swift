import Foundation

enum SpeechTranscriptValidator {
    static func hasEffectiveSpeechTranscript(_ text: String, language: LanguageOption) -> Bool {
        let normalizedText = text.lowercased()
        let hasSpeechCharacters = normalizedText.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        let loopText = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSpeechCharacters, loopText != "*trips*", loopText != "trips trips" else { return false }

        if usesUnspacedScript(language, text: loopText) {
            return !isRepetitionLoop(loopText)
        }

        let words = normalizedText
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        if words.count >= 6 {
            let uniqueWordRatio = Double(Set(words).count) / Double(words.count)
            if uniqueWordRatio < 0.35 { return false }
        }

        let lines = normalizedText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count >= 3, Set(lines).count <= max(1, lines.count / 3) {
            return false
        }

        return true
    }

    private static func usesUnspacedScript(_ language: LanguageOption, text: String) -> Bool {
        if ["th-TH", "zh-CN", "ja-JP"].contains(language.id) {
            return true
        }
        guard language.id == LanguageOption.undetermined.id,
              !text.contains(where: { $0.isWhitespace }) else {
            return false
        }
        return text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) && !(0x0041...0x024F).contains(Int($0.value))
        }
    }

    private static func isRepetitionLoop(_ text: String) -> Bool {
        let tokens = text.split { $0.isWhitespace }.map(String.init)
        if tokens.count >= 6 {
            let uniqueRatio = Double(Set(tokens).count) / Double(tokens.count)
            if uniqueRatio < 0.35 { return true }
        }

        let chars = Array(text)
        guard chars.count >= 18 else { return false }
        var grams = Set<String>()
        let total = chars.count - 2
        for index in 0..<total {
            grams.insert(String(chars[index..<index + 3]))
        }
        return Double(grams.count) / Double(total) < 0.25
    }

}
