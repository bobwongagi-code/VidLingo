import XCTest
@testable import VidLingo

final class CaptionLineTests: XCTestCase {
    func testTranscriptResultDisplayStateKeepsProcessingBeforeFinalResult() {
        XCTAssertEqual(
            TranscriptResultDisplayState.resolve(isProcessing: true, hasResult: true, hasVideo: true),
            .processing
        )
        XCTAssertEqual(
            TranscriptResultDisplayState.resolve(isProcessing: false, hasResult: true, hasVideo: true),
            .completed
        )
        XCTAssertEqual(
            TranscriptResultDisplayState.resolve(isProcessing: false, hasResult: false, hasVideo: true),
            .waiting
        )
        XCTAssertEqual(
            TranscriptResultDisplayState.resolve(isProcessing: false, hasResult: false, hasVideo: false),
            .noVideo
        )
    }
}
