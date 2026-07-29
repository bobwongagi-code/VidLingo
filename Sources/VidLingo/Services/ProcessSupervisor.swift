import Foundation
import Darwin
import Dispatch

final class ProcessCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: Date

    init(timeout: TimeInterval) {
        deadline = Date().addingTimeInterval(timeout)
    }

    func cancel() {
        lock.lock()
        cancelled = true
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
            "本地处理超时。请缩短视频或检查 ffmpeg / Whisper 配置。"
        }
    }
}

enum AsyncOperationTimeout {
    static func run<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.001) * 1_000_000_000))
                throw ProcessSupervisorError.processTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ProcessSupervisorError.processTimedOut
            }
            return result
        }
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
    static let maxAudioBytes: Int64 = 256 * 1_024 * 1_024
    static let totalTaskTimeout: TimeInterval = 20 * 60
    static let childProcessTimeout: TimeInterval = 10 * 60
    static let maxThaiWhisperSegments = 48
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
