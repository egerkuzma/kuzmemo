import AppKit
import AVFoundation
import KuzmemoCore
import KeyboardShortcuts
import KuzmemoSTT
import Observation
import os

/// The voice path from key press to spoken answer: trigger events drive `HotkeyPolicy`, a recording session
/// captures audio, finished recordings go through a serial queue to `UtteranceProcessor`, and the outcome is
/// shown in the HUD, confirmed with a sound and, for answers and questions, read aloud.
@Observable
final class VoiceController {
    enum Phase: Equatable {
        case idle
        case recording(handsFree: Bool)
    }

    enum ModelState: Equatable {
        case notLoaded, loading, ready
        case missing(String)
        case failed(String)
    }

    /// Something the user has to fix before voice input works; the popover explains it.
    enum Problem: Equatable {
        case microphoneDenied
        case inputMonitoringMissing
        case triggerUnavailable
        case modelMissing
    }

    private(set) var phase: Phase = .idle
    private(set) var modelState: ModelState = .notLoaded
    private(set) var problem: Problem?
    private(set) var triggerRunning = false
    private(set) var lastTranscript: String?
    private(set) var pendingJobs = 0

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var isBusy: Bool { pendingJobs > 0 }

    let hud = HUDController()
    let speech: SpeechRouter
    let cues = SoundCues()
    let permissions = PermissionsModel()

    /// The hard cap on a recording (a warning sounds ten seconds before it).
    var recordingLimit: TimeInterval { TimeInterval(env.settings.recording.maxSeconds) }

    /// Timings of the audio path, to find out why a recording came out short (numbers only, never speech or text).
    private static let log = Logger(subsystem: "app.kuzmemo", category: "audio")

    private unowned let env: AppEnvironment
    private let transcriber: WhisperKitTranscriber
    private let utterances: UtteranceProcessor
    /// Turns the Mac's sound off while a recording lasts. `simulatedOutput` is what it drives in the automation build.
    @ObservationIgnored let output: OutputMuteGuard
    @ObservationIgnored let simulatedOutput: SimulatedOutput
    @ObservationIgnored private var policy = HotkeyPolicy()
    @ObservationIgnored private var monitor: ModifierKeyMonitor?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var scriptedInput: (any AudioInput)?
    @ObservationIgnored private var lastTiming: Timing?
    @ObservationIgnored private var jobs: AsyncStream<Job>.Continuation
    @ObservationIgnored private var jobStream: AsyncStream<Job>
    @ObservationIgnored private var nextJobID = 0
    @ObservationIgnored private var activeJob: Int?
    /// The admissions still writing (a recording that has just ended); a quit waits for them, or the last phrase would be lost.
    @ObservationIgnored private var admissions: [Int: Task<Admission, Never>] = [:]
    /// Failed admissions retain their samples until a transcript/audio reaches disk, or the person explicitly quits anyway.
    @ObservationIgnored private var unkeptJobs: [Int: (memo: Memo, samples: [Float])] = [:]
    /// Jobs finish in order (one worker): a job is done when its id is not above this one.
    @ObservationIgnored private var lastFinishedJob = 0
    @ObservationIgnored private var workers: [Task<Void, Never>] = []
    /// Looks for the Input Monitoring grant (one at a time: each one would start a key tap of its own when it appears).
    @ObservationIgnored private var inputMonitoringWatcher: Task<Void, Never>?
    /// The app is quitting: nothing new starts (the quit waits for helper programs, and a key pressed meanwhile would
    /// begin a recording that dies unsaved, with the sound of the Mac off).
    @ObservationIgnored private var terminating = false

    /// How the last recording went, for the log and for explaining a short one.
    private struct Timing {
        /// From the trigger to its release, seconds.
        var held: TimeInterval
        /// How long the microphone took to come up.
        var startSeconds: TimeInterval
        var source: String
    }

    private struct Job {
        var id: Int
        var utterance: Utterance
        /// The phrase made for the recording the moment it ended (its audio in the spool, a `recorded` row in the database). It is
        /// started before the job waits its turn, so that a quit or a crash while another phrase is being worked on loses
        /// nothing: the next launch finds the phrase and recognises it.
        var admission: Task<Admission, Never>
        /// Set when the recording answers a question the app asked.
        var reply: AppEnvironment.PendingQuestion?
        var done: (@MainActor @Sendable (UtteranceResult) -> Void)?
    }

    private final class Session {
        let input: any AudioInput
        let meter: LevelMeter
        /// When the trigger asked for the recording; `startedAt` is later, once the microphone was up.
        let requestedAt: TimeInterval
        let startedAt: TimeInterval
        let spokenAt: LocalDateTime
        /// The question this recording answers, if any.
        let question: AppEnvironment.PendingQuestion?
        var handsFree = false
        var detector: EndOfSpeechDetector
        var smoothedLevel: Float = 0
        var warnedLimit = false
        var tick: Task<Void, Never>?
        /// The sound of the Mac was turned off for this recording and has to come back.
        var mutesOutput = false

        init(
            input: any AudioInput, meter: LevelMeter, requestedAt: TimeInterval, startedAt: TimeInterval, spokenAt: LocalDateTime,
            question: AppEnvironment.PendingQuestion?
        ) {
            self.input = input
            self.meter = meter
            self.requestedAt = requestedAt
            self.startedAt = startedAt
            self.spokenAt = spokenAt
            self.question = question
            handsFree = question != nil
            detector = question == nil ? VoiceController.holdWatchdog() : VoiceController.answerDetector()
        }
    }

    init(env: AppEnvironment) {
        self.env = env
        speech = SpeechRouter(cache: env.paths.speechCache, voice: .standard(voice: env.paths.voice), voiceCache: env.paths.voiceCache)
        let transcriber = WhisperKitTranscriber(configuration: .standard())
        self.transcriber = transcriber
        utterances = UtteranceProcessor(
            recognizer: Recognizer(transcriber: transcriber), processor: env.processor, store: env.store,
            spool: AudioSpool(directory: env.paths.audioSpool), clock: env.clock
        )
        (jobStream, jobs) = AsyncStream.makeStream(of: Job.self)
        // The automation build must never touch the Mac's sound; it gets a stand-in that scripts can look at.
        let simulated = SimulatedOutput()
        simulatedOutput = simulated
        let backend: any OutputAudioBackend = AppPaths.isAutomation ? simulated : CoreAudioOutput()
        output = OutputMuteGuard(backend: backend, journal: FileSilenceJournal(url: env.paths.support.appendingPathComponent("output-mute.json")))
    }

    // MARK: - Lifecycle

    func start() {
        // Automation must never make noise: that build starts muted and scripts opt in explicitly.
        if AppPaths.isAutomation { speech.muted = true; cues.muted = true }
        output.recoverAfterCrash() // the last run may have been killed while the sound was off

        hud.actions = HUDActions(
            cancel: { [weak self] in self?.cancelRecording(note: nil) },
            undo: { [weak self] opID in
                Task { @MainActor in
                    await self?.env.undo(opID: opID)
                    self?.hud.showNote(tr("Undone"), style: .success, seconds: 2)
                }
            },
            edit: { [weak self] itemID in
                self?.hud.hide()
                self?.env.openEditor(itemID: itemID)
            },
            choose: { [weak self] option in Task { @MainActor in await self?.choose(option) } }
        )

        if !AppPaths.isAutomation {
            // The automation build never listens to the person's keys: it would fight their own copy of the app.
            startTrigger()
            registerChord()
        }
        observeSystem()
        env.settings.observe { [weak self] group in self?.settingsChanged(group) }
        workers.append(Task { @MainActor [weak self] in
            // The saved preferences decide which model to load, so they come first.
            await self?.env.settings.load()
            self?.warmModel()
        })

        workers.append(Task { @MainActor [weak self] in
            guard let stream = self?.jobStream else { return }
            for await job in stream { await self?.run(job) }
        })
        workers.append(Task { @MainActor [weak self] in
            await self?.recoverUnfinished(includeBlocked: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.recoverUnfinished(includeBlocked: false)
            }
        })
    }

    /// Everything that was recorded or transcribed but not finished: the app quit, the model was missing, or a
    /// scheduled retry has come due.
    private func recoverUnfinished(includeBlocked: Bool) async {
        let spoken = await utterances.recoverUnfinished(includeBlocked: includeBlocked)
        let typed = await env.processor.recoverUnfinished()
        for outcome in spoken.compactMap(\.outcome) + typed { await announceRecovered(outcome) }
    }

    private func announceRecovered(_ outcome: ProcessOutcome) async {
        await env.present(outcome, announce: false)
        guard case let .applied(result) = outcome.kind, !result.changes.isEmpty, session == nil else { return }
        let today = env.clock.localNow().date
        if env.settings.speech.confirmationSound { cues.play(.saved) }
        hud.showNote(tr("Saved the delayed phrase: %1$@", result.changes.map { $0.summary(today: today) }.joined(separator: "; ")), style: .success, seconds: 5)
    }

    // MARK: - Settings

    /// The interface language changed: whatever is being said in the old one is cut off.
    func languageChanged() {
        speech.stop()
    }

    /// Puts a changed preference to work.
    func settingsChanged(_ group: AppSettings.Group) {
        let settings = env.settings
        switch group {
        case .speech:
            speech.system.voiceIdentifiers = [.russian: settings.speech.voiceIdentifier, .english: settings.speech.englishVoiceIdentifier].compactMapValues { $0 }
            speech.system.rate = Float(settings.speech.rate)
            speech.engine = settings.speech.engine
            speech.silero.speaker = settings.speech.sileroSpeaker
            speech.silero.rate = settings.speech.rate
            if speech.silero.pythonOverride != settings.speech.sileroPython || !speech.silero.isReady {
                speech.silero.pythonOverride = settings.speech.sileroPython
                speech.silero.refresh()
            }
            if speech.clone.steps != settings.speech.cloneSteps {
                speech.clone.steps = settings.speech.cloneSteps
                speech.clone.discardPreparedProgram() // it was started with the old number of steps
            }
            if settings.loaded { speech.prewarm() } // switching to the neural voice loads it now
        case .recording:
            policy.configuration.holdThreshold = settings.recording.holdThreshold
            policy.configuration.maxRecording = TimeInterval(settings.recording.maxSeconds)
        case .notifications:
            break // the notification scheduler listens to this one itself
        case .recognition:
            let configuration = Self.whisperConfiguration(settings.recognition)
            Task { @MainActor in
                await transcriber.reconfigure(configuration)
                if settings.loaded { warmModel() } // a new model starts loading now, not at the first recording
            }
        }
    }

    /// The model, language and idle time to use; a saved model that is no longer installed falls back to the default.
    static func whisperConfiguration(_ recognition: RecognitionSettings) -> WhisperKitConfiguration {
        var variant = recognition.modelVariant
        if let known = ModelCatalog.variant(id: variant), !ModelCatalog.isInstalled(known) { variant = RecognitionSettings.defaultVariant }
        var configuration = WhisperKitConfiguration.standard(variant: variant, language: recognition.language)
        configuration.idleUnloadSeconds = TimeInterval(recognition.idleUnloadMinutes * 60)
        return configuration
    }

    /// Says a sample with the current voice and speed (the settings window's "Listen").
    func previewSpeech(_ text: String) {
        Task { @MainActor in await speakUnprompted(text) }
    }

    /// Something nobody has just asked for (an alert's title, a sample): it never talks over a recording, whose microphone
    /// would hear it, and is dropped while the app quits.
    func speakUnprompted(_ text: String) async {
        guard session == nil, !terminating, env.settings.isLoaded(.speech) else { return }
        await speech.speak(text)
    }

    /// Recognises a short test recording without creating a memo (the settings window's check).
    func recognizeForTest(_ samples: [Float]) async -> Result<Recognition, any Error> {
        do { return .success(try await Recognizer(transcriber: transcriber).recognize(samples)) } catch { return .failure(error) }
    }

    /// The model that is loaded or loading, for the settings window.
    var modelSummary: String {
        switch modelState {
        case .notLoaded: tr("not loaded (loads at the first recording)")
        case .loading: tr("loading…")
        case .ready: tr("ready")
        case .missing: tr("not found")
        case let .failed(reason): tr("error: %1$@", "\(reason)")
        }
    }

    // MARK: - Trigger

    private func startTrigger() {
        // The automation build never listens to the person's keys: it would fight their own copy of the app.
        guard !AppPaths.isAutomation, !terminating else { return }
        permissions.refresh()
        if monitor?.isActive == true { triggerRunning = true; return }
        monitor?.stop() // a tap the system took away is removed before another is made, never left to fire into a dead object
        monitor = nil
        guard permissions.inputMonitoring else {
            triggerRunning = false
            problem = .inputMonitoringMissing
            waitForInputMonitoring()
            return
        }
        let monitor = ModifierKeyMonitor(key: .fn, handlers: .init(
            down: { [weak self] time in MainActor.assumeIsolated { self?.triggerDown(at: time) } },
            up: { [weak self] time in MainActor.assumeIsolated { self?.triggerUp(at: time) } },
            otherKey: { [weak self] time in MainActor.assumeIsolated { self?.otherKeyPressed(at: time) } },
            escape: { [weak self] in MainActor.assumeIsolated { self?.escapePressed() } }
        ))
        self.monitor = monitor
        triggerRunning = monitor.start()
        if triggerRunning {
            if problem == .inputMonitoringMissing || problem == .triggerUnavailable { problem = nil }
        } else {
            problem = .triggerUnavailable
        }
    }

    /// The fallback chord feeds the same state machine as the Fn key.
    private func registerChord() {
        KeyboardShortcuts.onKeyDown(for: .recordVoice) { [weak self] in MainActor.assumeIsolated { self?.triggerDown() } }
        KeyboardShortcuts.onKeyUp(for: .recordVoice) { [weak self] in MainActor.assumeIsolated { self?.triggerUp() } }
    }

    /// How the fallback chord is written, for hints ("⌃⌥M").
    var chordDescription: String? { KeyboardShortcuts.getShortcut(for: .recordVoice)?.description }

    /// The grant is made in System Settings, outside the app, so look for it until it appears.
    private func waitForInputMonitoring() {
        guard inputMonitoringWatcher == nil else { return }
        inputMonitoringWatcher = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, !self.permissions.inputMonitoring {
                try? await Task.sleep(for: .seconds(2))
                self.permissions.refresh()
            }
            guard let self else { return }
            inputMonitoringWatcher = nil
            startTrigger()
        }
    }

    func requestInputMonitoring() {
        permissions.requestInputMonitoring()
        PermissionsModel.openSettings(.inputMonitoring)
    }

    func triggerDown(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        perform(policy.triggerDown(at: time, speaking: speech.isSpeaking))
    }

    func triggerUp(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        perform(policy.triggerUp(at: time))
        enterHandsFreeIfTapped()
    }

    func otherKeyPressed(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        perform(policy.otherKeyPressed(at: time))
    }

    func escapePressed() {
        if session != nil {
            cancelRecording(note: nil)
        } else if speech.isSpeaking {
            speech.stop()
        }
    }

    /// The popover's record button: the same as tapping the trigger key.
    func toggleFromUI() {
        let now = ProcessInfo.processInfo.systemUptime
        triggerDown(at: now)
        triggerUp(at: now + 0.05)
    }

    private func perform(_ actions: [HotkeyPolicy.Action]) {
        for action in actions {
            switch action {
            case .interruptSpeech: speech.stop()
            case .startRecording: startRecording()
            case .stopRecording: finishRecording()
            case .cancelRecording: cancelRecording(note: nil)
            }
        }
    }

    // MARK: - Recording

    /// The window for answering a question: wait a few seconds for the first word, then stop shortly after the last.
    static func answerDetector() -> EndOfSpeechDetector {
        EndOfSpeechDetector(configuration: .init(silenceAfterSpeech: 1.5, speechWait: 7))
    }

    static func holdWatchdog() -> EndOfSpeechDetector {
        // Push-to-talk ends when the key is released; this only catches a release that was never seen.
        EndOfSpeechDetector(configuration: .init(silenceAfterSpeech: 30, speechWait: 30))
    }

    /// The microphone for a new recording or a check: what Settings → Recording says, with the built-in one standing in for a
    /// Bluetooth headset (whose microphone takes seconds to start; see `MicrophoneChoice`). The automation build must not get
    /// here: it never opens the real microphone (callers refuse first; see `microphoneIsOff`).
    func makeMicrophone() -> any AudioInput {
        let pick = MicrophoneChoice.pick(env.settings.recording.microphonePreference, among: InputDevices.all())
        if let device = pick.device, let captureDevice = AVCaptureDevice(uniqueID: device.uid) {
            return DeviceMicCapture(device: captureDevice)
        }
        return MicCapture()
    }

    /// The automation build never opens the real microphone by itself, nor asks for the permission: a script arms an input
    /// first (`/voice/input`).
    static var microphoneIsOff: Bool { AppPaths.isAutomation }

    static var microphoneIsOffMessage: String { tr("The microphone is off in this build (it is used for automated checks).") }

    /// Starts `input` and reports its levels. A microphone picked by name may be gone (unplugged, the lid closed): the
    /// system's input stands in for it. Returns what is running.
    func start(_ input: any AudioInput, level: @escaping @Sendable (Float) -> Void) throws -> any AudioInput {
        input.onLevel = level
        do {
            try input.start()
            return input
        } catch {
            guard input is DeviceMicCapture else { throw error }
            Self.log.error("microphone did not start (\(String(describing: error), privacy: .public)); using the system input")
            let fallback = MicCapture()
            fallback.onLevel = level
            try fallback.start()
            return fallback
        }
    }

    private func startRecording() {
        guard session == nil else { return }
        guard !terminating else { policy.recordingEnded(); return }
        guard env.settings.isLoaded(.recording), env.settings.isLoaded(.recognition), env.settings.isLoaded(.speech) else {
            policy.recordingEnded()
            hud.showNote(tr("Recording settings are still loading. Please try again."), style: .warning, seconds: 5)
            return
        }
        let candidate: any AudioInput
        if let scripted = scriptedInput {
            candidate = scripted
            scriptedInput = nil
        } else {
            guard !Self.microphoneIsOff else {
                policy.recordingEnded()
                hud.showNote(Self.microphoneIsOffMessage, style: .warning, seconds: 4)
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                policy.recordingEnded()
                hud.showNote(tr("Allow microphone access in the system dialog and press the key again."), style: .warning, seconds: 6)
                Task { await permissions.requestMicrophone() }
                return
            default:
                policy.recordingEnded()
                problem = .microphoneDenied
                hud.showNote(tr("No microphone access. Allow it: System Settings → Privacy & Security → Microphone."), style: .error, seconds: 8)
                return
            }
            candidate = makeMicrophone()
        }
        if problem == .microphoneDenied { problem = nil }

        let meter = LevelMeter()
        let question = env.pendingQuestion // a recording made while a question is open is its answer
        if let question {
            hud.show(.listening(env.toast ?? AppEnvironment.Toast(style: .question, lines: [question.question], options: question.options)))
        } else {
            hud.show(.recording(handsFree: false))
        }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        // The sound goes off first, so that speakers do not feed the music into the microphone.
        let muting = env.settings.recording.muteWhileRecording
        if muting { output.begin() }
        let input: any AudioInput
        do {
            input = try start(candidate) { level in meter.record(level) }
        } catch {
            if muting { output.end() }
            policy.recordingEnded()
            hud.showNote(tr("Could not turn on the microphone: %1$@", "\(error)"), style: .error, seconds: 6)
            return
        }

        let session = Session(
            input: input, meter: meter, requestedAt: requestedAt, startedAt: ProcessInfo.processInfo.systemUptime,
            spokenAt: env.clock.localNow(), question: question
        )
        session.mutesOutput = muting
        self.session = session
        phase = .recording(handsFree: question != nil)
        speech.stop()
        warmModel() // the model loads while the person is still talking
        speech.prewarm() // …and so does the neural voice, if it is the one in use
        session.tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.tick()
            }
        }
    }

    /// A tap (released quickly) leaves the recording running hands-free, which stops on silence.
    private func enterHandsFreeIfTapped() {
        guard let session, !session.handsFree, case .toggled = policy.state else { return }
        session.handsFree = true
        session.detector = EndOfSpeechDetector(configuration: .init(silenceAfterSpeech: env.settings.recording.handsFreeSilence, speechWait: 20))
        phase = .recording(handsFree: true)
        hud.show(.recording(handsFree: true))
    }

    private func tick() {
        guard let session else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - session.startedAt
        let peak = session.meter.takePeak()
        session.smoothedLevel = max(peak, session.smoothedLevel * 0.7)
        hud.updateRecording(level: session.smoothedLevel, elapsed: elapsed)

        switch session.detector.feed(level: peak, at: elapsed) {
        case .endOfSpeech: finishRecording()
        case .noSpeech:
            if session.question != nil { giveUpListening() } else { cancelRecording(note: tr("No speech heard — recording stopped.")) }
        case .speechStarted, nil: break
        }
        guard self.session === session else { return }
        if elapsed >= recordingLimit {
            finishRecording()
        } else if elapsed >= recordingLimit - 10, !session.warnedLimit {
            session.warnedLimit = true
            cues.play(.attention) // ten seconds left
        }
    }

    private func endSession() -> (samples: [Float], spokenAt: LocalDateTime, question: AppEnvironment.PendingQuestion?)? {
        guard let session else { return nil }
        self.session = nil
        session.tick?.cancel()
        let samples = session.input.stop()
        if session.mutesOutput { output.end() } // the sound comes back before anything is said or played
        lastTiming = Timing(
            held: ProcessInfo.processInfo.systemUptime - session.requestedAt, startSeconds: session.input.startSeconds,
            source: session.input.sourceName
        )
        phase = .idle
        policy.recordingEnded()
        return (samples, session.spokenAt, session.question)
    }

    /// Esc or the ✕ in the HUD. Cancelling an answer closes the question and saves nothing.
    func cancelRecording(note: String?) {
        guard let ended = endSession() else { return }
        if let note { hud.showNote(note, style: .warning, seconds: 2.5) } else { hud.hide() }
        if ended.question != nil { Task { await env.closeQuestion(keep: false) } }
    }

    /// Nobody answered the question in time: keep the original words as a note.
    private func giveUpListening() {
        guard endSession() != nil else { return }
        Task { @MainActor in await closeUnanswered() }
    }

    /// `taken` is the question when it has already been taken out of play (the answer was recorded and could not be
    /// recognised): without it the closing finds no question, saves nothing, and the phrase stays open until the next launch.
    private func closeUnanswered(_ taken: AppEnvironment.PendingQuestion? = nil) async {
        await env.closeQuestion(taken, keep: true)
        if let toast = env.toast { showBackground(.result(toast), autoHideAfter: Self.displaySeconds(for: toast)) } else { showBackground(.hidden) }
    }

    private func finishRecording() {
        guard let (samples, spokenAt, question) = endSession() else { return }
        let seconds = Double(samples.count) / 16_000
        let timing = lastTiming
        if let timing {
            Self.log.notice("""
                recording: held \(timing.held, format: .fixed(precision: 2), privacy: .public) s, \
                microphone up in \(timing.startSeconds, format: .fixed(precision: 2), privacy: .public) s, \
                captured \(seconds, format: .fixed(precision: 2), privacy: .public) s from \(timing.source, privacy: .private)
                """)
        }
        guard seconds >= 0.6 else {
            if question != nil {
                Task { @MainActor in await closeUnanswered() }
            } else if let timing, timing.startSeconds >= 0.8 {
                // Not too short on the person's side: the microphone was slow to come up and ate the beginning.
                let took = String(format: "%.1f", locale: Localization.current.locale, timing.startSeconds)
                hud.showNote(
                    tr("The microphone needed %1$@ s to start, so the beginning was not recorded. Choose the built-in microphone in Settings → Recording.", took),
                    style: .warning, seconds: 7
                )
            } else {
                hud.showNote(tr("Recording too short — skipped."), style: .warning, seconds: 2)
            }
            return
        }
        if question != nil { _ = env.takeQuestion() } // from here on the question is being answered
        enqueue(Utterance(samples: samples, spokenAt: spokenAt), reply: question, done: nil)
    }

    // MARK: - Queue

    private func enqueue(
        _ utterance: Utterance, reply: AppEnvironment.PendingQuestion? = nil, done: (@MainActor @Sendable (UtteranceResult) -> Void)?
    ) {
        nextJobID += 1
        pendingJobs += 1
        showBackground(modelState == .loading ? .preparingModel : .transcribing)
        // The phrase is saved right away, in parallel with whatever the worker is doing; the job is queued at once, so two quick
        // recordings keep their order.
        let utterances = self.utterances
        let id = nextJobID
        let admission = Task { @MainActor [weak self] in
            let admitted = await utterances.admit(utterance, replyTo: reply.map { Reply(memoID: $0.memoID, question: $0.question) })
            self?.admissions[id] = nil
            if let failure = admitted.failure {
                self?.unkeptJobs[id] = (admitted.memo, utterance.samples)
                Self.log.error("the recording could not be kept: \(failure, privacy: .public)")
                self?.hud.showNote(tr("The recording could not be kept on disk, so a crash would have lost it: %1$@", failure), style: .warning, seconds: 6)
            }
            return admitted
        }
        admissions[id] = admission
        jobs.yield(Job(id: id, utterance: utterance, admission: admission, reply: reply, done: done))
    }

    /// Waits until every recording that has just ended is on disk and in the database (the quit path). A recording that could
    /// not be written is nowhere but in the queue: the quit then waits for the worker to carry it through (recognition, the
    /// model, the entry), within reason, rather than lose it without a word.
    func awaitAdmissions() async -> Bool {
        for task in admissions.values { _ = await task.value }
        let deadline = ContinuousClock.now + .seconds(90)
        while let last = unkeptJobs.keys.max(), last > lastFinishedJob, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        for (id, kept) in unkeptJobs where id <= lastFinishedJob {
            do {
                try await utterances.keepAfterFailure(kept.memo, samples: kept.samples)
                unkeptJobs[id] = nil
            } catch { /* The quit must report that this recording is still only in memory. */ }
        }
        return unkeptJobs.isEmpty
    }

    private func run(_ job: Job) async {
        activeJob = job.id
        let admitted = await job.admission.value
        let result = await utterances.process(admitted: admitted.memo, samples: job.utterance.samples) { [weak self] stage in
            Task { @MainActor in self?.stageChanged(stage, job: job.id) }
        }
        activeJob = nil
        await present(result, replyingTo: job.reply)
        if unkeptJobs[job.id] != nil {
            if case .noSpeech = result.kind { unkeptJobs[job.id] = nil } else if await utterances.isKept(memoID: admitted.memo.id) {
                unkeptJobs[job.id] = nil
            }
        }
        pendingJobs -= 1
        lastFinishedJob = job.id
        job.done?(result)
    }

    private func stageChanged(_ stage: UtteranceStage, job: Int) {
        guard activeJob == job else { return }
        switch stage {
        case .transcribing: showBackground(modelState == .loading ? .preparingModel : .transcribing)
        case let .interpreting(text):
            showBackground(.interpreting(text))
            // Claude is being asked and its answer may be spoken in a couple of seconds: the cloned voice loads meanwhile
            // (not earlier: nothing said, nothing to load, and the recognizer is not disturbed).
            if env.settings.speech.speakAnswers { speech.prewarmForAnswer() }
        }
    }

    /// Shows a state unless the person is recording right now: the recording HUD always wins.
    private func showBackground(_ state: HUDModel.State, autoHideAfter seconds: TimeInterval? = nil) {
        guard session == nil else { return }
        hud.show(state, autoHideAfter: seconds)
    }

    // MARK: - Presenting

    private func present(_ result: UtteranceResult, replyingTo question: AppEnvironment.PendingQuestion?) async {
        lastTranscript = result.transcript ?? lastTranscript
        switch result.kind {
        case .noSpeech:
            if let question { await closeUnanswered(question) } else {
                showBackground(.note(tr("No speech heard — nothing was saved."), .warning), autoHideAfter: 2.5)
            }

        case let .recognitionFailed(message, needsUser, retryAt):
            cues.play(.attention)
            if let question {
                await closeUnanswered(question)
            } else if needsUser {
                modelState = .missing(message)
                problem = .modelMissing
                let note = result.recordingKept
                    ? tr("No recognition model. Your recording is saved — download the model in Settings → Recognition.")
                    : tr("No recognition model, and the recording could not be kept. Download the model in Settings → Recognition.")
                showBackground(.note(note, .error), autoHideAfter: 8)
            } else {
                let message = !result.recordingKept
                    ? tr("Could not recognize the speech, and the recording could not be kept.")
                    : retryAt == nil
                    ? tr("Could not recognize the speech. Your recording is saved.")
                    : tr("Could not recognize the speech. Your recording is saved; I will try again later.")
                showBackground(.note(message, .error), autoHideAfter: 6)
            }

        case let .processed(outcome):
            await env.present(outcome, announce: true, round: (question?.round ?? 0) + 1)
            await showOutcome(outcome)
        }
    }

    /// The HUD, sound and speech for an outcome that `AppEnvironment.present` has already recorded.
    private func showOutcome(_ outcome: ProcessOutcome) async {
        if case .erased = outcome.kind { showBackground(.hidden); return } // everything was erased meanwhile: nothing to show or say
        guard let toast = env.toast else { showBackground(.hidden); return }
        let spoken = await spokenText(for: outcome)
        switch outcome.kind {
        case .applied: if env.settings.speech.confirmationSound { cues.play(.saved) }
        case .unknown, .failed: cues.play(.attention)
        case .answered, .clarify, .erased: break
        }
        let asking = env.pendingQuestion != nil
        if let spoken, session == nil {
            showBackground(.result(toast))
            await speech.speak(spoken)
            if asking { startListening() } else { showBackground(.result(toast), autoHideAfter: 2.5) }
        } else if asking {
            startListening()
        } else {
            showBackground(.result(toast), autoHideAfter: Self.displaySeconds(for: toast))
        }
    }

    /// Opens the microphone for the answer to the question on screen. Automation never opens the real
    /// microphone on its own: it has to arm a scripted input first.
    private func startListening() {
        guard env.pendingQuestion != nil, session == nil else { return }
        if AppPaths.isAutomation && scriptedInput == nil { return }
        perform(policy.beginHandsFree())
    }

    /// "Retry" on an Inbox card whose recording could not be recognised.
    func retryRecognition(memoID: String) async {
        pendingJobs += 1
        defer { pendingJobs -= 1 }
        guard let result = await utterances.retry(memoID: memoID) else { return }
        await present(result, replyingTo: nil)
    }

    /// An option chosen by tapping it (in the HUD or the popover) answers the question without speech.
    @discardableResult
    func choose(_ option: String) async -> ProcessOutcome? {
        guard let question = env.pendingQuestion else { return nil }
        if session != nil { _ = endSession() } // stop listening; the tap is the answer
        speech.stop()
        showBackground(.interpreting(option))
        pendingJobs += 1
        defer { pendingJobs -= 1 }
        guard let outcome = await env.answer(option, inputKind: question.inputKind) else { return nil }
        await showOutcome(outcome)
        return outcome
    }

    private func spokenText(for outcome: ProcessOutcome) async -> String? {
        guard env.settings.isLoaded(.speech) else { return nil }
        let speechSettings = env.settings.speech
        switch outcome.kind {
        case .answered:
            guard speechSettings.speakAnswers, let result = env.queryResult else { return nil }
            let glossary = (try? await env.store.glossary()) ?? []
            return AgendaSpeaker(glossary: glossary).speech(for: result, today: env.clock.localNow().date)
        case let .clarify(clarification):
            return speechSettings.speakAnswers ? clarification.question : nil
        case let .applied(result):
            guard speechSettings.speakConfirmations, !result.changes.isEmpty else { return nil }
            let glossary = (try? await env.store.glossary()) ?? []
            let today = env.clock.localNow().date
            return result.changes.map { $0.spokenConfirmation(today: today, glossary: glossary) }.joined(separator: " ")
        default:
            return nil
        }
    }

    /// How long the HUD keeps a result: 2 s for a confirmation with Undo, time to read for anything else (see `ResultDisplay`).
    static func displaySeconds(for toast: AppEnvironment.Toast) -> TimeInterval {
        ResultDisplay.seconds(characters: toast.lines.reduce(0) { $0 + $1.count }, lines: toast.lines.count, undoable: toast.undoOpID != nil)
    }

    // MARK: - Model

    func warmModel() {
        guard env.settings.isLoaded(.recognition) else { return }
        guard modelState != .loading else { return }
        Task { @MainActor in await loadModel() }
    }

    private func loadModel() async {
        if modelState == .ready, await transcriber.isLoaded { return }
        modelState = .loading
        // A load that takes more than a moment is the one-time compilation for this Mac: say so.
        let slow = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.session == nil, self.activeJob == nil, self.hud.model.state == .hidden else { return }
            self.hud.show(.preparingModel)
        }
        defer {
            slow.cancel()
            if hud.model.state == .preparingModel, activeJob == nil { hud.hide() }
        }
        do {
            try await transcriber.prepare()
            modelState = .ready
            if problem == .modelMissing { problem = nil }
        } catch TranscriberError.modelMissing(let path) {
            modelState = .missing(path)
            problem = .modelMissing
        } catch {
            modelState = .failed("\(error)")
        }
    }

    // MARK: - System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviveTrigger() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviveTrigger() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }
    }

    /// Sleep or a locked screen: a key-up may never arrive, so drop whatever is in progress.
    private func interrupt() {
        speech.stop()
        perform(policy.reset())
    }

    private func reviveTrigger() {
        guard !AppPaths.isAutomation, !terminating else { return } // waking up must not give the automation build the person's keys
        permissions.refresh()
        if monitor?.revive() == false || monitor == nil { startTrigger() }
    }

    // MARK: - Quitting

    /// The app is quitting: what is being recorded or said stops, the sound of the Mac comes back at once and nothing new starts.
    /// The quit itself waits for the helper programs, and the person may still press a key meanwhile.
    func beginTermination() {
        terminating = true
        speech.stop()
        if session != nil { cancelRecording(note: nil) }
        output.forceEnd()
    }

    func cancelTermination() { terminating = false }

    // MARK: - Automation (control channel)

    /// The next recording plays these samples instead of listening to the microphone.
    func armScriptedInput(samples: [Float]) {
        scriptedInput = ScriptedAudioInput(samples: samples)
    }

    /// Pushes a recording straight into the pipeline, as if the trigger had just been released, and waits for it.
    func inject(samples: [Float]) async -> UtteranceResult {
        await withCheckedContinuation { continuation in
            enqueue(Utterance(samples: samples, spokenAt: env.clock.localNow())) { continuation.resume(returning: $0) }
        }
    }

    func setMuted(_ muted: Bool) {
        speech.muted = muted
        cues.muted = muted
    }

    var policyDescription: String { "\(policy.state)" }
}

extension UtteranceResult {
    /// The pipeline outcome, when the recording got as far as being interpreted.
    var outcome: ProcessOutcome? {
        if case let .processed(outcome) = kind { outcome } else { nil }
    }
}
