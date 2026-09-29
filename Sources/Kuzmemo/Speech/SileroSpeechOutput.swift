import AVFoundation
import KuzmemoCore
import Observation

/// Speaks with the Silero neural voice: the text is made ready (`SpeechText`), turned into a WAV file by the Python
/// helper (`SileroHelper`) and played with `AVAudioPlayer`. It also knows whether Silero can be used at all on this
/// Mac (a Python with torch and the model file), which the settings screen shows.
@Observable
final class SileroSpeechOutput: NSObject, AVAudioPlayerDelegate {
    enum Status: Equatable {
        case unknown
        case ready(SileroInstallation)
        case unavailable(SileroLocator.Problem)
        /// This build has no `silero_helper.py` in its resources.
        case missingHelper
    }

    private(set) var status = Status.unknown
    /// The last thing that went wrong, worded for the person; cleared by the next success.
    private(set) var lastError: String?
    /// The voices the loaded model offers (empty until it has been loaded once).
    private(set) var speakers: [String] = []
    private(set) var isLoading = false

    var speaker = SileroVoice.defaultSpeaker
    var rate = 0.5
    /// A Python chosen by hand in the settings.
    var pythonOverride: String?

    @ObservationIgnored private let cache: URL
    @ObservationIgnored private var helper: SileroHelper?
    @ObservationIgnored private var launched: SileroHelper.Launch?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackEnded: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var current: Task<Void, any Error>?

    init(cache: URL) {
        self.cache = cache
        super.init()
        try? FileManager.default.removeItem(at: cache) // whatever an earlier run left behind
    }

    /// Whether a phrase is being made ready or played (a key press then interrupts it).
    var isSpeaking: Bool { current != nil }

    var isReady: Bool { if case .ready = status { true } else { false } }

    // MARK: - Finding Silero

    /// Looks for Python, torch and the model again (only files are looked at) and sets the helper up for what it found.
    func refresh() {
        guard let script = Bundle.main.url(forResource: "silero_helper", withExtension: "py") else {
            status = .missingHelper
            retire()
            return
        }
        switch SileroLocator.find(override: pythonOverride) {
        case let .success(found):
            status = .ready(found)
            let launch = SileroHelper.Launch(python: found.python, script: script, model: found.model)
            guard launch != launched else { return }
            retire()
            launched = launch
            // The start timeout is short: a phrase that has to wait for the model longer than this is spoken by the
            // system voice instead.
            helper = SileroHelper(launch: launch, outputDirectory: cache, idleSeconds: 600, startTimeout: 25, requestTimeout: 20)
        case let .failure(problem):
            status = .unavailable(problem)
            retire()
        }
    }

    private func retire() {
        let old = helper
        helper = nil
        launched = nil
        speakers = []
        if let old { Task { await old.stop() } }
    }

    /// Ends the Python process (when the app quits).
    func shutDown() async {
        stop()
        await helper?.stop()
    }

    // MARK: - Loading

    /// Starts the helper and waits until the model is loaded; done at the start of a recording so that the answer
    /// does not wait for torch.
    func prepare() async {
        if status == .unknown { refresh() }
        guard let helper, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await helper.prepare()
            speakers = await helper.speakers
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func prewarm() {
        guard isReady, !isLoading else { return }
        Task { @MainActor in await prepare() }
    }

    // MARK: - Speaking

    /// Speaks the text and returns when it has been played (or interrupted, which throws `CancellationError`).
    func speak(_ text: String) async throws {
        if status == .unknown { refresh() }
        guard let helper else { throw SileroError.startFailed(unavailableReason) }
        let prepared = SpeechText.forNeuralVoice(text)
        guard !prepared.isEmpty else { return }
        stop()
        let voice = speaker, speed = SileroVoice.Rate(speechRate: rate)
        let task = Task { @MainActor in
            let phrase = try await helper.synthesize(text: prepared, speaker: voice, rate: speed)
            do { try Task.checkCancellation() } catch { try? FileManager.default.removeItem(at: phrase.url); throw error }
            try await self.play(phrase.url)
        }
        current = task
        defer { if current == task { current = nil } }
        do {
            try await task.value
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Makes a phrase into a WAV file without playing it (used by the control channel's silent check).
    func synthesizeOnly(_ text: String) async throws -> (phrase: SileroSynthesis, spoken: String) {
        if status == .unknown { refresh() }
        guard let helper else { throw SileroError.startFailed(unavailableReason) }
        let prepared = SpeechText.forNeuralVoice(text)
        let phrase = try await helper.synthesize(text: prepared, speaker: speaker, rate: .init(speechRate: rate))
        return (phrase, prepared)
    }

    private var unavailableReason: String {
        switch status {
        case let .unavailable(problem): problem.message
        case .missingHelper: "в этой сборке нет вспомогательного файла Silero"
        default: "Silero не готов"
        }
    }

    func stop() {
        current?.cancel()
        current = nil
        player?.stop()
        player = nil
        playbackEnded?.resume()
        playbackEnded = nil
    }

    private func play(_ url: URL) async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        player = next
        guard next.play() else {
            player = nil
            throw SileroError.failed("не удалось начать воспроизведение")
        }
        await withCheckedContinuation { playbackEnded = $0 }
        player = nil
        try Task.checkCancellation()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playbackEnded?.resume()
            self.playbackEnded = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.playbackEnded?.resume()
            self.playbackEnded = nil
        }
    }
}
