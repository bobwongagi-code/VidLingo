import Foundation

enum LanguageTextDetector {
    static func detect(_ text: String) -> LanguageOption? {
        let ranked = LanguageOption.supported
            .map { language in
                (language: language, score: score(transcript: text, language: language))
            }
            .sorted { $0.score > $1.score }

        guard let best = ranked.first, best.score >= 0.35 else { return nil }
        if let runnerUp = ranked.dropFirst().first,
           best.score - runnerUp.score < 0.08 {
            return nil
        }
        return best.language
    }

    private static func score(transcript: String, language: LanguageOption) -> Double {
        let normalizedText = transcript.lowercased()
        let scalars = Array(normalizedText.unicodeScalars)
        guard scalars.count >= 4 else { return 0 }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }

        func ratio(_ predicate: (UnicodeScalar) -> Bool) -> Double {
            Double(letters.filter(predicate).count) / Double(letters.count)
        }
        var score: Double
        switch language.id {
        case "th-TH":
            score = ratio { (0x0E00...0x0E7F).contains(Int($0.value)) }
        case "zh-CN":
            score = ratio { (0x4E00...0x9FFF).contains(Int($0.value)) }
        case "ja-JP":
            score = ratio {
                (0x3040...0x30FF).contains(Int($0.value))
                    || (0x4E00...0x9FFF).contains(Int($0.value))
            }
        case "ko-KR":
            score = ratio { (0xAC00...0xD7AF).contains(Int($0.value)) }
        default:
            let latinRatio = ratio { ($0.value >= 0x0041 && $0.value <= 0x024F) }
            let words = normalizedText
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
            let wordSet = Set(words)
            func markerScore(_ markers: [String]) -> Double {
                min(0.45, Double(markers.filter { wordSet.contains($0) }.count) * 0.08)
            }
            score = latinRatio * 0.55
            switch language.id {
            case "en-US":
                score += markerScore(["the", "and", "you", "this", "is", "to", "of", "for"])
            case "ms-MY":
                score += markerScore(["yang", "dan", "ini", "itu", "saya", "nak", "boleh", "untuk", "dengan"])
            case "id-ID":
                score += markerScore(["yang", "dan", "ini", "itu", "saya", "bisa", "untuk", "dengan", "ada"])
            case "es-ES":
                score += markerScore(["que", "el", "la", "de", "para", "con", "una", "por"])
            case "fr-FR":
                score += markerScore(["le", "la", "les", "de", "pour", "avec", "une", "est"])
            case "de-DE":
                score += markerScore(["der", "die", "das", "und", "mit", "für", "eine", "ist"])
            default:
                break
            }
            if words.count < 3 {
                score *= 0.7
            }
        }

        let repetitionPenalty = min(0.4, Double(repeatedLineCount(in: normalizedText)) * 0.08)
        return max(0, min(1, score - repetitionPenalty))
    }

    private static func repeatedLineCount(in text: String) -> Int {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(0, lines.count - Set(lines).count)
    }
}
