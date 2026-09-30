import KeyboardShortcuts
import KuzmemoCore
import SwiftUI

/// How recording is started and stopped.
struct RecordingSettingsTab: View {
    let env: AppEnvironment
    @State private var devices = InputDevices.all()

    var body: some View {
        @Bindable var settings = env.settings
        let microphone = Binding<String>(
            get: { settings.recording.microphone ?? "" }, set: { settings.recording.microphone = $0.isEmpty ? nil : $0 }
        )
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
            Section(tr("Microphone")) {
                Picker(tr("Record from"), selection: microphone) {
                    Text(tr("Automatic")).tag("")
                    Text(tr("System input")).tag("system")
                    ForEach(devices) { device in Text(verbatim: Self.label(device)).tag(device.uid) }
                }
                Hint(microphoneHint(settings.recording.microphonePreference))
            }
            Section(tr("Sound")) {
                Toggle(tr("Turn the sound off while recording"), isOn: $settings.recording.muteWhileRecording)
                Hint(tr("Music and video in the headphones or speakers go quiet while you speak, so they do not get into the recording, and come back when it ends."))
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
        .onAppear { devices = InputDevices.all() }
    }

    /// What the choice means right now: which microphone a recording will use and, when it is not the one macOS selected, why.
    private func microphoneHint(_ preference: MicrophonePreference) -> String {
        let pick = MicrophoneChoice.pick(preference, among: devices)
        switch pick.reason {
        case let .bluetoothAvoided(name)?:
            return tr("“%1$@” is a Bluetooth headset. Its microphone needs a few seconds to switch the headset to call mode (the first words would be lost) and makes it sound worse, so “%2$@” is used instead. The headset keeps playing sound as usual.", name, pick.device?.name ?? "")
        case .pickedDeviceMissing?:
            return tr("The microphone you picked is not connected now, so the automatic choice is used.")
        case nil:
            guard let used = pick.device ?? devices.first(where: \.isSystemDefault) else { return tr("No audio input found.") }
            if used.transport == .bluetooth {
                return tr("A Bluetooth microphone needs a few seconds to start: hold the key a little longer, or choose the built-in microphone.")
            }
            return tr("Recording from “%1$@”.", used.name)
        }
    }

    private static func label(_ device: InputDevice) -> String {
        switch device.transport {
        case .builtIn: "\(device.name) · \(tr("built-in"))"
        case .bluetooth: "\(device.name) · \(tr("Bluetooth"))"
        case .usb: "\(device.name) · \(tr("USB"))"
        case .virtual: "\(device.name) · \(tr("virtual"))"
        case .other: device.name
        }
    }

    static func seconds(_ value: Double) -> String {
        String(format: tr("%.2f s"), locale: Localization.current.locale, value)
    }
}
