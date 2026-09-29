import KuzmemoCore
import SwiftUI

/// The voice controls in the popover: a record button that works like a tap on the trigger key, and cards for
/// anything the person has to fix (permissions, missing speech model) with a button that leads there.
struct VoiceStatusView: View {
    let voice: VoiceController

    private var hint: String {
        var keys: [String] = []
        if voice.triggerRunning { keys.append("Fn") }
        if let chord = voice.chordDescription { keys.append(chord) }
        return keys.isEmpty ? "" : tr("or %1$@", keys.joined(separator: " / "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: voice.toggleFromUI) {
                    Label(voice.isRecording ? tr("Finish recording") : tr("Record by voice"),
                          systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(voice.isRecording ? .red : .accentColor)
                .controlSize(.regular)
                Text(verbatim: hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if voice.modelState == .loading {
                    ProgressView().controlSize(.small)
                        .help(tr("Preparing speech recognition. The first time this takes up to a couple of minutes."))
                }
            }
            if let problem = voice.problem { ProblemCard(problem: problem, voice: voice) }
        }
    }
}

private struct ProblemCard: View {
    let problem: VoiceController.Problem
    let voice: VoiceController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: message).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let action { Button(action.title, action: action.run).buttonStyle(.link).font(.callout) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var message: String {
        switch problem {
        case .inputMonitoringMissing:
            tr("To make the Fn key work, allow Kuzmemo “Input Monitoring”. Meanwhile you can record with the button above.")
        case .triggerUnavailable:
            tr("Could not enable the Fn key. The permission is granted — restart the app.")
        case .microphoneDenied:
            tr("No microphone access. Voice commands do not work without it.")
        case .modelMissing:
            tr("The speech recognition model was not found. Download it in Settings → Recognition.")
        }
    }

    private var action: (title: String, run: () -> Void)? {
        switch problem {
        case .inputMonitoringMissing: (tr("Allow…"), voice.requestInputMonitoring)
        case .microphoneDenied: (tr("Open microphone settings"), { PermissionsModel.openSettings(.microphone) })
        case .triggerUnavailable, .modelMissing: nil
        }
    }
}
