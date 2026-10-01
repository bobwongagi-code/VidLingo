import Foundation
import Darwin
import Dispatch

final class ProcessCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandlers = [UUID: @Sendable () -> Void]()
    private let deadline: Date

    init(timeout: TimeInterval) {
        deadline = Date().addingTimeInterval(timeout)
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    @discardableResult
    func addCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            handler()
            return nil
        }
        let id = UUID()
        cancellationHandlers[id] = handler
        lock.unlock()
        return id
    }

    func removeCancellationHandler(_ id: UUID) {
        lock.lock()
        cancellationHandlers.removeValue(forKey: id)
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled || Task.isCancelled {
            throw ProcessSupervisorError.cancelled
        }
        if Date() >= deadline {
            throw ProcessSupervisorError.deadlineExceeded
        }
    }
}

enum ProcessSupervisorError: LocalizedError, Equatable {
    case cancelled
    case deadlineExceeded
    case processTimedOut

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "任务已取消。"
        case .deadlineExceeded, .processTimedOut:
            "本地媒体处理超时。请缩短视频或检查 ffmpeg 配置。"
        }
    }
}

enum AsyncOperationTimeout {
    static func run<T: Sendable>(
        timeout: TimeInterval,
        token: ProcessCancellationToken? = nil,
        onCancel: @escaping @Sendable () -> Void = {},
        onLateCompletion: @escaping @Sendable (T) -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = AsyncOperationRace(onCancel: onCancel, onLateCompletion: onLateCompletion)
        let cancellationHandlerID = token?.addCancellationHandler {
            race.fail(ProcessSupervisorError.cancelled)
        }
        defer {
            if let cancellationHandlerID {
                token?.removeCancellationHandler(cancellationHandlerID)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.installContinuation(continuation)
                guard race.isPending else { return }

                let operationTask = Task.detached(priority: .utility) {
                    guard !Task.isCancelled else {
                        race.finishOperation(.failure(CancellationError()))
                        return
                    }
                    do {
                        race.finishOperation(.success(try await operation()))
                    } catch {
                        race.finishOperation(.failure(error))
                    }
                }
                race.installOperationTask(operationTask)
                guard race.isPending else { return }

                let timeoutTask = Task.detached(priority: .utility) {
                    do {
                        try await Task.sleep(for: .seconds(max(timeout, 0.001)))
                        race.fail(ProcessSupervisorError.processTimedOut)
                    } catch {
                        // 另一个结果先完成时，取消计时任务即可。
                    }
                }
                race.installTimeoutTask(timeoutTask)
            }
        } onCancel: {
            race.fail(ProcessSupervisorError.cancelled)
        }
    }
}

private final class AsyncOperationRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let onCancel: @Sendable () -> Void
    private let onLateCompletion: @Sendable (T) -> Void
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        onCancel: @escaping @Sendable () -> Void,
        onLateCompletion: @escaping @Sendable (T) -> Void
    ) {
        self.onCancel = onCancel
        self.onLateCompletion = onLateCompletion
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    func installContinuation(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        let completedResult = result
        if completedResult == nil {
            self.continuation = continuation
        }
        lock.unlock()
        if let completedResult {
            continuation.resume(with: completedResult)
        }
    }

    func installOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel {
            operationTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func finishOperation(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            if case let .success(value) = result {
                onLateCompletion(value)
            }
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        operationTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        let failure = Result<T, Error>.failure(error)
        result = failure
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        self.operationTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        onCancel()
        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: failure)
    }
}

final class BoundedProcessLog: @unchecked Sendable {
    let pipe = Pipe()

    private static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private let readerFinished = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var hasStarted = false
    private var hasFinished = false

    func start() {
        lock.lock()
        guard !hasStarted else {
            lock.unlock()
            return
        }
        hasStarted = true
        lock.unlock()

        let readHandle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { self.readerFinished.signal() }
            while true {
                guard let chunk = try? readHandle.read(upToCount: 8 * 1024),
                      !chunk.isEmpty else {
                    return
                }
                self.lock.lock()
                self.buffer.append(chunk)
                if self.buffer.count > Self.maximumBytes {
                    self.buffer = Data(self.buffer.suffix(Self.maximumBytes))
                }
                self.lock.unlock()
            }
        }
    }

    func finish(to url: URL) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        lock.unlock()

        try? pipe.fileHandleForWriting.close()
        _ = readerFinished.wait(timeout: .now() + 3)
        try? pipe.fileHandleForReading.close()

        lock.lock()
        let output = buffer
        lock.unlock()
        try? output.write(to: url, options: .atomic)
    }
}

enum MediaProcessingLimits {
    static let maxVideoBytes: Int64 = 1_024 * 1_024 * 1_024
    static let maxVideoDurationSeconds: Double = 15 * 60
    static let totalTaskTimeout: TimeInterval = 20 * 60
    static let childProcessTimeout: TimeInterval = 10 * 60
}

enum ProcessSupervisor {
    static func run(
        _ process: Process,
        token: ProcessCancellationToken,
        timeout: TimeInterval = MediaProcessingLimits.childProcessTimeout
    ) throws -> Int32 {
        try token.check()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning {
            do {
                try token.check()
            } catch {
                terminate(process)
                throw error
            }
            if Date() >= deadline {
                terminate(process)
                throw ProcessSupervisorError.processTimedOut
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return process.terminationStatus
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
