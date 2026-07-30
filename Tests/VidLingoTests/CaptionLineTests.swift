import XCTest
@testable import VidLingo

final class CaptionLineTests: XCTestCase {
    func testPartialTranscriptKeepsLocalSourceText() {
        let line = CaptionLine.partialTranscript(sourceText: "本地 Whisper 已完成转写")

        XCTAssertEqual(line.sourceText, "本地 Whisper 已完成转写")
        XCTAssertEqual(line.translatedSourceText, "本地 Whisper 已完成转写")
        XCTAssertTrue(line.translatedText.isEmpty)
        XCTAssertFalse(line.isFinal)
    }
}
