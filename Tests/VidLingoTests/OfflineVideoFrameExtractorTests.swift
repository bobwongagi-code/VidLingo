import XCTest
@testable import VidLingo

final class OfflineVideoFrameExtractorTests: XCTestCase {
    func testLocalFrameTimeoutIsRecoverableButCancellationAndDeadlinePropagate() {
        XCTAssertNoThrow(try OfflineVideoFrameExtractor.rethrowFatalFrameReadError(
            ProcessSupervisorError.processTimedOut
        ))
        XCTAssertThrowsError(try OfflineVideoFrameExtractor.rethrowFatalFrameReadError(
            ProcessSupervisorError.cancelled
        )) { error in
            XCTAssertEqual(error as? ProcessSupervisorError, .cancelled)
        }
        XCTAssertThrowsError(try OfflineVideoFrameExtractor.rethrowFatalFrameReadError(
            ProcessSupervisorError.deadlineExceeded
        )) { error in
            XCTAssertEqual(error as? ProcessSupervisorError, .deadlineExceeded)
        }
        XCTAssertThrowsError(try OfflineVideoFrameExtractor.rethrowFatalFrameReadError(
            CancellationError()
        )) { error in
            XCTAssertEqual(error as? ProcessSupervisorError, .cancelled)
        }
    }
}
