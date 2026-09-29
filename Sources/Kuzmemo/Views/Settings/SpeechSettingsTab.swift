import AVFoundation
import KuzmemoCore
import SwiftUI

/// Voice output: which voice, how fast, what is read aloud, and a way to hear it.
struct SpeechSettingsTab: View {
    let env: AppEnvironment
    @State private var voices = SpeechSettingsTab.installedVoices()
    @State private var sample = tr("Hello! You have three things today: stand-up at ten, a team sync at eleven and a report to check at six in the evening.")
    @State private var confirmForget = false

    struct VoiceInfo: Identifiable, Equatable {
        var id: String
        var name: String
        var language: String
        var quality: String
    }

    private var settings: AppSettings { env.settings }

    /// The chosen system voice for the interface language (each language keeps its own).
    private var systemVoiceBinding: Binding<String?> {
        Binding(
            get: { env.language == .english ? env.settings.speech.englishVoiceIdentifier : env.settings.speech.voiceIdentifier },
            set: { if env.language == .english { env.settings.speech.englishVoiceIdentifier = $0 } else { env.settings.speech.voiceIdentifier = $0 } }
        )
    }

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section(tr("Speech engine")) {
                if env.language == .russian {
                    Picker(tr("Engine"), selection: $settings.speech.engine) {
                        Text(tr("macOS system voice")).tag(SpeechEngine.system)
                        Text(tr("Silero — neural voice")).tag(SpeechEngine.silero)
                        Text(tr("My voice")).tag(SpeechEngine.clone)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if settings.speech.engine == .silero {
                        sileroStatus(settings.speech)
                    } else if settings.speech.engine == .clone {
                        Hint(tr("Answers are spoken in your own voice, learned from a recording of you. It starts speaking a few seconds after the answer is ready, while the other voices start at once. It speaks Russian only."))
                    } else {
                        Hint(tr("The voice built into macOS: fast, nothing to install. The neural Silero voice sounds more natural but needs Python with torch and a model file (installed with one command). Silero speaks Russian only."))
                    }
                } else {
                    Label(tr("macOS system voice"), systemImage: "speaker.wave.2")
                    Hint(tr("The neural Silero voice speaks Russian only: switch the interface language to Russian to use it."))
                }
            }
            if usesClone(settings.speech) { cloneSection(settings.speech) }
            Section(tr("Voice")) {
                if usesClone(settings.speech) {
                    EmptyView() // the voice is the person's own; its pace is its own
                } else if settings.speech.engine == .silero, env.language == .russian {
                    Picker(tr("Silero voice"), selection: $settings.speech.sileroSpeaker) {
                        ForEach(sileroChoices(settings.speech.sileroSpeaker), id: \.id) { Text(verbatim: $0.title).tag($0.id) }
                    }
                } else {
                    Picker(tr("Voice"), selection: systemVoiceBinding) {
                        Text(tr("Best installed")).tag(String?.none)
                        ForEach(voices) { voice in
                            Text(verbatim: "\(voice.name) — \(voice.quality)").tag(Optional(voice.id))
                        }
                    }
                }
                if !usesClone(settings.speech) {
                    LabeledContent(tr("Speed")) {
                        HStack {
                            Text(tr("slower")).font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.speech.rate, in: 0.3 ... 0.6, step: 0.01) { editing in
                                if !editing { preview() }
                            }
                            .frame(width: 200)
                            Text(tr("faster")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Sample phrase")).font(.caption).foregroundStyle(.secondary)
                    // a TextEditor: a multi-line TextField in a grouped form aligns its text to the trailing edge
                    TextEditor(text: $sample)
                        .font(.body)
                        .frame(height: 56)
                        .scrollContentBackground(.hidden)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                }
                HStack {
                    Button { preview() } label: { Label(tr("Listen"), systemImage: "play.fill") }
                    Button { env.voice.speech.stop() } label: { Label(tr("Stop"), systemImage: "stop.fill") }
                    if silero.isBusy || silero.isLoading || env.voice.speech.clone.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    if env.voice.speech.muted { Hint(tr("Sound is off in this build (it is used for automated checks).")) }
                }
                if let reason = env.voice.speech.lastFallback, settings.speech.engine != .system {
                    Hint(tr("The last phrase was spoken by the system voice: %1$@", "\(reason)"))
                }
                if !((settings.speech.engine == .silero || usesClone(settings.speech)) && env.language == .russian), !voices.isEmpty, voices.allSatisfy({ $0.quality == tr("standard") }) {
                    Hint(tr("Only standard voices are installed. Enhanced and premium voices sound noticeably more natural: System Settings → Accessibility → Spoken Content → System Voice → “Manage Voices…”."))
                    Button(tr("Open voice settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Section(tr("What to speak")) {
                Toggle(tr("Answers to questions and clarifications"), isOn: $settings.speech.speakAnswers)
                Toggle(tr("Confirmations: “Saved: event for tomorrow…”"), isOn: $settings.speech.speakConfirmations)
                Toggle(tr("A short sound when an entry is saved"), isOn: $settings.speech.confirmationSound)
            }
        }
        .formStyle(.grouped)
        .onChange(of: env.language) { voices = Self.installedVoices() }
        .task {
            voices = Self.installedVoices()
            env.voice.speech.silero.refresh()
            env.voice.speech.clone.refresh()
        }
        .confirmationDialog(tr("Forget your voice?"), isPresented: $confirmForget) {
            Button(tr("Forget my voice"), role: .destructive) { forgetVoice() }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(tr("The recording and everything made from it are deleted. The voice can be recorded again at any time."))
        }
    }

    // MARK: My voice

    private var clone: OmniVoiceSpeechOutput { env.voice.speech.clone }

    private func usesClone(_ speech: SpeechSettings) -> Bool { speech.engine == .clone && env.language == .russian }

    @ViewBuilder private func cloneSection(_ speech: SpeechSettings) -> some View {
        @Bindable var settings = env.settings
        Section(tr("My voice")) {
            switch clone.status {
            case .notInstalled:
                Label(tr("The program that makes the voice is not installed."), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Hint(tr("For now the system voice speaks. To install it (about 1 GB, one time), run this in Terminal:"))
                Text(verbatim: Self.installCloneCommand).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button(tr("Copy the command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.installCloneCommand, forType: .string)
                    }
                    Button(tr("Check again")) { clone.refresh() }
                }
            case .noVoice:
                Label(tr("No voice yet"), systemImage: "person.wave.2").foregroundStyle(.secondary)
                enrollmentControls
            case .ready:
                Label(savedText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                enrollmentControls
                Picker(tr("Quality"), selection: $settings.speech.cloneSteps) {
                    ForEach(qualityChoices(speech.cloneSteps), id: \.steps) { Text(verbatim: $0.title).tag($0.steps) }
                }
                Hint(tr("More steps sound clearer and take longer; with fewer, words may slur. Sentences said before are kept and play at once."))
                if let report = clone.lastReport {
                    Hint(reportText(report))
                }
            }
            if let error = clone.lastError { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
            Hint(tr("The program runs only while an answer is spoken and needs about 1.3 GB of memory then. The voice model may be used for non-commercial purposes only (CC BY-NC)."))
        }
    }

    private var savedText: String {
        guard let sample = clone.sample else { return tr("Your voice is saved") }
        let seconds = String(format: tr("%.1f s"), locale: Localization.current.locale, sample.seconds)
        let date = sample.saved.formatted(.dateTime.day().month(.abbreviated).locale(Localization.current.locale))
        return tr("Your voice is saved · recording %1$@ · %2$@", seconds, date)
    }

    private func reportText(_ report: OmniVoiceSpeechOutput.Report) -> String {
        let first = report.firstSoundSeconds.map { String(format: "%.1f", locale: Localization.current.locale, $0) } ?? "–"
        let made = String(format: "%.1f", locale: Localization.current.locale, report.madeInSeconds)
        return tr("Last answer: the first sound after %1$@ s, all sentences ready after %2$@ s.", first, made)
    }

    private struct QualityChoice { var steps: Int; var title: String }

    private func qualityChoices(_ current: Int) -> [QualityChoice] {
        var choices = [
            QualityChoice(steps: 8, title: tr("Fast — 8 steps")),
            QualityChoice(steps: 12, title: tr("Balanced — 12 steps")),
            QualityChoice(steps: 16, title: tr("Clearer — 16 steps")),
            QualityChoice(steps: 24, title: tr("Clearest — 24 steps")),
        ]
        if !choices.contains(where: { $0.steps == current }) { choices.append(QualityChoice(steps: current, title: tr("%1$@ steps", "\(current)"))) }
        return choices.sorted { $0.steps < $1.steps }
    }

    @ViewBuilder private var enrollmentControls: some View {
        switch clone.enrollment.state {
        case .idle:
            HStack {
                Button(clone.status == .ready ? tr("Replace with another recording…") : tr("Choose a recording…")) { chooseRecording() }
                if clone.status == .ready { Button(tr("Forget my voice"), role: .destructive) { confirmForget = true } }
            }
            Hint(tr("Choose a recording of your own voice: 8 to 12 seconds of clear speech with no other sounds (Voice Memos will do). In the next step you check the words said in it."))
            if let problem = clone.enrollment.problem { Text(verbatim: problem).font(.caption).foregroundStyle(.red) }
        case let .working(message):
            HStack { ProgressView().controlSize(.small); Text(verbatim: message).foregroundStyle(.secondary) }
        case let .review(draft):
            SampleReview(draft: draft, problem: clone.enrollment.problem) { words in
                Task { await clone.enrollment.save(words: words) }
            } cancel: {
                clone.enrollment.cancel()
            }
            .id(draft.recording)
        }
    }

    private func chooseRecording() {
        let panel = NSOpenPanel()
        panel.title = tr("Recording of your voice")
        panel.message = tr("Choose a recording of your own voice, 3 to 15 seconds long (8 to 12 is best).")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let env = env
        Task {
            await env.voice.speech.clone.enrollment.choose(url) { samples in
                if case let .success(.speech(output)) = await env.voice.recognizeForTest(samples) { return output.text }
                return nil
            }
        }
    }

    private func forgetVoice() {
        try? OmniVoiceEnrollment(locator: clone.locator).remove()
        clone.voiceChanged()
    }

    /// What to run in the Terminal to install the program of the voice (the project folder is known from the build).
    private static var installCloneCommand: String {
        let root = (Bundle.main.object(forInfoDictionaryKey: "KuzmemoSourceRoot") as? String) ?? tr("<project folder>")
        return "\"\(root)/scripts/install_omnivoice.sh\""
    }

    // MARK: Silero

    private var silero: SileroSpeechOutput { env.voice.speech.silero }

    /// The voices of the model when it is known, otherwise the five that Silero's Russian model ships with.
    private func sileroChoices(_ selected: String) -> [SileroVoice.Speaker] {
        var choices = SileroVoice.speakers
        if !silero.speakers.isEmpty {
            choices = silero.speakers.map { name in SileroVoice.speakers.first { $0.id == name } ?? .init(id: name, title: name) }
        }
        if !choices.contains(where: { $0.id == selected }) { choices.append(.init(id: selected, title: selected)) }
        return choices
    }

    @ViewBuilder private func sileroStatus(_ speech: SpeechSettings) -> some View {
        switch silero.status {
        case .unknown:
            Label(tr("Checking…"), systemImage: "hourglass").foregroundStyle(.secondary)
        case let .ready(found):
            Label(tr("Ready · %1$@", "\(found.source)") + (silero.loadMilliseconds.map { tr(" · model loaded in %1$@", "\(Self.seconds($0))") } ?? ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Hint(tr("Python: %1$@\nModel: %2$@", "\(found.python.path)", "\(found.model.path)"))
            Hint(tr("The neural network is loaded into memory when a recording starts and unloaded after 10 idle minutes. If it is not ready, the phrase is spoken by the system voice."))
        case let .unavailable(problem):
            Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Hint(tr("For now the system voice speaks. To enable Silero, run this in Terminal:"))
            Text(verbatim: Self.installCommand).font(.caption.monospaced()).textSelection(.enabled)
            Button(tr("Copy the command")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.installCommand, forType: .string)
            }
        case .missingHelper:
            Label(tr("This build has no Silero helper file."), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Hint(tr("Rebuild the app: scripts/run_app.sh."))
        }
        if let error = silero.lastError { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
        HStack {
            Button(tr("Choose Python…")) { choosePython() }
            if speech.sileroPython != nil {
                Button(tr("Find automatically")) { env.settings.speech.sileroPython = nil }
            }
            Spacer()
            Button(tr("Check")) {
                silero.refresh()
                Task { await silero.prepare() }
            }
            .disabled(!silero.isReady || silero.isLoading)
        }
    }

    private static func seconds(_ milliseconds: Int) -> String {
        String(format: tr("%.1f s"), locale: Localization.current.locale, Double(milliseconds) / 1000)
    }

    /// What to run in the Terminal to set Silero up (the project folder is known from the build).
    private static var installCommand: String {
        let root = (Bundle.main.object(forInfoDictionaryKey: "KuzmemoSourceRoot") as? String) ?? tr("<project folder>")
        return "\"\(root)/scripts/install_silero.sh\""
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.title = tr("Python with torch installed")
        panel.message = tr("Choose the python of an environment that has torch installed (for example venv/bin/python).")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        env.settings.speech.sileroPython = url.path
    }

    private func preview() {
        env.voice.previewSpeech(sample)
    }

    private static func installedVoices() -> [VoiceInfo] {
        SystemSpeechOutput.voices(for: Localization.current).map { voice in
            VoiceInfo(id: voice.identifier, name: voice.name, language: voice.language, quality: qualityTitle(voice.quality))
        }
    }

    static func qualityTitle(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: tr("premium")
        case .enhanced: tr("enhanced")
        default: tr("standard")
        }
    }
}

/// The step where the person checks the words said in the recording they chose.
private struct SampleReview: View {
    let draft: VoiceSampleEnrollment.Draft
    let problem: String?
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var words: String

    init(draft: VoiceSampleEnrollment.Draft, problem: String?, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.draft = draft
        self.problem = problem
        self.save = save
        self.cancel = cancel
        _words = State(initialValue: draft.words)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Recording: %1$@ s", String(format: "%.1f", locale: Localization.current.locale, draft.seconds))).font(.caption).foregroundStyle(.secondary)
            Text(tr("Check the words said in the recording. The likeness depends on them being exact: write numbers in words, as you say them."))
                .font(.caption).foregroundStyle(.secondary)
            if !draft.suggested {
                Text(tr("The words could not be recognized; write them yourself.")).font(.caption).foregroundStyle(.orange)
            }
            TextEditor(text: $words)
                .font(.body)
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
            if let problem { Text(verbatim: problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(tr("Save my voice")) { save(words) }
                    .buttonStyle(.borderedProminent)
                    .disabled(OmniVoiceEnrollment.clean(words).split(separator: " ").count < 2)
                Button(tr("Cancel"), action: cancel)
            }
        }
    }
}
