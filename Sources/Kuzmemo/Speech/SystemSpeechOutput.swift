import AVFoundation
import Foundation
import KuzmemoCore

protocol SpeechOutput: AnyObject {
    var isSpeaking: Bool { get }
    /// Speaks and returns when finished or interrupted.
    func speak(_ text: String) async
    func stop()
}

/// Speaks with the system voice. Picks the best installed Russian voice (premium, then enhanced, then the
/// compact default) unless the user chose one. While muted (dev automation, quiet hours) it says nothing;
/// `SpeechRouter` keeps the record of what would have been said.
final class SystemSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    /// The chosen voice for each language of the interface; `nil` picks the best installed voice of that language.
    var voiceIdentifiers: [AppLanguage: String] = [:]
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var muted = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) async {
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

    /// The voice for what is about to be said: the person's choice for the interface language if it is still installed
    /// (and really speaks that language), else the best installed voice of the language.
    func chosenVoice() -> AVSpeechSynthesisVoice? {
        let language = Localization.current
        if let identifier = voiceIdentifiers[language], let voice = AVSpeechSynthesisVoice(identifier: identifier),
           voice.language.hasPrefix(language.rawValue) { return voice }
        return Self.bestVoice(for: language)
    }

    /// Installed voices of a language, best quality first.
    static func voices(for language: AppLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language.rawValue) }.sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    static func bestVoice(for language: AppLanguage) -> AVSpeechSynthesisVoice? {
        voices(for: language).first ?? AVSpeechSynthesisVoice(language: language == .russian ? "ru-RU" : "en-US")
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
