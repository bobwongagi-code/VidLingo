import Foundation

public struct TimedTranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let startMilliseconds: Int
    public let endMilliseconds: Int
    public let sourceText: String
    public var translatedText: String?

    public init(
        id: Int,
        startMilliseconds: Int,
        endMilliseconds: Int,
        sourceText: String,
        translatedText: String? = nil
    ) {
        let normalizedStart = max(0, startMilliseconds)
        self.id = id
        self.startMilliseconds = normalizedStart
        self.endMilliseconds = max(normalizedStart, endMilliseconds)
        self.sourceText = sourceText
        self.translatedText = translatedText
    }

    public var hasTranslation: Bool {
        !(translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public enum SRTTimelineCodecError: LocalizedError, Sendable, Equatable {
    case invalidFormat
    case invalidTimeRange

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "字幕时间轴格式无法解析。"
        case .invalidTimeRange:
            "字幕时间轴包含无效时间范围。"
        }
    }
}

public enum SRTTimelineCodec {
    public static func encode(_ segments: [TimedTranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            let source = normalizedLine(segment.sourceText)
            let translation = segment.hasTranslation ? normalizedLine(segment.translatedText ?? "") : nil
            let text = [source, translation].compactMap { $0 }.joined(separator: "\n")
            return "\(index + 1)\n\(timecode(segment.startMilliseconds)) --> \(timecode(segment.endMilliseconds))\n\(text)"
        }
        .joined(separator: "\n\n")
        + (segments.isEmpty ? "" : "\n")
    }

    public static func decode(_ text: String) throws -> [TimedTranscriptSegment] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var segments = [TimedTranscriptSegment]()
        for (index, block) in blocks.enumerated() {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3,
                  Int(lines[0].trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
                throw SRTTimelineCodecError.invalidFormat
            }

            let timeParts = lines[1].components(separatedBy: " --> ")
            guard timeParts.count == 2,
                  let start = parseTimecode(timeParts[0]),
                  let end = parseTimecode(timeParts[1]),
                  end >= start else {
                throw SRTTimelineCodecError.invalidTimeRange
            }

            let content = Array(lines.dropFirst(2))
            let source = content.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let translation = content.dropFirst()
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { throw SRTTimelineCodecError.invalidFormat }

            segments.append(TimedTranscriptSegment(
                id: index + 1,
                startMilliseconds: start,
                endMilliseconds: end,
                sourceText: source,
                translatedText: translation.isEmpty ? nil : translation
            ))
        }
        return segments
    }

    private static func normalizedLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timecode(_ milliseconds: Int) -> String {
        let totalMilliseconds = max(0, milliseconds)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let remainder = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }

    private static func parseTimecode(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]) else { return nil }
        let secondParts = parts[2].components(separatedBy: ",")
        guard secondParts.count == 2,
              let seconds = Int(secondParts[0]),
              let milliseconds = Int(secondParts[1]),
              hours >= 0,
              minutes >= 0, minutes < 60,
              seconds >= 0, seconds < 60,
              milliseconds >= 0, milliseconds < 1_000 else { return nil }
        return hours * 3_600_000 + minutes * 60_000 + seconds * 1_000 + milliseconds
    }
}
