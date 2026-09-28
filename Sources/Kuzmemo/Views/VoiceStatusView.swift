import SwiftUI

/// The voice controls in the popover: a record button that works like a tap on the trigger key, and cards for
/// anything the person has to fix (permissions, missing speech model) with a button that leads there.
struct VoiceStatusView: View {
    let voice: VoiceController

    private var hint: String {
        var keys: [String] = []
        if voice.triggerRunning { keys.append("Fn") }
        if let chord = voice.chordDescription { keys.append(chord) }
        return keys.isEmpty ? "" : "или " + keys.joined(separator: " / ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: voice.toggleFromUI) {
                    Label(voice.isRecording ? "Закончить запись" : "Записать голосом",
                          systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(voice.isRecording ? .red : .accentColor)
                .controlSize(.regular)
                Text(verbatim: hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if voice.modelState == .loading {
                    ProgressView().controlSize(.small)
                        .help("Подготовка распознавания речи. Первый раз это занимает до пары минут.")
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
            "Чтобы работала клавиша Fn, разрешите Kuzmemo «Мониторинг ввода». Пока можно записывать кнопкой выше."
        case .triggerUnavailable:
            "Не удалось включить клавишу Fn. Разрешение выдано — перезапустите приложение."
        case .microphoneDenied:
            "Нет доступа к микрофону. Без него голосовые команды не работают."
        case .modelMissing:
            "Не найдена модель распознавания речи. Выполните scripts/install_models.sh."
        }
    }

    private var action: (title: String, run: () -> Void)? {
        switch problem {
        case .inputMonitoringMissing: ("Разрешить…", voice.requestInputMonitoring)
        case .microphoneDenied: ("Открыть настройки микрофона", { PermissionsModel.openSettings(.microphone) })
        case .triggerUnavailable, .modelMissing: nil
        }
    }
}
