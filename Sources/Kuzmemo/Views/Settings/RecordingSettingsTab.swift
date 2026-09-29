import KeyboardShortcuts
import KuzmemoCore
import SwiftUI

/// How recording is started and stopped.
struct RecordingSettingsTab: View {
    let env: AppEnvironment

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section(tr("Keys")) {
                LabeledContent(tr("Fn key")) {
                    if env.voice.triggerRunning {
                        Label(tr("Working"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if AppPaths.isAutomation {
                        Text(tr("off in this build")).foregroundStyle(.secondary)
                    } else {
                        Button(tr("Allow “Input Monitoring”…")) { env.voice.requestInputMonitoring() }
                    }
                }
                Hint(tr("Tap and release — recording continues on its own while you speak and stops after a pause. Hold — recording lasts while the key is pressed. If Fn opens the emoji picker or dictation, set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”."))
                KeyboardShortcuts.Recorder(tr("Fallback shortcut"), name: .recordVoice)
                Hint(tr("Works without extra permissions and behaves like Fn."))
            }
            Section(tr("Behavior")) {
                LabeledContent(tr("Count as a hold after")) {
                    HStack {
                        Slider(value: $settings.recording.holdThreshold, in: 0.15 ... 0.8, step: 0.05).frame(width: 200)
                        Text(verbatim: Self.seconds(settings.recording.holdThreshold)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent(tr("Stop after a pause of")) {
                    HStack {
                        Slider(value: $settings.recording.handsFreeSilence, in: 1 ... 6, step: 0.5).frame(width: 200)
                        Text(verbatim: Self.seconds(settings.recording.handsFreeSilence)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                Stepper(value: $settings.recording.maxSeconds, in: 30 ... 300, step: 30) {
                    Text(verbatim: tr("Longest recording: %1$lld s", numbers: settings.recording.maxSeconds))
                }
                Hint(tr("A press shorter than that is a tap: recording continues on its own. A pause only counts after you have said something."))
            }
        }
        .formStyle(.grouped)
    }

    static func seconds(_ value: Double) -> String {
        String(format: tr("%.2f s"), locale: Localization.current.locale, value)
    }
}
