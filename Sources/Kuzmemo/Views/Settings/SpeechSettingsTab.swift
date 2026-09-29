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
            Section("Голос") {
                Picker("Голос", selection: $settings.speech.voiceIdentifier) {
                    Text("Лучший из установленных").tag(String?.none)
                    ForEach(voices) { voice in
                        Text(verbatim: "\(voice.name) — \(voice.quality)").tag(Optional(voice.id))
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
                    Spacer()
                    if env.voice.speech.muted { Hint("В этой сборке звук выключен (для автоматических проверок).") }
                }
                if !voices.isEmpty, voices.allSatisfy({ $0.quality == "стандартный" }) {
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
        .task { voices = Self.installedVoices() }
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
