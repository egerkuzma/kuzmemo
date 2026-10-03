import Darwin
import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var wallSeconds: Double
    var timedOut: Bool
    /// True when the child was ended by a signal (crash or our own kill) rather than exiting normally.
    var killedBySignal: Bool
    var outputTruncated = false
}

/// Runs a child process with a hard timeout. Writes stdin from a background queue and reads stdout and
/// stderr on dedicated threads, so a large prompt or large output cannot deadlock the pipes.
enum ProcessRunner {
    static func run(
        executable: URL, arguments: [String], stdin: Data?, environment: [String: String],
        workingDirectory: URL?, timeout: TimeInterval
    ) async throws -> ProcessResult {
        let job = Job(
            executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory
        )
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await job.start(stdin: stdin, timeout: timeout)
        } onCancel: {
            job.terminate()
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        private var truncated = false
        init(limit: Int) { self.limit = limit }
        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let available = max(0, limit - data.count)
            data.append(chunk.prefix(available))
            if chunk.count > available { truncated = true }
            return !truncated
        }
        var wasTruncated: Bool { lock.lock(); defer { lock.unlock() }; return truncated }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let inPipe = Pipe()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let out = Buffer(limit: 8 << 20)
        private let err = Buffer(limit: 1 << 20)
        private let lock = NSLock()
        private var timedOut = false
        private var resumed = false
        private var stopRequested = false
        private var terminationSent = false
        private var started = Date()

        init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?) {
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workingDirectory
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func terminate() {
            lock.lock(); stopRequested = true; lock.unlock()
            guard process.isRunning else { return }
            lock.lock()
            guard !terminationSent else { lock.unlock(); return }
            terminationSent = true
            lock.unlock()
            let pid = process.processIdentifier
            // Foundation starts a private process group. Stop its children as well: a CLI's shell/helper can otherwise keep
            // the pipes open after the parent ends. Never signal a group inherited from the caller.
            if getpgid(pid) == pid { _ = kill(-pid, SIGTERM) } else { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                guard process.isRunning, process.processIdentifier == pid else { return }
                if getpgid(pid) == pid { _ = kill(-pid, SIGKILL) } else { _ = kill(pid, SIGKILL) }
            }
        }

        func start(stdin: Data?, timeout: TimeInterval) async throws -> ProcessResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                let readers = DispatchGroup()
                // Both readers are counted before the child can start, so the termination handler of a child that exits at
                // once still waits for them (it used to see an empty group and answer with an empty output).
                readers.enter()
                readers.enter()
                process.terminationHandler = { [self] finished in
                    // The process holds this handler and the job holds the process: let go of it, or neither is ever freed.
                    process.terminationHandler = nil
                    // Give the readers a moment to reach EOF; a stray grandchild holding a pipe must not hang us.
                    DispatchQueue.global().async { [self] in
                        _ = readers.wait(timeout: .now() + 0.5)
                        lock.lock()
                        let flagged = timedOut
                        let already = resumed
                        resumed = true
                        lock.unlock()
                        guard !already else { return }
                        continuation.resume(returning: ProcessResult(
                            exitCode: finished.terminationStatus,
                            stdout: out.snapshot(), stderr: err.snapshot(),
                            wallSeconds: Date().timeIntervalSince(started),
                            timedOut: flagged,
                            killedBySignal: finished.terminationReason == .uncaughtSignal,
                            outputTruncated: out.wasTruncated || err.wasTruncated
                        ))
                    }
                }
                started = Date()
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    readers.leave()
                    readers.leave()
                    for handle in [inPipe.fileHandleForReading, inPipe.fileHandleForWriting, outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
                        try? handle.close()
                    }
                    lock.lock(); resumed = true; lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                lock.lock(); let shouldStop = stopRequested; lock.unlock()
                if shouldStop { terminate() } // cancellation can arrive before run() gave the child a PID

                for (handle, buffer) in [(outPipe.fileHandleForReading, out), (errPipe.fileHandleForReading, err)] {
                    DispatchQueue.global().async { [self] in
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            if !buffer.append(chunk) { terminate() }
                        }
                        try? handle.close() // the only thread that uses this end gives it back
                        readers.leave()
                    }
                }
                DispatchQueue.global().async { [inPipe] in
                    if let stdin, !stdin.isEmpty { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
                    try? inPipe.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    guard process.isRunning else { return }
                    lock.lock(); timedOut = true; lock.unlock()
                    terminate()
                }
            }
        }
    }
}
