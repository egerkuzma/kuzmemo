import Foundation
import KuzmemoCore
import Observation

/// The engine failed part-way through an answer: `unspoken` is what the person has not heard yet, so that the fallback
/// voice can say the rest instead of repeating everything.
struct OmniVoiceSpeechFailure: Error {
    var underlying: any Error
    var unspoken: [String]
}

/// Speaks with the person's own voice ("My voice", `omnivoice.cpp`): the answer is cut into sentences, the program makes
/// them one after another, and each is queued for playback the moment it is ready. Sentences it has said before come from
/// the cache. It also knows whether the engine and a voice are in place, which the settings screen shows.
@Observable
final class OmniVoiceSpeechOutput {
    /// What one answer cost, for the settings screen and the control channel.
    struct Report: Equatable {
        var lines: Int
        var cachedLines: Int
        /// Seconds from having the text to the first sentence being ready.
        var firstSoundSeconds: Double?
        /// Seconds until every sentence was ready.
        var madeInSeconds: Double
        var audioSeconds: Double
        /// Silence heard between sentences (a sentence that was not ready in time); `nil` when nothing was played.
        var silenceSeconds: Double?
        var steps: Int
        /// The program had been started ahead of the text.
        var startedAhead: Bool
        /// For every sentence: seconds until it was ready (0 for one from the cache) and how long it lasts.
        var readyAt: [Double]
        var lengths: [Double]
    }

    struct SampleInfo: Equatable {
        var seconds: Double
        var saved: Date
    }

    private(set) var status: OmniVoiceLocator.Status
    private(set) var sample: SampleInfo?
    /// The last thing that went wrong, worded for the person; cleared by the next success.
    private(set) var lastError: String?
    private(set) var lastReport: Report?
    /// Answers being made or played right now.
    private(set) var activePhrases = 0
    var steps = SpeechSettings.defaultCloneSteps

    let locator: OmniVoiceLocator
    let enrollment = VoiceSampleEnrollment()
    @ObservationIgnored private let cache: OmniVoiceCache
    @ObservationIgnored private var prepared: OmniVoiceSession?
    @ObservationIgnored private var player: SegmentPlayer?
    @ObservationIgnored private var current: Task<Report, any Error>?
    @ObservationIgnored private var pruneCounter = 0

    init(locator: OmniVoiceLocator, cache: URL) {
        self.locator = locator
        self.cache = OmniVoiceCache(directory: cache)
        status = locator.status
        refresh()
        enrollment.attach(locator: locator) { [weak self] in self?.voiceChanged() }
    }

    var isReady: Bool { status == .ready }
    var isSpeaking: Bool { current != nil }
    var isBusy: Bool { activePhrases > 0 }

    private var runner: OmniVoiceRunner { OmniVoiceRunner(locator: locator, steps: steps) }

    private var cacheVoice: OmniVoiceCache.Voice? {
        OmniVoiceCache.fingerprint(of: locator).map { .init(fingerprint: $0, steps: steps, language: runner.language) }
    }

    // MARK: - Finding the engine

    /// Looks at the files again: is the program installed, is there a voice.
    func refresh() {
        status = locator.status
        if status == .ready,
           let info = try? WAVInfo(contentsOf: locator.referenceRecording),
           let saved = try? FileManager.default.attributesOfItem(atPath: locator.referenceRecording.path)[.modificationDate] as? Date {
            sample = SampleInfo(seconds: info.seconds, saved: saved)
        } else {
            sample = nil
        }
    }

    /// A voice was saved or forgotten: whatever was made with the old one is no longer right.
    func voiceChanged() {
        stop()
        forgetPrepared()
        cache.clear()
        refresh()
    }

    // MARK: - Starting ahead

    /// Starts the program now, so that it has loaded its weights when the answer arrives. It stops itself if nothing is
    /// said within a few seconds.
    func prewarm() {
        guard status == .ready, prepared?.isUsable != true else { return }
        prepared = try? runner.begin(idleLimit: 25)
    }

    private func forgetPrepared() {
        prepared?.cancel()
        prepared = nil
    }

    /// Drops a program that was started ahead with settings that have changed since.
    func discardPreparedProgram() { forgetPrepared() }

    /// Ends the program (when the app quits).
    func shutDown() {
        stop()
        forgetPrepared()
    }

    // MARK: - Speaking

    /// Speaks the text and returns when it has been played (or interrupted, which throws `CancellationError`). A failure
    /// part-way throws `OmniVoiceSpeechFailure` with what was left unsaid.
    func speak(_ text: String) async throws {
        refresh()
        guard status == .ready else {
            // The fallback voice gets the words as they were written: the lines are spelled out for the neural voice (digits as
            // words, Latin letters in Cyrillic), which the system voice does not need.
            throw OmniVoiceSpeechFailure(underlying: OmniVoiceError.notReady(status), unspoken: [text])
        }
        let lines = OmniVoiceText.lines(for: text)
        guard !lines.isEmpty else { return }
        stop()
        activePhrases += 1
        defer { activePhrases -= 1 }
        let player = SegmentPlayer()
        self.player = player
        let task = Task { @MainActor in try await self.make(lines, player: player) }
        current = task
        defer { if current == task { current = nil; self.player = nil } }
        do {
            lastReport = try await task.value
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = Self.message(for: (error as? OmniVoiceSpeechFailure)?.underlying ?? error)
            throw error
        }
    }

    /// Makes the sentences of an answer without playing them (the control channel's silent check). `keep` gets every
    /// sentence's sound in order.
    /// With a `player` (an offline one, in scripts) the sentences are also queued for it, so its behaviour can be seen.
    func synthesizeOnly(_ text: String, useCache: Bool = false, player: SegmentPlayer? = nil, keep: ((Int, SpokenSegment) -> Void)? = nil) async throws -> (lines: [String], report: Report) {
        refresh()
        guard status == .ready else { throw OmniVoiceError.notReady(status) }
        let lines = OmniVoiceText.lines(for: text)
        guard !lines.isEmpty else { throw OmniVoiceError.producedNoAudio }
        do {
            let report = try await make(lines, player: player, useCache: useCache, keep: keep)
            lastReport = report
            lastError = nil
            return (lines, report)
        } catch {
            lastError = Self.message(for: (error as? OmniVoiceSpeechFailure)?.underlying ?? error)
            throw (error as? OmniVoiceSpeechFailure)?.underlying ?? error
        }
    }

    func stop() {
        current?.cancel()
        current = nil
        player?.stop()
        player = nil
    }

    /// The core: lines that are in the cache are ready at once, the others come from the program; whatever is ready in
    /// order is handed to the player (when there is one).
    private func make(_ lines: [String], player: SegmentPlayer?, useCache: Bool = true, keep: ((Int, SpokenSegment) -> Void)? = nil) async throws -> Report {
        let began = Date()
        let voice = cacheVoice
        var ready: [Int: SpokenSegment] = [:]
        var missing: [(index: Int, line: String)] = []
        var cached = 0
        for (index, line) in lines.enumerated() {
            if useCache, let voice, let hit = cache.segment(for: line, voice: voice) {
                ready[index] = hit
                cached += 1
            } else {
                missing.append((index, line))
            }
        }

        var next = 0
        var firstSound: Double?
        var audio = 0.0
        var readyAt = [Double](repeating: 0, count: lines.count)
        var lengths = [Double](repeating: 0, count: lines.count)
        func handOver() throws {
            while let segment = ready.removeValue(forKey: next) {
                if firstSound == nil { firstSound = Date().timeIntervalSince(began) }
                audio += segment.seconds
                lengths[next] = segment.seconds
                try player?.enqueue(segment)
                keep?(next, segment)
                next += 1
            }
        }

        var startedAhead = false
        var failure: (any Error)?
        do {
            try player?.prepare(sampleRate: 24_000) // the sound device wakes while the sentences are made
            try handOver()
            if !missing.isEmpty {
                let session: OmniVoiceSession
                if let waiting = prepared, waiting.isUsable {
                    session = waiting
                    startedAhead = true
                } else {
                    session = try runner.begin()
                }
                prepared = nil
                var position = 0
                for try await segment in session.speak(missing.map(\.line)) {
                    guard position < missing.count else { break } // the runner never gives more than it was asked for
                    let (index, line) = missing[position]
                    position += 1
                    if useCache, let voice, segment.seconds > 0.2 { cache.store(segment, for: line, voice: voice) }
                    readyAt[index] = Date().timeIntervalSince(began)
                    ready[index] = segment
                    try handOver()
                }
                try Task.checkCancellation() // a cancelled listener just sees the stream end
            }
        } catch is CancellationError {
            player?.stop()
            throw CancellationError()
        } catch {
            failure = error
        }
        let madeIn = Date().timeIntervalSince(began)
        if failure == nil { try? handOver() }

        var heard = next
        if let player {
            player.seal()
            // Waits for the last sentence to be heard, but never for longer than it can last.
            await player.waitUntilFinished(timeout: player.remainingSeconds + 5)
            try Task.checkCancellation()
            if player.cutShort {
                // The device never reported the end of what was queued (it went away mid-answer): the rest is not heard.
                failure = failure ?? SegmentPlayer.Problem.noOutput("the sound stopped before the end of the answer")
                heard = min(heard, player.playedCount)
            }
        }
        pruneCounter += 1
        if pruneCounter % 20 == 0 { cache.prune() }

        if let failure {
            throw OmniVoiceSpeechFailure(underlying: failure, unspoken: Array(lines[min(heard, lines.count)...]))
        }
        return Report(
            lines: lines.count, cachedLines: cached, firstSoundSeconds: firstSound, madeInSeconds: madeIn, audioSeconds: audio,
            silenceSeconds: player.map { $0.silences.reduce(0, +) }, steps: steps, startedAhead: startedAhead,
            readyAt: readyAt, lengths: lengths
        )
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let OmniVoiceError.notReady(status): status == .noVoice ? tr("No voice has been saved yet.") : tr("The program of the voice is not installed.")
        case let OmniVoiceError.launchFailed(reason): tr("The program of the voice could not start: %1$@", reason)
        case let OmniVoiceError.failed(status): tr("The program of the voice ended with an error (%1$lld).", numbers: Int(status))
        case OmniVoiceError.timedOut: tr("The voice took too long to make the answer.")
        case OmniVoiceError.producedNoAudio: tr("The voice made no sound.")
        case OmniVoiceError.expired: tr("The program of the voice was not ready.")
        case let OmniVoiceError.sampleLength(seconds):
            tr(
                "The recording is %1$@ s long; it has to be between %2$@ and %3$@ seconds (8 to 12 is best).",
                String(format: "%.1f", locale: Localization.current.locale, seconds),
                "\(Int(OmniVoiceEnrollment.allowedSeconds.lowerBound))", "\(Int(OmniVoiceEnrollment.allowedSeconds.upperBound))"
            )
        case OmniVoiceError.sampleWithoutWords: tr("Write the words said in the recording (at least two).")
        case OmniVoiceError.sampleUnreadable: tr("The recording could not be read as speech.")
        case let OmniVoiceError.encoderFailed(status): tr("The program that prepares the voice ended with an error (%1$lld).", numbers: Int(status))
        case OmniVoiceError.encoderWroteNothing: tr("The program that prepares the voice made nothing from this recording.")
        case let SegmentPlayer.Problem.noOutput(reason): tr("Could not play the sound: %1$@", reason)
        default: "\(error)"
        }
    }
}
