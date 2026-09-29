import Foundation
import KuzmemoCore

/// The app's voice: the system synthesizer, or the Silero neural voice when the person chose it and it works. If
/// Silero is missing or fails, the phrase is spoken by the system voice instead, so an answer is never lost.
/// It also keeps the record of what was said, which the control channel reads while sounds are muted.
final class SpeechRouter: SpeechOutput {
    let system = SystemSpeechOutput()
    let silero: SileroSpeechOutput
    var engine = SpeechEngine.system
    var muted = false { didSet { system.muted = muted } }

    /// Everything that was (or would have been) spoken, newest last (the last 100).
    private(set) var log: [String] = []
    /// How many phrases there have been in total, so a caller can tell which log entries are new.
    private(set) var spokenCount = 0
    /// The engine that spoke the last phrase, and why Silero did not when it was asked to.
    private(set) var lastEngine: SpeechEngine?
    private(set) var lastFallback: String?

    init(cache: URL) {
        silero = SileroSpeechOutput(cache: cache)
    }

    var isSpeaking: Bool { system.isSpeaking || silero.isSpeaking }

    func speak(_ text: String) async {
        log.append(text)
        spokenCount += 1
        if log.count > 100 { log.removeFirst(log.count - 100) }
        guard !muted, !text.isEmpty else { return }
        stop()
        if engine == .silero {
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
    }

    /// Loads the neural voice ahead of time (the start of a recording), so that the answer does not wait for it.
    func prewarm() {
        if engine == .silero, !muted { silero.prewarm() } // the muted automation build never starts torch on its own
    }
}
