import XCTest
@testable import VidLingo

final class CaptionLineTests: XCTestCase {
    func testPartialTranscriptKeepsLocalSourceText() {
        let line = CaptionLine.partialTranscript(sourceText: "Fun-ASR 已完成转写")

        XCTAssertEqual(line.sourceText, "Fun-ASR 已完成转写")
        XCTAssertEqual(line.translatedSourceText, "Fun-ASR 已完成转写")
        XCTAssertTrue(line.translatedText.isEmpty)
        XCTAssertFalse(line.isFinal)
    }
}
