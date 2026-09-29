import Foundation

/// Where the experimental "My voice" engine lives and whether it can speak. Everything is under one folder,
/// `~/Library/Application Support/Kuzmemo/omnivoice`, which `scripts/install_omnivoice.sh` fills.
public struct OmniVoiceLocator: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The program or the weights are missing.
        case notInstalled
        /// Installed, but no voice has been recorded yet.
        case noVoice
        case ready
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: OmniVoiceLocator {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return OmniVoiceLocator(directory: support.appendingPathComponent("Kuzmemo/omnivoice", isDirectory: true))
    }

    /// Makes speech from text.
    public var synthesizer: URL { directory.appendingPathComponent("build/omnivoice-tts") }
    /// Turns a recording of a voice into the compact codes the synthesizer wants.
    public var encoder: URL { directory.appendingPathComponent("build/omnivoice-codec") }
    public var languageModel: URL { directory.appendingPathComponent("models/omnivoice-base-Q8_0.gguf") }
    public var codecModel: URL { directory.appendingPathComponent("models/omnivoice-tokenizer-Q8_0.gguf") }
    /// The person's voice: the recording, its codes and the exact words said in it.
    public var voiceDirectory: URL { directory.appendingPathComponent("voice", isDirectory: true) }
    public var referenceRecording: URL { voiceDirectory.appendingPathComponent("ref.wav") }
    public var referenceCodes: URL { voiceDirectory.appendingPathComponent("ref.rvq") }
    public var referenceText: URL { voiceDirectory.appendingPathComponent("ref.txt") }

    public var status: Status {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: synthesizer.path), files.fileExists(atPath: languageModel.path),
              files.fileExists(atPath: codecModel.path)
        else { return .notInstalled }
        return files.fileExists(atPath: referenceCodes.path) && files.fileExists(atPath: referenceText.path) ? .ready : .noVoice
    }
}

public enum OmniVoiceError: Error, Equatable, Sendable {
    case notReady(OmniVoiceLocator.Status)
    case launchFailed(String)
    /// The program ended with an error.
    case failed(status: Int32)
    case timedOut
    /// The program ended well but made no sound.
    case producedNoAudio
}

/// Speaks with the person's own voice by running `omnivoice-tts` once per answer: the sentences go in one per line, and
/// the sound of each comes out as soon as it is made (`--stream-by-line`), so the first sentence can be played while the
/// next is still being made. The process lives only as long as the answer, so nothing stays in memory between answers.
public struct OmniVoiceRunner: Sendable {
    public var locator: OmniVoiceLocator
    /// Decoding steps of the model: more is clearer and slower. 16 is intelligible; 8 makes slips.
    public var steps: Int
    /// The longest an answer may take before the program is stopped.
    public var timeout: TimeInterval
    public var language: String

    public init(locator: OmniVoiceLocator = .standard, steps: Int = 16, timeout: TimeInterval = 90, language: String = "Russian") {
        self.locator = locator
        self.steps = steps
        self.timeout = timeout
        self.language = language
    }

    func arguments() -> [String] {
        [
            "--model", locator.languageModel.path, "--codec", locator.codecModel.path,
            "--ref-rvq", locator.referenceCodes.path, "--ref-text", locator.referenceText.path,
            "--lang", language, "--steps", String(steps), "-o", "-", "--stream-by-line",
        ]
    }

    /// One segment per non-empty sentence, in order, each yielded when it is complete. The stream ends with an error when
    /// the engine is not ready, cannot start, fails, makes no sound or takes longer than `timeout`. Ending the iteration
    /// early stops the program.
    public func speak(_ sentences: [String]) -> AsyncThrowingStream<SpokenSegment, any Error> {
        let lines = sentences.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let arguments = arguments()
        let locator = self.locator
        let timeout = self.timeout
        return AsyncThrowingStream { continuation in
            guard locator.status == .ready else { continuation.finish(throwing: OmniVoiceError.notReady(locator.status)); return }
            guard !lines.isEmpty else { continuation.finish(); return }
            let process = Process()
            process.executableURL = locator.synthesizer
            process.arguments = arguments
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let running = RunningProcess(process)
            continuation.onTermination = { _ in running.stop(timedOut: false) }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: OmniVoiceError.launchFailed("\(error)"))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = Data((lines.joined(separator: "\n") + "\n").utf8)
                try? input.fileHandleForWriting.write(contentsOf: text)
                try? input.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { running.stop(timedOut: true) }
            DispatchQueue.global(qos: .userInitiated).async {
                var splitter = WAVStreamSplitter()
                var made = 0
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    for segment in splitter.feed(chunk) {
                        made += 1
                        continuation.yield(segment)
                    }
                }
                for segment in splitter.finish() {
                    made += 1
                    continuation.yield(segment)
                }
                process.waitUntilExit()
                if running.didTimeOut {
                    continuation.finish(throwing: OmniVoiceError.timedOut)
                } else if process.terminationStatus != 0 {
                    continuation.finish(throwing: OmniVoiceError.failed(status: process.terminationStatus))
                } else if made == 0 {
                    continuation.finish(throwing: OmniVoiceError.producedNoAudio)
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

/// The process, reachable from the callbacks that stop it.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false

    init(_ process: Process) { self.process = process }

    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    func stop(timedOut byTimeout: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return }
        if byTimeout { timedOut = true }
        process.terminate()
    }
}
