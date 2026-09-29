import Foundation
import KuzmemoCore
import KuzmemoSTT
import Observation

/// Making a voice out of a recording the person chose: the file is converted to what the encoder wants, the recognizer
/// suggests the words said in it, the person corrects them (the likeness depends on them being right), and both go to
/// the encoder. Nothing of the old voice is touched until the new one is complete.
@MainActor
@Observable
final class VoiceSampleEnrollment {
    struct Draft: Equatable {
        /// The prepared sample (24 kHz mono 16-bit) in a temporary folder.
        var recording: URL
        var seconds: Double
        /// What is said in it; the person's version once they have edited it.
        var words: String
        /// The words came from the recognizer (rather than being empty because it could not help).
        var suggested: Bool
    }

    enum State: Equatable {
        case idle
        /// Converting, listening to the recording, or saving; the text says which.
        case working(String)
        /// Waiting for the person to check the words.
        case review(Draft)
    }

    private(set) var state = State.idle
    /// Why the last step failed, worded for the person; cleared when a new one starts.
    private(set) var problem: String?

    @ObservationIgnored private var locator: OmniVoiceLocator?
    @ObservationIgnored private var onSaved: (() -> Void)?
    @ObservationIgnored private var scratch: URL?

    func attach(locator: OmniVoiceLocator, onSaved: @escaping () -> Void) {
        self.locator = locator
        self.onSaved = onSaved
    }

    var isBusy: Bool {
        if case .working = state { true } else { false }
    }

    /// Prepares `file` and asks `recognize` (16 kHz mono samples in, the words out, `nil` when it cannot help) what is
    /// said in it. Ends in `.review` with the suggestion, or with a `problem` and back at `.idle`.
    func choose(_ file: URL, recognize: @escaping ([Float]) async -> String?) async {
        guard !isBusy else { return }
        discardScratch()
        problem = nil
        state = .working(tr("Preparing the recording…"))
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-voice-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            scratch = folder
            let prepared = folder.appendingPathComponent("sample.wav")
            try await Self.convert(file, to: prepared)
            let seconds = try WAVInfo(contentsOf: prepared).seconds
            guard OmniVoiceEnrollment.allowedSeconds.contains(seconds) else { throw OmniVoiceError.sampleLength(seconds: seconds) }

            state = .working(tr("Listening to what is said in it…"))
            let samples = try AudioFileLoader.load(prepared)
            let heard = await recognize(samples)
            // Numbers are written out as they are pronounced: the encoder is told the words, and digits do not match the sound.
            let words = heard.map { SpeechText.forNeuralVoice($0) } ?? ""
            state = .review(Draft(recording: prepared, seconds: seconds, words: words, suggested: !words.isEmpty))
        } catch {
            fail(error)
        }
    }

    /// Saves the voice with the words the person confirmed.
    func save(words: String) async {
        guard case let .review(draft) = state, let locator else { return }
        problem = nil
        state = .working(tr("Saving the voice…"))
        do {
            try await OmniVoiceEnrollment(locator: locator).enroll(recording: draft.recording, transcript: words)
            discardScratch()
            state = .idle
            onSaved?()
        } catch {
            problem = OmniVoiceSpeechOutput.message(for: error)
            state = .review(Draft(recording: draft.recording, seconds: draft.seconds, words: words, suggested: draft.suggested)) // the words stay for another try
        }
    }

    /// Enrolls a file directly, for the control channel: no review step.
    func enroll(_ file: URL, words: String) async throws {
        guard let locator else { throw OmniVoiceError.notReady(.notInstalled) }
        discardScratch()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prepared = folder.appendingPathComponent("sample.wav")
        try await Self.convert(file, to: prepared)
        try await OmniVoiceEnrollment(locator: locator).enroll(recording: prepared, transcript: words)
        onSaved?()
    }

    func cancel() {
        discardScratch()
        problem = nil
        state = .idle
    }

    private func fail(_ error: any Error) {
        discardScratch()
        problem = OmniVoiceSpeechOutput.message(for: error)
        state = .idle
    }

    private func discardScratch() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
    }

    /// Any audio the system can read, as a mono 16-bit WAV at 24 kHz (what the encoder and the model work in).
    nonisolated static func convert(_ source: URL, to destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16@24000", "-c", "1", source.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: OmniVoiceError.launchFailed("\(error)"))
            }
        }
        guard status == 0, FileManager.default.fileExists(atPath: destination.path) else { throw OmniVoiceError.sampleUnreadable }
    }
}
