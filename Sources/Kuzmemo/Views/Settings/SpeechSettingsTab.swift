import AVFoundation
import KuzmemoCore
import SwiftUI

/// Voice output: which voice, how fast, what is read aloud, and a way to hear it.
struct SpeechSettingsTab: View {
    let env: AppEnvironment
    @State private var voices = SpeechSettingsTab.installedVoices()
    @State private var sample = "Здравствуйте! Сегодня у вас три дела: в десять часов планёрка, в одиннадцать созвон с Фигма и в шесть вечера проверить статистику."

    struct VoiceInfo: Identifiable, Equatable {
        var id: String
        var name: String
        var language: String
        var quality: String
    }

    private var settings: AppSettings { env.settings }

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("Движок озвучки") {
                Picker("Движок", selection: $settings.speech.engine) {
                    Text("Системный голос macOS").tag(SpeechEngine.system)
                    Text("Silero — нейросетевой голос").tag(SpeechEngine.silero)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if settings.speech.engine == .silero {
                    sileroStatus(settings.speech)
                } else {
                    Hint("Голос, встроенный в macOS: быстрый, ничего не нужно устанавливать. Нейросетевой Silero звучит естественнее (как в проекте another project), но требует Python с torch.")
                }
            }
            Section("Голос") {
                if settings.speech.engine == .silero {
                    Picker("Голос Silero", selection: $settings.speech.sileroSpeaker) {
                        ForEach(sileroChoices(settings.speech.sileroSpeaker), id: \.id) { Text(verbatim: $0.title).tag($0.id) }
                    }
                } else {
                    Picker("Голос", selection: $settings.speech.voiceIdentifier) {
                        Text("Лучший из установленных").tag(String?.none)
                        ForEach(voices) { voice in
                            Text(verbatim: "\(voice.name) — \(voice.quality)").tag(Optional(voice.id))
                        }
                    }
                }
                LabeledContent("Скорость") {
                    HStack {
                        Text("медленнее").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.speech.rate, in: 0.3 ... 0.6, step: 0.01) { editing in
                            if !editing { preview() }
                        }
                        .frame(width: 200)
                        Text("быстрее").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Фраза для проверки").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $sample, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button { preview() } label: { Label("Прослушать", systemImage: "play.fill") }
                    Button { env.voice.speech.stop() } label: { Label("Стоп", systemImage: "stop.fill") }
                    if silero.isBusy || silero.isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    if env.voice.speech.muted { Hint("В этой сборке звук выключен (для автоматических проверок).") }
                }
                if let reason = env.voice.speech.lastFallback, settings.speech.engine == .silero {
                    Hint("Последняя фраза прозвучала системным голосом: \(reason)")
                }
                if settings.speech.engine == .system, !voices.isEmpty, voices.allSatisfy({ $0.quality == "стандартный" }) {
                    Hint("Установлены только стандартные голоса. Улучшенные и премиум-голоса звучат заметно естественнее: Системные настройки → Универсальный доступ → Устный контент → Системный голос → «Управление голосами…».")
                    Button("Открыть настройки голосов") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Section("Что озвучивать") {
                Toggle("Ответы на вопросы и уточнения", isOn: $settings.speech.speakAnswers)
                Toggle("Подтверждения: «Записал: событие на завтра…»", isOn: $settings.speech.speakConfirmations)
                Toggle("Короткий звук, когда запись сохранена", isOn: $settings.speech.confirmationSound)
            }
        }
        .formStyle(.grouped)
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
            Label("Проверяю…", systemImage: "hourglass").foregroundStyle(.secondary)
        case let .ready(found):
            Label("Готов · \(found.source)" + (silero.loadMilliseconds.map { " · модель загружена за \(Self.seconds($0))" } ?? ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Hint("Python: \(found.python.path)\nМодель: \(found.model.path)")
            Hint("Нейросеть загружается в память при записи и выгружается через 10 минут простоя. Если она не готова, фраза прозвучит системным голосом.")
        case let .unavailable(problem):
            Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Hint("Пока фразы озвучивает системный голос. Чтобы включить Silero, выполните в Терминале:")
            Text(verbatim: Self.installCommand).font(.caption.monospaced()).textSelection(.enabled)
            Button("Скопировать команду") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.installCommand, forType: .string)
            }
        case .missingHelper:
            Label("В этой сборке нет вспомогательного файла Silero.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Hint("Соберите приложение заново: scripts/run_app.sh.")
        }
        if let error = silero.lastError { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
        HStack {
            Button("Указать Python…") { choosePython() }
            if speech.sileroPython != nil {
                Button("Искать самому") { env.settings.speech.sileroPython = nil }
            }
            Spacer()
            Button("Проверить") {
                silero.refresh()
                Task { await silero.prepare() }
            }
            .disabled(!silero.isReady || silero.isLoading)
        }
    }

    private static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.1f с", Double(milliseconds) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    /// What to run in the Terminal to set Silero up (the project folder is known from the build).
    private static var installCommand: String {
        let root = (Bundle.main.object(forInfoDictionaryKey: "KuzmemoSourceRoot") as? String) ?? "<папка проекта>"
        return "\"\(root)/scripts/install_silero.sh\""
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.title = "Python с установленным torch"
        panel.message = "Выберите python из окружения (например, venv/bin/python), где стоит torch."
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
        SystemSpeechOutput.russianVoices().map { voice in
            VoiceInfo(id: voice.identifier, name: voice.name, language: voice.language, quality: qualityTitle(voice.quality))
        }
    }

    static func qualityTitle(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "премиум"
        case .enhanced: "улучшенный"
        default: "стандартный"
        }
    }
}
