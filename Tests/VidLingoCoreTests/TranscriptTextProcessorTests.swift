import XCTest
@testable import VidLingoCore

final class TranscriptTextProcessorTests: XCTestCase {
    func testSentenceBoundariesRemainReadable() {
        let result = TranscriptTextProcessor.organizeTranscript(
            "First sentence. Second sentence! Third sentence?",
            languageID: "en-US"
        )

        XCTAssertEqual(result, "First sentence.\nSecond sentence!\nThird sentence?")
    }

    func testParagraphBreaksArePreserved() {
        let result = TranscriptTextProcessor.organizeTranscript(
            "第一段。\n\n第二段。",
            languageID: "zh-CN"
        )

        XCTAssertEqual(result, "第一段。\n\n第二段。")
    }
}
