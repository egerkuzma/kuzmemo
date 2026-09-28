import AVFoundation
import Foundation

protocol SpeechOutput: AnyObject {
    var isSpeaking: Bool { get }
    /// Speaks and returns when finished or interrupted.
    func speak(_ text: String) async
    func stop()
}

/// Speaks with the system voice. Picks the best installed Russian voice (premium, then enhanced, then the
/// compact default) unless the user chose one. While muted (dev automation, quiet hours) it only records
/// what it would have said.
final class SystemSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    var voiceIdentifier: String?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var muted = false
    /// Everything that was (or would have been) spoken, newest last.
    private(set) var log: [String] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) async {
        log.append(text)
        if log.count > 100 { log.removeFirst(log.count - 100) }
        guard !muted, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = chosenVoice()
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resume()
    }

    func chosenVoice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { return voice }
        return Self.bestRussianVoice()
    }

    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }.sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
        russianVoices().first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}
