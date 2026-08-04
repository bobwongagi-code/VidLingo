import XCTest
@testable import VidLingoCore

final class TimedTranscriptSegmenterTests: XCTestCase {
    func testContinuousSpeechIsSplitIntoUsefulSizedSegments() {
        let words = (0..<10).map { index in
            TimedTranscriptWord(
                startMilliseconds: index * 800,
                endMilliseconds: index * 800 + 700,
                text: "词\(index) "
            )
        }

        let segments = TimedTranscriptSegmenter.segment(words)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertLessThanOrEqual(segments.count, 4)
        XCTAssertTrue(segments.allSatisfy {
            $0.endMilliseconds - $0.startMilliseconds <= TimedTranscriptSegmenter.maximumDurationMilliseconds
        })
        let combinedSource = segments.map(\.sourceText).joined()
            .replacingOccurrences(of: " ", with: "")
        let expectedSource = words.map(\.renderedText).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(combinedSource, expectedSource)
    }

    func testFiftyThreeSecondSpeechStaysWithinExpectedRowCount() {
        let words = (0..<120).map { index in
            TimedTranscriptWord(
                startMilliseconds: index * 450,
                endMilliseconds: index * 450 + 350,
                text: "词\(index)"
            )
        }

        let segments = TimedTranscriptSegmenter.segment(words)

        XCTAssertGreaterThanOrEqual(segments.count, 8)
        XCTAssertLessThanOrEqual(segments.count, 15)
        XCTAssertTrue(segments.allSatisfy {
            $0.endMilliseconds - $0.startMilliseconds <= TimedTranscriptSegmenter.maximumDurationMilliseconds
        })
    }

    func testStrongPauseAndTerminalPunctuationArePreferredBoundaries() {
        let words = [
            TimedTranscriptWord(startMilliseconds: 0, endMilliseconds: 1_500, text: "开场", punctuation: "。"),
            TimedTranscriptWord(startMilliseconds: 2_300, endMilliseconds: 3_600, text: "卖点"),
            TimedTranscriptWord(startMilliseconds: 3_950, endMilliseconds: 5_000, text: "结尾", punctuation: "！")
        ]

        let segments = TimedTranscriptSegmenter.segment(words)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].sourceText, "开场。")
        XCTAssertEqual(segments[1].sourceText, "卖点结尾！")
    }

    func testDoesNotCreateAnUnnecessaryTinyTrailingSegment() {
        let words = [
            TimedTranscriptWord(startMilliseconds: 0, endMilliseconds: 4_500, text: "主体"),
            TimedTranscriptWord(startMilliseconds: 4_700, endMilliseconds: 5_300, text: "补充")
        ]

        let segments = TimedTranscriptSegmenter.segment(words)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].sourceText, "主体补充")
    }
}
