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
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private final class Job: @unchecked Sendable {
        private let process = Process()
        private let inPipe = Pipe()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let out = Buffer()
        private let err = Buffer()
        private let lock = NSLock()
        private var timedOut = false
        private var stopRequested = false
        private var terminationSent = false
        private var resumed = false
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
            // Foundation normally gives the child its own group. Stop its descendants too: a child shell can wait
            // for them and they can keep our pipes open. Never signal the caller's inherited process group.
            let privateGroup = getpgid(pid) == pid
            if privateGroup { kill(-pid, SIGTERM) } else { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                // A delayed kill must still refer to this running child, not a PID reused after it exited.
                guard process.isRunning, process.processIdentifier == pid else { return }
                if privateGroup, getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
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
                    // Give the readers time to reach EOF: on a loaded Mac half a second was not enough for them to be scheduled,
                    // and a child that had answered in full was read as having said nothing. A stray grandchild holding a pipe
                    // must still not hang us (the group kill at the timeout makes that rare), so the wait stays bounded.
                    DispatchQueue.global().async { [self] in
                        _ = readers.wait(timeout: .now() + 3)
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
                            killedBySignal: finished.terminationReason == .uncaughtSignal
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
                lock.lock(); let cancelledBeforeLaunch = stopRequested; lock.unlock()
                if cancelledBeforeLaunch { terminate() }

                for (handle, buffer) in [(outPipe.fileHandleForReading, out), (errPipe.fileHandleForReading, err)] {
                    DispatchQueue.global().async {
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            buffer.append(chunk)
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
