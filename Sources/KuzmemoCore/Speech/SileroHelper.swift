import Darwin
import Foundation

public enum SileroError: Error, Equatable, Sendable, LocalizedError {
    case startFailed(String)
    case exited(String)
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .startFailed(text): "Silero не запустился: \(text)"
        case let .exited(text): "Silero остановился: \(text)"
        case .timedOut: "Silero не ответил вовремя."
        case let .failed(text): "Silero не смог озвучить фразу: \(text)"
        }
    }
}

/// A phrase spoken into a WAV file.
public struct SileroSynthesis: Equatable, Sendable {
    public var url: URL
    public var seconds: Double
    public var milliseconds: Int
}

/// Runs `silero_helper.py` and turns text into WAV files with it. The Python process is started on first use and kept
/// while it is used, so that torch and the model are loaded once; after `idleSeconds` without a request it is stopped
/// to give the memory back. A crashed or hung helper is replaced by a fresh one on the next request.
public actor SileroHelper {
    public struct Launch: Equatable, Sendable {
        public var python: URL
        public var script: URL
        public var model: URL

        public init(python: URL, script: URL, model: URL) {
            self.python = python
            self.script = script
            self.model = model
        }
    }

    private enum State { case stopped, starting, ready }

    private let launch: Launch
    private let outputDirectory: URL
    private let idleSeconds: TimeInterval
    private let startTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    private var state = State.stopped
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var run = 0
    private var nextID = 0
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var pending: [String: CheckedContinuation<SileroSynthesis, any Error>] = [:]
    private var idleTask: Task<Void, Never>?
    private var startTimer: Task<Void, Never>?
    private var stderrTail: [String] = []
    /// A process's end is only acted on once everything it wrote has been read, so that its last words (an error
    /// event, say) are not overtaken by the news that it exited.
    private var exitStatus: Int32?
    private var outputDrained = false

    /// The voices the loaded model offers (empty until the helper has started).
    public private(set) var speakers: [String] = []
    public private(set) var loadMilliseconds = 0

    public init(
        launch: Launch, outputDirectory: URL, idleSeconds: TimeInterval = 600, startTimeout: TimeInterval = 90,
        requestTimeout: TimeInterval = 30
    ) {
        self.launch = launch
        self.outputDirectory = outputDirectory
        self.idleSeconds = idleSeconds
        self.startTimeout = startTimeout
        self.requestTimeout = requestTimeout
    }

    public var isReady: Bool { state == .ready }
    public var isRunning: Bool { state != .stopped }

    /// What the helper wrote to its error stream lately, for a diagnostic message.
    public var diagnostics: String { stderrTail.suffix(8).joined(separator: "\n") }

    // MARK: - Use

    /// Starts the helper if it is not running and waits until the model is loaded.
    public func prepare() async throws {
        idleTask?.cancel()
        try await ensureReady()
        scheduleIdleStop()
    }

    public func synthesize(text: String, speaker: String, rate: SileroVoice.Rate = .medium, sampleRate: Int = 48_000) async throws -> SileroSynthesis {
        idleTask?.cancel()
        try await ensureReady()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        nextID += 1
        let id = String(nextID)
        let output = outputDirectory.appendingPathComponent("silero-\(UUID().uuidString).wav")
        let request: [String: Any] = [
            "id": id, "op": "say", "text": text, "speaker": speaker, "rate": rate.rawValue, "sample_rate": sampleRate, "out": output.path,
        ]
        defer { scheduleIdleStop() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SileroSynthesis, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                do {
                    try send(request)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: SileroError.exited("не удалось передать фразу: \(error.localizedDescription)"))
                    return
                }
                let limit = requestTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    await self?.expire(id)
                }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Ends the helper (it is started again by the next request).
    public func stop() async {
        idleTask?.cancel()
        startTimer?.cancel()
        guard let process else { return }
        run += 1 // events of the old process are ignored from here on
        try? send(["op": "quit"])
        try? stdinPipe?.fileHandleForWriting.close()
        for _ in 0 ..< 15 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning {
            process.terminate()
            for _ in 0 ..< 10 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        cleanUp(failWith: SileroError.exited("остановлен"))
    }

    // MARK: - Starting

    private func ensureReady() async throws {
        switch state {
        case .ready: return
        case .stopped: try startProcess()
        case .starting: break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiters.append(continuation)
        }
    }

    private func startProcess() throws {
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        let child = Process()
        child.executableURL = launch.python
        child.arguments = [launch.script.path, launch.model.path]
        var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR"].contains($0.key) }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1" // a borrowed environment stays as it was
        environment["TOKENIZERS_PARALLELISM"] = "false"
        child.environment = environment
        child.standardInput = inPipe
        child.standardOutput = outPipe
        child.standardError = errPipe
        run += 1
        let mine = run
        child.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.processExited(run: mine, status: status) }
        }
        do {
            try child.run()
        } catch {
            throw SileroError.startFailed(error.localizedDescription)
        }
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        stdinPipe = inPipe
        stdoutPipe = outPipe
        stderrPipe = errPipe
        state = .starting
        stderrTail = []
        exitStatus = nil
        outputDrained = false

        let stdout = Self.lines(from: outPipe.fileHandleForReading)
        Task { [weak self] in
            for await line in stdout { await self?.receive(line, run: mine) }
            await self?.outputEnded(run: mine)
        }
        let stderr = Self.lines(from: errPipe.fileHandleForReading)
        Task { [weak self] in
            for await line in stderr { await self?.remember(line, run: mine) }
        }
        let limit = startTimeout
        startTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            await self?.startTimedOut(run: mine)
        }
    }

    private func startTimedOut(run started: Int) {
        guard started == run, state == .starting else { return }
        fail(SileroError.startFailed("не загрузился за \(Int(startTimeout)) с"))
    }

    // MARK: - Events from the process

    private func remember(_ line: String, run started: Int) {
        guard started == run else { return }
        stderrTail.append(line)
        if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
    }

    private func receive(_ line: String, run started: Int) {
        guard started == run, let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let event = message["event"] as? String {
            switch event {
            case "ready":
                speakers = (message["speakers"] as? [String]) ?? []
                loadMilliseconds = (message["load_ms"] as? Int) ?? 0
                state = .ready
                startTimer?.cancel()
                let waiting = waiters
                waiters = []
                for waiter in waiting { waiter.resume() }
            case "error":
                fail(SileroError.startFailed((message["error"] as? String) ?? "неизвестная ошибка"))
            default: break
            }
            return
        }
        guard let id = message["id"] as? String else { return }
        let continuation = pending.removeValue(forKey: id)
        if (message["ok"] as? Bool) == true, let path = message["path"] as? String {
            let seconds = (message["seconds"] as? Double) ?? Double((message["seconds"] as? Int) ?? 0)
            let result = SileroSynthesis(url: URL(fileURLWithPath: path), seconds: seconds, milliseconds: (message["ms"] as? Int) ?? 0)
            if let continuation { continuation.resume(returning: result) } else { try? FileManager.default.removeItem(at: result.url) }
        } else {
            continuation?.resume(throwing: SileroError.failed((message["error"] as? String) ?? "неизвестная ошибка"))
        }
    }

    private func processExited(run started: Int, status: Int32) {
        guard started == run, process != nil else { return }
        exitStatus = status
        if outputDrained {
            finishExit(run: started)
        } else {
            // the reader is still handing over what the process wrote last; do not wait for it forever
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.finishExit(run: started)
            }
        }
    }

    private func outputEnded(run started: Int) {
        guard started == run else { return }
        outputDrained = true
        if exitStatus != nil { finishExit(run: started) }
    }

    private func finishExit(run started: Int) {
        guard started == run, process != nil, let status = exitStatus else { return }
        let detail = diagnostics.isEmpty ? "код \(status)" : "код \(status): \(diagnostics.split(separator: "\n").last.map(String.init) ?? "")"
        cleanUp(failWith: state == .starting ? SileroError.startFailed(detail) : SileroError.exited(detail))
    }

    /// A request that took too long: the helper is assumed hung, so it is replaced.
    private func expire(_ id: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: SileroError.timedOut)
        fail(SileroError.timedOut)
    }

    /// The caller gave up on a phrase; the helper finishes it and the late file is deleted when it arrives.
    private func abandon(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: - Ending

    /// Kills the process and fails everything waiting for it.
    private func fail(_ error: SileroError) {
        let old = process
        run += 1
        old?.terminate()
        if let old { let pid = old.processIdentifier; Task.detached { try? await Task.sleep(for: .seconds(2)); if old.isRunning { kill(pid, SIGKILL) } } }
        cleanUp(failWith: error)
    }

    private func cleanUp(failWith error: SileroError) {
        state = .stopped
        process = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        startTimer?.cancel()
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(throwing: error) }
        let requests = pending
        pending = [:]
        for (_, request) in requests { request.resume(throwing: error) }
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard idleSeconds > 0 else { return }
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    // MARK: - Pipes

    private func send(_ object: [String: Any]) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else { throw SileroError.exited("не запущен") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    /// The lines a child writes, in order, on a thread of their own; the stream ends when the child closes the pipe.
    private static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                // the handle stays alive (and open) for as long as this thread reads from it
                withExtendedLifetime(handle) {
                    let descriptor = handle.fileDescriptor
                    var pending = Data()
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count < 0, errno == EINTR { continue }
                        if count <= 0 { break }
                        pending.append(buffer, count: count)
                        while let newline = pending.firstIndex(of: 0x0A) {
                            continuation.yield(String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self))
                            pending.removeSubrange(pending.startIndex ... newline)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    continuation.finish()
                }
            }
            thread.start()
        }
    }
}
