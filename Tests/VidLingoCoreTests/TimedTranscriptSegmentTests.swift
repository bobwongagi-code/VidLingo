import XCTest
@testable import VidLingoCore

final class TimedTranscriptSegmentTests: XCTestCase {
    func testSRTEncodeAndDecodePreserveBilingualSegments() throws {
        let segments = [
            TimedTranscriptSegment(
                id: 1,
                startMilliseconds: 1_250,
                endMilliseconds: 3_480,
                sourceText: "原文第一句",
                translatedText: "第一句译文"
            ),
            TimedTranscriptSegment(
                id: 2,
                startMilliseconds: 4_000,
                endMilliseconds: 5_125,
                sourceText: "原文第二句",
                translatedText: "第二句译文"
            )
        ]

        let srt = SRTTimelineCodec.encode(segments)

        XCTAssertTrue(srt.contains("00:00:01,250 --> 00:00:03,480"))
        XCTAssertTrue(srt.contains("原文第一句\n第一句译文"))
        XCTAssertEqual(try SRTTimelineCodec.decode(srt), segments)
    }

    func testSRTDecodeSupportsSourceOnlySegments() throws {
        let srt = """
        1
        00:00:00,000 --> 00:00:01,500
        只有原文
        """

        let segments = try SRTTimelineCodec.decode(srt)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].sourceText, "只有原文")
        XCTAssertFalse(segments[0].hasTranslation)
    }

    func testTimedSegmentNormalizesNegativeStartTime() {
        let segment = TimedTranscriptSegment(
            id: 1,
            startMilliseconds: -500,
            endMilliseconds: -100,
            sourceText: "原文"
        )

        XCTAssertEqual(segment.startMilliseconds, 0)
        XCTAssertEqual(segment.endMilliseconds, 0)
    }

    func testSRTDecodeRejectsInvalidTimeRange() {
        let srt = """
        1
        00:00:03,000 --> 00:00:01,000
        无效片段
        """

        XCTAssertThrowsError(try SRTTimelineCodec.decode(srt)) { error in
            XCTAssertEqual(error as? SRTTimelineCodecError, .invalidTimeRange)
        }
    }
}
