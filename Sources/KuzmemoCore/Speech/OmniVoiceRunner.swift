import Foundation

/// Where the experimental "My voice" engine lives and whether it can speak. The program and its weights are one folder,
/// `~/Library/Application Support/Kuzmemo/omnivoice`, which `scripts/install_omnivoice.sh` fills and both app bundles
/// share; the person's voice (their recording, its codes and the words said in it) is a folder of the bundle's own, so
/// the automation build can never touch the recording of the daily app.
public struct OmniVoiceLocator: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The program or the weights are missing.
        case notInstalled
        /// Installed, but no voice has been recorded yet.
        case noVoice
        case ready
    }

    public let directory: URL
    public let voiceDirectory: URL

    /// `voiceDirectory` defaults to a `voice` folder inside the engine's folder (tests, the live check).
    public init(directory: URL, voiceDirectory: URL? = nil) {
        self.directory = directory
        self.voiceDirectory = voiceDirectory ?? directory.appendingPathComponent("voice", isDirectory: true)
    }

    public static var engineDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Kuzmemo/omnivoice", isDirectory: true)
    }

    public static var standard: OmniVoiceLocator { OmniVoiceLocator(directory: engineDirectory) }

    /// The installed engine with a voice kept elsewhere (an app bundle's own folder).
    public static func standard(voice: URL) -> OmniVoiceLocator { OmniVoiceLocator(directory: engineDirectory, voiceDirectory: voice) }

    /// Makes speech from text.
    public var synthesizer: URL { directory.appendingPathComponent("build/omnivoice-tts") }
    /// Turns a recording of a voice into the compact codes the synthesizer wants.
    public var encoder: URL { directory.appendingPathComponent("build/omnivoice-codec") }
    public var languageModel: URL { directory.appendingPathComponent("models/omnivoice-base-Q8_0.gguf") }
    public var codecModel: URL { directory.appendingPathComponent("models/omnivoice-tokenizer-Q8_0.gguf") }
    /// The person's voice: the recording, its codes and the exact words said in it.
    public var referenceRecording: URL { voiceDirectory.appendingPathComponent("ref.wav") }
    public var referenceCodes: URL { voiceDirectory.appendingPathComponent("ref.rvq") }
    public var referenceText: URL { voiceDirectory.appendingPathComponent("ref.txt") }

    /// Whether the program and its weights are in place.
    public var isInstalled: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: synthesizer.path) && files.fileExists(atPath: languageModel.path)
            && files.fileExists(atPath: codecModel.path)
    }

    public var status: Status {
        guard isInstalled else { return .notInstalled }
        let files = FileManager.default
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
    /// A program started ahead of time was not used soon enough, or was used already.
    case expired
    /// The recording is too short or too long to be a voice sample (its length in seconds).
    case sampleLength(seconds: Double)
    /// The words said in the recording are missing (a sample needs at least two).
    case sampleWithoutWords
    /// The file is not a mono 16-bit WAV recording.
    case sampleUnreadable
    /// The encoder that turns the recording into codes ended with an error.
    case encoderFailed(status: Int32)
    /// The encoder ended well but wrote no codes.
    case encoderWroteNothing
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

    /// One line per sentence: line breaks inside a sentence become spaces (a line break ends a sentence for the program),
    /// and blank ones go.
    static func lines(from sentences: [String]) -> [String] {
        sentences.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Starts the program now and tells it what to say later, so that it can load its weights while the answer is still
    /// being worked out. A program nobody talks to within `idleLimit` seconds is stopped again.
    public func begin(idleLimit: TimeInterval = 20) throws -> OmniVoiceSession {
        try OmniVoiceSession(runner: self, idleLimit: idleLimit)
    }

    /// One segment per non-empty sentence, in order, each yielded when it is complete. The stream ends with an error when
    /// the engine is not ready, cannot start, fails, makes no sound or takes longer than `timeout`. Ending the iteration
    /// early stops the program.
    public func speak(_ sentences: [String]) -> AsyncThrowingStream<SpokenSegment, any Error> {
        guard locator.status == .ready else { return AsyncThrowingStream { $0.finish(throwing: OmniVoiceError.notReady(locator.status)) } }
        guard !Self.lines(from: sentences).isEmpty else { return AsyncThrowingStream { $0.finish() } }
        do {
            return try begin().speak(sentences)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}

/// One run of the program, started ahead of the text: `speak` hands it the sentences and streams their sound back.
public final class OmniVoiceSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var spoken = false
    private var stopped = false
    private var timedOut = false

    init(runner: OmniVoiceRunner, idleLimit: TimeInterval) throws {
        let locator = runner.locator
        guard locator.status == .ready else { throw OmniVoiceError.notReady(locator.status) }
        timeout = runner.timeout
        process.executableURL = locator.synthesizer
        process.arguments = runner.arguments()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw OmniVoiceError.launchFailed("\(error)")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + idleLimit) { [weak self] in self?.stopIfUnused() }
    }

    deinit { stop(timedOut: false) }

    /// Whether the program is still there and nobody has spoken through it yet.
    public var isUsable: Bool {
        lock.lock(); defer { lock.unlock() }
        return !spoken && !stopped && process.isRunning
    }

    /// Gives up the program without saying anything.
    public func cancel() { stop(timedOut: false) }

    /// One segment per non-empty sentence, as `OmniVoiceRunner.speak`. A session speaks once.
    public func speak(_ sentences: [String]) -> AsyncThrowingStream<SpokenSegment, any Error> {
        let lines = OmniVoiceRunner.lines(from: sentences)
        return AsyncThrowingStream { continuation in
            lock.lock()
            let usable = !spoken && !stopped && process.isRunning
            spoken = true
            lock.unlock()
            guard usable else { continuation.finish(throwing: OmniVoiceError.expired); return }
            guard !lines.isEmpty else { stop(timedOut: false); continuation.finish(); return }
            continuation.onTermination = { [self] _ in stop(timedOut: false) }
            let input = self.input, output = self.output, process = self.process
            DispatchQueue.global(qos: .userInitiated).async {
                let text = Data((lines.joined(separator: "\n") + "\n").utf8)
                try? input.fileHandleForWriting.write(contentsOf: text)
                try? input.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in stop(timedOut: true) }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
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
                try? output.fileHandleForReading.close()
                if didTimeOut {
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

    private var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    private func stopIfUnused() {
        lock.lock()
        let unused = !spoken
        lock.unlock()
        if unused { stop(timedOut: false) }
    }

    private func stop(timedOut byTimeout: Bool) {
        lock.lock()
        let wasSpoken = spoken
        if !stopped { stopped = true }
        if byTimeout && process.isRunning { timedOut = true }
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
        if !wasSpoken { // nobody reads the streams of a program that never spoke: close them here
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
    }
}
