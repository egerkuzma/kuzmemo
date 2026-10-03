import Foundation

/// Puts the person's voice in place (or takes it away): the recording, the words said in it and the codes the
/// synthesizer wants, all in the bundle's `voice` folder. A new voice is built next to the old one and swapped in only
/// when it is complete, so a failed attempt never costs the voice the person already has.
public struct OmniVoiceEnrollment: Sendable {
    /// A sample shorter than this gives a poor likeness, one longer makes every sentence slower (and the maker of the
    /// model advises 3 to 10 seconds).
    public static let allowedSeconds: ClosedRange<Double> = 3 ... 15
    /// The length to aim for.
    public static let idealSeconds: ClosedRange<Double> = 8 ... 12

    public var locator: OmniVoiceLocator
    /// The first run of a new program compiles its GPU kernels, which takes tens of seconds.
    public var timeout: TimeInterval

    public init(locator: OmniVoiceLocator = .standard, timeout: TimeInterval = 120) {
        self.locator = locator
        self.timeout = timeout
    }

    /// The words as the program wants them: one line, single spaces.
    public static func clean(_ transcript: String) -> String {
        transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `recording` is a 16-bit mono WAV of the person speaking; `transcript` says what is said in it, word for word.
    public func enroll(recording: URL, transcript: String) async throws {
        guard locator.isInstalled else { throw OmniVoiceError.notReady(.notInstalled) }
        let words = Self.clean(transcript)
        guard words.split(separator: " ").count >= 2 else { throw OmniVoiceError.sampleWithoutWords }
        let info: WAVInfo
        do { info = try WAVInfo(contentsOf: recording) } catch { throw OmniVoiceError.sampleUnreadable }
        guard info.channels == 1, info.bitsPerSample == 16 else { throw OmniVoiceError.sampleUnreadable }
        guard Self.allowedSeconds.contains(info.seconds) else { throw OmniVoiceError.sampleLength(seconds: info.seconds) }

        let files = FileManager.default
        let parent = locator.voiceDirectory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("voice-new-\(UUID().uuidString)", isDirectory: true)
        try PrivateFiles.directory(staging)
        defer { try? files.removeItem(at: staging) } // nothing is left behind, whether the swap happened or not
        let wav = staging.appendingPathComponent("ref.wav")
        try files.copyItem(at: recording, to: wav)
        try words.write(to: staging.appendingPathComponent("ref.txt"), atomically: true, encoding: .utf8)

        try await encode(wav)
        let codes = staging.appendingPathComponent("ref.rvq")
        let size = (try? files.attributesOfItem(atPath: codes.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw OmniVoiceError.encoderWroteNothing }
        for file in [wav, staging.appendingPathComponent("ref.txt"), codes] { try PrivateFiles.file(file) }

        if files.fileExists(atPath: locator.voiceDirectory.path) {
            _ = try files.replaceItemAt(locator.voiceDirectory, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: locator.voiceDirectory)
        }
    }

    /// Forgets the person's voice.
    public func remove() throws {
        if FileManager.default.fileExists(atPath: locator.voiceDirectory.path) {
            try FileManager.default.removeItem(at: locator.voiceDirectory)
        }
    }

    /// `omnivoice-codec --model <tokenizer> -i ref.wav` writes `ref.rvq` next to the recording.
    private func encode(_ wav: URL) async throws {
        let process = Process()
        process.executableURL = locator.encoder
        process.arguments = ["--model", locator.codecModel.path, "-i", wav.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let timedOut = Flag()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: OmniVoiceError.launchFailed("\(error)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                // an encoder stuck in a GPU call may ignore the request, and enrolling would wait for it for ever
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        if timedOut.value { throw OmniVoiceError.timedOut }
        guard status == 0 else { throw OmniVoiceError.encoderFailed(status: status) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set() { lock.lock(); on = true; lock.unlock() }
}
