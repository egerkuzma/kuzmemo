import KuzmemoCore
import KuzmemoSTT
import SwiftUI

/// Speech recognition: which model, which language, how long it stays in memory, and a check with the microphone.
struct RecognitionSettingsTab: View {
    let env: AppEnvironment
    @State private var tester = RecognitionTester()

    var body: some View {
        @Bindable var settings = env.settings
        let models = env.models
        Form {
            Section(tr("Speech recognition model")) {
                ForEach(ModelCatalog.variants) { variant in
                    ModelRow(
                        variant: variant, selected: settings.recognition.modelVariant == variant.id,
                        installed: models.installed.contains(variant.id), canCopy: models.copyable.contains(variant.id),
                        running: models.running[variant.id],
                        select: { settings.recognition.modelVariant = variant.id },
                        install: { models.install(variant) }
                    )
                }
                LabeledContent(tr("Current")) { Text(verbatim: env.voice.modelSummary).foregroundStyle(.secondary) }
                if let failure = models.failure { Text(verbatim: failure).font(.caption).foregroundStyle(.red) }
                Hint(tr("A model is downloaded from Hugging Face the first time (or copied, when another app already has it in Documents/huggingface). The first load of a new model on this Mac takes up to a couple of minutes (Core ML prepares it once), then about a second."))
            }
            Section(tr("Try it")) {
                HStack {
                    Button { Task { await tester.run(env: env) } } label: { Label(tr("Test the microphone and recognition"), systemImage: "mic.fill") }
                        .disabled(tester.isBusy)
                    Spacer()
                    Text(tr("5 seconds")).font(.caption).foregroundStyle(.secondary)
                }
                testOutput
            }
            Section(tr("Language")) {
                Picker(tr("Speech language"), selection: Binding(
                    get: { settings.recognition.language ?? "auto" },
                    set: { settings.recognition.language = $0 == "auto" ? nil : $0 }
                )) {
                    Text(tr("Russian")).tag("ru")
                    Text(tr("English")).tag("en")
                    Text(tr("Detect automatically")).tag("auto")
                }
                Hint(tr("A fixed language is more reliable: with automatic detection short phrases are sometimes mistaken for another language."))
            }
            Section(tr("Memory")) {
                Picker(tr("Unload the model after being idle"), selection: $settings.recognition.idleUnloadMinutes) {
                    Text(tr("5 minutes")).tag(5)
                    Text(tr("15 minutes")).tag(15)
                    Text(tr("30 minutes")).tag(30)
                    Text(tr("1 hour")).tag(60)
                    Text(tr("Never")).tag(0)
                }
                Hint(tr("A loaded model takes about 1.5 GB of memory. After it is unloaded the next recording starts as usual: the model loads while you speak."))
            }
        }
        .formStyle(.grouped)
        .task {
            env.models.refresh()
            env.models.probeSources()
        }
    }

    @ViewBuilder private var testOutput: some View {
        switch tester.state {
        case .idle:
            Hint(tr("Say something after pressing: it shows what the model heard and how long it took."))
        case let .recording(elapsed, total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: elapsed, total: total)
                ProgressView(value: Double(min(1, tester.level * 10)), total: 1).tint(.red)
                Hint(tr("Speak…"))
            }
        case .recognizing:
            HStack { ProgressView().controlSize(.small); Text(tr("Recognizing…")) }
        case let .done(text, audioSeconds, milliseconds):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: Wording.quoted(text)).textSelection(.enabled)
                Hint(tr("Recorded %1$@, recognized in %2$@.", "\(Self.seconds(audioSeconds))", "\(Self.seconds(Double(milliseconds) / 1000))"))
            }
        case let .nothingHeard(reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(tr("No speech heard"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Hint(tr("Check which microphone is selected in System Settings → Sound → Input. (%1$@)", "\(reason)"))
            }
        case let .failed(message):
            Text(verbatim: message).font(.callout).foregroundStyle(.red)
        }
    }

    private static func seconds(_ value: Double) -> String {
        String(format: tr("%.1f s"), locale: Localization.current.locale, value)
    }
}

private struct ModelRow: View {
    let variant: ModelVariant
    let selected: Bool
    let installed: Bool
    let canCopy: Bool
    /// Set while the model is being downloaded or copied.
    let running: ModelInstaller.Progress?
    let select: () -> Void
    let install: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(installed ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!installed)
            .accessibilityLabel(selected ? tr("Selected") : tr("Select"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(variant.title) · \(Self.size(variant.sizeMB))").fontWeight(selected ? .semibold : .regular)
                Text(verbatim: variant.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let running {
                if let fraction = running.fraction, !running.copying {
                    ProgressView(value: fraction).frame(width: 90)
                    Text(verbatim: "\(Int(fraction * 100)) %").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text(running.copying ? tr("Copying…") : tr("Downloading…")).font(.caption).foregroundStyle(.secondary)
                }
            } else if installed {
                Text(selected ? tr("In use") : tr("Installed")).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(canCopy ? tr("Install") : tr("Download"), action: install)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if installed { select() } }
    }

    private static func size(_ megabytes: Int) -> String {
        megabytes >= 1000 ? String(format: tr("%.1f GB"), locale: Localization.current.locale, Double(megabytes) / 1000) : tr("%1$lld MB", numbers: megabytes)
    }
}
