import KeyboardShortcuts
import KuzmemoCore
import SwiftUI

/// How recording is started and stopped.
struct RecordingSettingsTab: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("Клавиши") {
                LabeledContent("Клавиша Fn") {
                    if env.voice.triggerRunning {
                        Label("Работает", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if AppPaths.isAutomation {
                        Text("выключена в этой сборке").foregroundStyle(.secondary)
                    } else {
                        Button("Разрешить «Мониторинг ввода»…") { env.voice.requestInputMonitoring() }
                    }
                }
                Hint("Нажмите и отпустите — запись идёт сама, пока вы говорите, и остановится после паузы. Удерживайте — запись идёт, пока клавиша нажата. Если Fn открывает эмодзи или диктовку, поставьте в Системные настройки → Клавиатура «Нажатие клавиши 🌐» в «Ничего не делать».")
                KeyboardShortcuts.Recorder("Запасное сочетание", name: .recordVoice)
                Hint("Работает без дополнительных разрешений, действует так же, как Fn.")
            }
            Section("Поведение") {
                LabeledContent("Считать удержанием после") {
                    HStack {
                        Slider(value: $settings.recording.holdThreshold, in: 0.15 ... 0.8, step: 0.05).frame(width: 200)
                        Text(verbatim: Self.seconds(settings.recording.holdThreshold)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Остановить после паузы") {
                    HStack {
                        Slider(value: $settings.recording.handsFreeSilence, in: 1 ... 6, step: 0.5).frame(width: 200)
                        Text(verbatim: Self.seconds(settings.recording.handsFreeSilence)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                Stepper(value: $settings.recording.maxSeconds, in: 30 ... 300, step: 30) {
                    Text(verbatim: "Самая длинная запись: \(settings.recording.maxSeconds) с")
                }
                Hint("Короче удержания — это касание: запись продолжится сама. Пауза считается только после того, как вы что-то сказали.")
            }
        }
        .formStyle(.grouped)
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.2f с", value).replacingOccurrences(of: ".", with: ",")
    }
}
