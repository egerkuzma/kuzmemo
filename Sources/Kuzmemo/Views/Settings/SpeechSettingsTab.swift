import AVFoundation
import KuzmemoCore
import SwiftUI

/// Voice output: which voice, how fast, what is read aloud, and a way to hear it.
struct SpeechSettingsTab: View {
    let env: AppEnvironment
    @State private var voices = SpeechSettingsTab.installedVoices()
    @State private var sample = tr("Hello! You have three things today: stand-up at ten, a team sync at eleven and a report to check at six in the evening.")

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
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if settings.speech.engine == .silero {
                        sileroStatus(settings.speech)
                    } else {
                        Hint(tr("The voice built into macOS: fast, nothing to install. The neural Silero voice sounds more natural but needs Python with torch and a model file (installed with one command). Silero speaks Russian only."))
                    }
                } else {
                    Label(tr("macOS system voice"), systemImage: "speaker.wave.2")
                    Hint(tr("The neural Silero voice speaks Russian only: switch the interface language to Russian to use it."))
                }
            }
            Section(tr("Voice")) {
                if settings.speech.engine == .silero, env.language == .russian {
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Sample phrase")).font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $sample, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button { preview() } label: { Label(tr("Listen"), systemImage: "play.fill") }
                    Button { env.voice.speech.stop() } label: { Label(tr("Stop"), systemImage: "stop.fill") }
                    if silero.isBusy || silero.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    if env.voice.speech.muted { Hint(tr("Sound is off in this build (it is used for automated checks).")) }
                }
                if let reason = env.voice.speech.lastFallback, settings.speech.engine == .silero {
                    Hint(tr("The last phrase was spoken by the system voice: %1$@", "\(reason)"))
                }
                if !(settings.speech.engine == .silero && env.language == .russian), !voices.isEmpty, voices.allSatisfy({ $0.quality == tr("standard") }) {
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
        }
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
