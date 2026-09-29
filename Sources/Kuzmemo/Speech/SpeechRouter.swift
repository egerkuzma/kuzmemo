import Foundation
import KuzmemoCore

/// The app's voice: the system synthesizer, the Silero neural voice, or the person's own cloned voice, when they chose
/// one and it works. If it is missing or fails, the phrase (or what is left of it) is spoken by the system voice instead,
/// so an answer is never lost. It also keeps the record of what was said, which the control channel reads while sounds
/// are muted.
final class SpeechRouter: SpeechOutput {
    let system = SystemSpeechOutput()
    let silero: SileroSpeechOutput
    let clone: OmniVoiceSpeechOutput
    var engine = SpeechEngine.system
    var muted = false { didSet { system.muted = muted } }

    /// Everything that was (or would have been) spoken, newest last (the last 100).
    private(set) var log: [String] = []
    /// How many phrases there have been in total, so a caller can tell which log entries are new.
    private(set) var spokenCount = 0
    /// The engine that spoke the last phrase, and why the neural voice did not when it was asked to.
    private(set) var lastEngine: SpeechEngine?
    private(set) var lastFallback: String?

    init(cache: URL, voice: OmniVoiceLocator, voiceCache: URL) {
        silero = SileroSpeechOutput(cache: cache)
        clone = OmniVoiceSpeechOutput(locator: voice, cache: voiceCache)
    }

    var isSpeaking: Bool { system.isSpeaking || silero.isSpeaking || clone.isSpeaking }

    func speak(_ text: String) async {
        log.append(text)
        spokenCount += 1
        if log.count > 100 { log.removeFirst(log.count - 100) }
        guard !muted, !text.isEmpty else { return }
        stop()
        var text = text
        if engine == .clone, Localization.current == .russian { // the cloned voice speaks Russian only, like Silero
            do {
                try await clone.speak(text)
                lastEngine = .clone
                lastFallback = nil
                return
            } catch is CancellationError {
                return // interrupted on purpose (a key press, a new phrase): stay quiet
            } catch let failure as OmniVoiceSpeechFailure {
                lastFallback = OmniVoiceSpeechOutput.message(for: failure.underlying)
                text = failure.unspoken.joined(separator: " ") // only what the person has not heard yet
                guard !text.isEmpty else { lastEngine = .clone; return }
            } catch {
                lastFallback = OmniVoiceSpeechOutput.message(for: error)
            }
            lastEngine = .system
            await system.speak(text)
            return
        }
        if engine == .silero, Localization.current == .russian { // the neural voice speaks Russian only
            do {
                try await silero.speak(text)
                lastEngine = .silero
                lastFallback = nil
                return
            } catch is CancellationError {
                return // interrupted on purpose (a key press, a new phrase): stay quiet
            } catch {
                lastFallback = error.localizedDescription
            }
        }
        lastEngine = .system
        await system.speak(text)
    }

    func stop() {
        system.stop()
        silero.stop()
        clone.stop()
    }

    /// Loads the neural voice ahead of time (the start of a recording), so that the answer does not wait for it.
    func prewarm() {
        if engine == .silero, Localization.current == .russian, !muted { silero.prewarm() } // the muted automation build never starts torch on its own
    }

    /// A recording has ended and its answer is a few seconds away: starts the program of the cloned voice so that its
    /// weights are loaded by then. It stops itself if nothing is said.
    func prewarmForAnswer() {
        if engine == .clone, Localization.current == .russian, !muted { clone.prewarm() }
    }
}
