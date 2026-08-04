import Foundation

public struct TimedTranscriptWord: Sendable, Equatable {
    public let startMilliseconds: Int
    public let endMilliseconds: Int
    public let text: String
    public let punctuation: String

    public init(
        startMilliseconds: Int,
        endMilliseconds: Int,
        text: String,
        punctuation: String = ""
    ) {
        let normalizedStart = max(0, startMilliseconds)
        self.startMilliseconds = normalizedStart
        self.endMilliseconds = max(normalizedStart, endMilliseconds)
        self.text = text
        self.punctuation = punctuation
    }

    var renderedText: String {
        guard !punctuation.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(punctuation) else {
            return text
        }
        return text + punctuation
    }
}

public enum TimedTranscriptSegmenter {
    public static let minimumDurationMilliseconds = 1_500
    public static let preferredMinimumDurationMilliseconds = 3_000
    public static let preferredMaximumDurationMilliseconds = 7_000
    public static let maximumDurationMilliseconds = 8_000

    private static let strongPauseMilliseconds = 650
    private static let candidatePauseMilliseconds = 300
    private static let targetDurationMilliseconds = 5_000
    private static let terminalPunctuation = CharacterSet(charactersIn: ".!?。！？")
    private static let softPunctuation = CharacterSet(charactersIn: ",;:，；：、")

    public static func renderText(from words: [TimedTranscriptWord]) -> String {
        words.map(\.renderedText)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func segment(_ words: [TimedTranscriptWord]) -> [TimedTranscriptSegment] {
        let orderedWords = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.startMilliseconds == $1.startMilliseconds {
                    return $0.endMilliseconds < $1.endMilliseconds
                }
                return $0.startMilliseconds < $1.startMilliseconds
            }
        guard !orderedWords.isEmpty else { return [] }

        var ranges = [(start: Int, end: Int)]()
        var startIndex = 0
        while startIndex < orderedWords.count {
            let endIndex = chooseEndIndex(from: orderedWords, startIndex: startIndex)
            ranges.append((start: startIndex, end: endIndex))
            startIndex = endIndex
        }

        ranges = mergeShortRanges(ranges, words: orderedWords)
        return ranges.enumerated().map { index, range in
            let rangeWords = Array(orderedWords[range.start..<range.end])
            return TimedTranscriptSegment(
                id: index + 1,
                startMilliseconds: rangeWords.first?.startMilliseconds ?? 0,
                endMilliseconds: rangeWords.last?.endMilliseconds ?? 0,
                sourceText: renderText(from: rangeWords)
            )
        }
    }

    private static func chooseEndIndex(
        from words: [TimedTranscriptWord],
        startIndex: Int
    ) -> Int {
        let lastIndex = words.count - 1
        guard startIndex < lastIndex else { return words.count }

        let startTime = words[startIndex].startMilliseconds
        let maxEndTime = startTime + maximumDurationMilliseconds
        let candidateEndIndexes = (startIndex + 1...lastIndex + 1).filter { endIndex in
            let lastWordIndex = endIndex - 1
            return words[lastWordIndex].endMilliseconds <= maxEndTime
        }
        guard !candidateEndIndexes.isEmpty else { return min(startIndex + 1, words.count) }

        let minimumEndIndex = candidateEndIndexes.first { endIndex in
            duration(of: words, startIndex: startIndex, endIndex: endIndex) >= minimumDurationMilliseconds
        }

        let eligibleEndIndexes = candidateEndIndexes.filter { endIndex in
            guard let minimumEndIndex else { return true }
            return endIndex >= minimumEndIndex
        }
        guard let selected = eligibleEndIndexes.max(by: { lhs, rhs in
            boundaryScore(
                words: words,
                startIndex: startIndex,
                endIndex: lhs
            ) < boundaryScore(
                words: words,
                startIndex: startIndex,
                endIndex: rhs
            )
        }) else {
            return min(startIndex + 1, words.count)
        }
        return selected
    }

    private static func boundaryScore(
        words: [TimedTranscriptWord],
        startIndex: Int,
        endIndex: Int
    ) -> Int {
        let duration = duration(of: words, startIndex: startIndex, endIndex: endIndex)
        var score = 0

        if endIndex < words.count {
            let previous = words[endIndex - 1]
            let next = words[endIndex]
            let gap = next.startMilliseconds - previous.endMilliseconds
            if gap >= strongPauseMilliseconds {
                score += 1_800
            } else if gap >= candidatePauseMilliseconds {
                score += 700
            }
        }

        let previousText = words[endIndex - 1].renderedText
        if containsAnyPunctuation(previousText, in: terminalPunctuation) {
            score += 2_000
        } else if containsAnyPunctuation(previousText, in: softPunctuation) {
            score += 450
        }

        if duration >= preferredMinimumDurationMilliseconds,
           duration <= preferredMaximumDurationMilliseconds {
            score += 300
        } else if duration < preferredMinimumDurationMilliseconds {
            score -= (preferredMinimumDurationMilliseconds - duration) / 20
        } else {
            score -= (duration - preferredMaximumDurationMilliseconds) / 20
        }

        score -= abs(duration - targetDurationMilliseconds) / 100
        return score
    }

    private static func duration(
        of words: [TimedTranscriptWord],
        startIndex: Int,
        endIndex: Int
    ) -> Int {
        guard startIndex < endIndex,
              let first = words[safe: startIndex],
              let last = words[safe: endIndex - 1] else { return 0 }
        return max(0, last.endMilliseconds - first.startMilliseconds)
    }

    private static func mergeShortRanges(
        _ ranges: [(start: Int, end: Int)],
        words: [TimedTranscriptWord]
    ) -> [(start: Int, end: Int)] {
        guard ranges.count > 1 else { return ranges }
        var merged = [(start: Int, end: Int)]()

        var index = 0
        while index < ranges.count {
            let range = ranges[index]
            let rangeDuration = duration(of: words, startIndex: range.start, endIndex: range.end)

            if rangeDuration < minimumDurationMilliseconds,
               let previous = merged.last,
               duration(of: words, startIndex: previous.start, endIndex: range.end) <= maximumDurationMilliseconds {
                merged[merged.count - 1] = (previous.start, range.end)
                index += 1
                continue
            }

            if rangeDuration < minimumDurationMilliseconds,
               index + 1 < ranges.count {
                let next = ranges[index + 1]
                if duration(of: words, startIndex: range.start, endIndex: next.end) <= maximumDurationMilliseconds {
                    merged.append((range.start, next.end))
                    index += 2
                    continue
                }
            }

            merged.append(range)
            index += 1
        }
        return merged
    }

    private static func containsAnyPunctuation(_ text: String, in characterSet: CharacterSet) -> Bool {
        text.unicodeScalars.contains { characterSet.contains($0) }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
