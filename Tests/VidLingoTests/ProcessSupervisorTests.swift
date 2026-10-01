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

    func testTimeoutReturnsBeforeNonCooperativeOperation() async {
        let gate = AsyncOperationGate()
        let state = AsyncOperationTestState()
        let task = Task {
            try await AsyncOperationTimeout.run(
                timeout: 1,
                onCancel: { state.markCancelled() },
                onLateCompletion: { state.markLateCompletion($0) }
            ) {
                await gate.suspend()
                return "late result"
            }
        }
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            await gate.release()
        }
        defer { watchdog.cancel() }
        let cleanupWatchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            state.markLateCompletion("late completion watchdog expired")
        }
        defer { cleanupWatchdog.cancel() }
        await gate.waitUntilStarted()
        do {
            _ = try await task.value
            XCTFail("Expected the async operation to time out")
        } catch {
            XCTAssertEqual(error as? ProcessSupervisorError, .processTimedOut)
        }

        let operationStarted = await gate.isStarted
        XCTAssertTrue(operationStarted)
        XCTAssertTrue(state.wasCancelled)
        let operationFinishedBeforeRelease = await gate.isFinished
        XCTAssertFalse(operationFinishedBeforeRelease)

        await gate.release()
        await gate.waitUntilFinished()
        let lateValue = await state.waitForLateCompletion()
        XCTAssertEqual(lateValue, "late result")
    }

    func testSuccessfulOperationDoesNotCallCancellationHook() async throws {
        let state = AsyncOperationTestState()
        let result = try await AsyncOperationTimeout.run(
            timeout: 60,
            onCancel: { state.markCancelled() }
        ) {
            "completed"
        }

        XCTAssertEqual(result, "completed")
        XCTAssertFalse(state.wasCancelled)
    }

    func testTaskCancellationReturnsBeforeNonCooperativeOperation() async {
        let gate = AsyncOperationGate()
        let state = AsyncOperationTestState()
        let task = Task {
            try await AsyncOperationTimeout.run(
                timeout: 60,
                onCancel: { state.markCancelled() },
                onLateCompletion: { state.markLateCompletion($0) }
            ) {
                await gate.suspend()
                return "finished"
            }
        }
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            await gate.release()
        }
        defer { watchdog.cancel() }
        let cleanupWatchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            state.markLateCompletion("late completion watchdog expired")
        }
        defer { cleanupWatchdog.cancel() }

        await gate.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation to interrupt the wait")
        } catch {
            XCTAssertEqual(error as? ProcessSupervisorError, .cancelled)
        }

        XCTAssertTrue(state.wasCancelled)
        let operationFinishedBeforeRelease = await gate.isFinished
        XCTAssertFalse(operationFinishedBeforeRelease)
        await gate.release()
        await gate.waitUntilFinished()
        let lateValue = await state.waitForLateCompletion()
        cleanupWatchdog.cancel()
        XCTAssertEqual(lateValue, "finished")
    }

    func testCancellationTokenReturnsBeforeNonCooperativeOperation() async {
        let gate = AsyncOperationGate()
        let state = AsyncOperationTestState()
        let token = ProcessCancellationToken(timeout: 60)
        let task = Task {
            try await AsyncOperationTimeout.run(
                timeout: 60,
                token: token,
                onCancel: { state.markCancelled() }
            ) {
                await gate.suspend()
                return "finished"
            }
        }
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            await gate.release()
        }
        defer { watchdog.cancel() }

        await gate.waitUntilStarted()
        token.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected token cancellation to interrupt the wait")
        } catch {
            XCTAssertEqual(error as? ProcessSupervisorError, .cancelled)
        }

        XCTAssertTrue(state.wasCancelled)
        let operationFinishedBeforeRelease = await gate.isFinished
        XCTAssertFalse(operationFinishedBeforeRelease)
        await gate.release()
        await gate.waitUntilFinished()
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

private actor AsyncOperationGate {
    private var isOperationStarted = false
    private var isOperationFinished = false
    private var wasReleased = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var finishWaiters = [CheckedContinuation<Void, Never>]()

    var isFinished: Bool { isOperationFinished }
    var isStarted: Bool { isOperationStarted }

    func suspend() async {
        await withCheckedContinuation { continuation in
            isOperationStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            if wasReleased {
                isOperationFinished = true
                let finishWaiters = finishWaiters
                self.finishWaiters.removeAll()
                continuation.resume()
                waiters.forEach { $0.resume() }
                finishWaiters.forEach { $0.resume() }
                return
            }
            operationContinuation = continuation
            waiters.forEach { $0.resume() }
        }
        isOperationFinished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !isOperationStarted, !wasReleased else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilFinished() async {
        guard !isOperationFinished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    func release() {
        wasReleased = true
        guard let operationContinuation else {
            guard !isOperationStarted else { return }
            isOperationFinished = true
            let waiters = startWaiters
            startWaiters.removeAll()
            let finishWaiters = finishWaiters
            self.finishWaiters.removeAll()
            waiters.forEach { $0.resume() }
            finishWaiters.forEach { $0.resume() }
            return
        }
        operationContinuation.resume()
        self.operationContinuation = nil
    }
}

private final class AsyncOperationTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lateCompletion: String?
    private var lateCompletionWaiters = [CheckedContinuation<String?, Never>]()

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func waitForLateCompletion() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let lateCompletion {
                lock.unlock()
                continuation.resume(returning: lateCompletion)
            } else {
                lateCompletionWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func markLateCompletion(_ value: String) {
        lock.lock()
        guard lateCompletion == nil else {
            lock.unlock()
            return
        }
        lateCompletion = value
        let waiters = lateCompletionWaiters
        lateCompletionWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: value) }
    }
}
