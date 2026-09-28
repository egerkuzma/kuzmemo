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
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }

        func start(stdin: Data?, timeout: TimeInterval) async throws -> ProcessResult {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                let readers = DispatchGroup()
                process.terminationHandler = { [self] finished in
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
                            killedBySignal: finished.terminationReason == .uncaughtSignal
                        ))
                    }
                }
                started = Date()
                do {
                    try process.run()
                } catch {
                    lock.lock(); resumed = true; lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

                for (handle, buffer) in [(outPipe.fileHandleForReading, out), (errPipe.fileHandleForReading, err)] {
                    readers.enter()
                    DispatchQueue.global().async {
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            buffer.append(chunk)
                        }
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
