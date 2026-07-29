import Dispatch
import XCTest
@testable import VidLingo

final class ProcessSupervisorTests: XCTestCase {
    func testAsyncOperationTimeoutIsReported() async {
        do {
            _ = try await AsyncOperationTimeout.run(timeout: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return "finished"
            }
            XCTFail("Expected the async operation to time out")
        } catch {
            XCTAssertEqual(error as? ProcessSupervisorError, .processTimedOut)
        }
    }

    func testCancellationTerminatesChildProcess() throws {
        let token = ProcessCancellationToken(timeout: 10)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            token.cancel()
        }

        XCTAssertThrowsError(try ProcessSupervisor.run(process, token: token, timeout: 5)) { error in
            XCTAssertEqual(error as? ProcessSupervisorError, .cancelled)
        }
    }
}
