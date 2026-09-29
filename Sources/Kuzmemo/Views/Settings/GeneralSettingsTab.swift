import AVFoundation
import AppKit
import KuzmemoCore
import ServiceManagement
import SwiftUI

/// Start at login, what the app is allowed to do, and where its data lives.
struct GeneralSettingsTab: View {
    let env: AppEnvironment
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    private var permissions: PermissionsModel { env.voice.permissions }

    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать Kuzmemo при входе в систему", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                .disabled(AppPaths.isAutomation)
                if AppPaths.isAutomation {
                    Hint("В этой сборке (для автоматических проверок) автозапуск выключен.")
                } else if loginStatus == .requiresApproval {
                    Hint("Разрешите запуск в Системных настройках → Основные → Объекты входа.")
                    Button("Открыть объекты входа") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Hint("Приложение живёт в строке меню и не занимает Dock, пока окно закрыто.")
                }
                if let loginError { Text(verbatim: loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Разрешения") {
                PermissionRow(
                    title: "Микрофон", state: microphoneState,
                    action: microphoneAction
                )
                PermissionRow(
                    title: "Мониторинг ввода (клавиша Fn)",
                    state: AppPaths.isAutomation ? .notNeeded : (permissions.inputMonitoring ? .granted : .missing),
                    action: ("Разрешить…", { env.voice.requestInputMonitoring() })
                )
                Hint("Без «Мониторинга ввода» клавиша Fn не работает, но кнопка записи и запасное сочетание остаются.")
            }
            Section("Данные") {
                LabeledContent("База данных") {
                    HStack {
                        Text(verbatim: env.paths.database.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([env.paths.database]) }
                    }
                }
                Hint("Записи, глоссарий и настройки хранятся только на этом Mac. Звук удаляется сразу после расшифровки; в Anthropic уходит только текст фразы.")
            }
            Section("О программе") {
                LabeledContent("Версия") { Text(verbatim: env.version).foregroundStyle(.secondary) }
                if let commit = Bundle.main.object(forInfoDictionaryKey: "KuzmemoGitCommit") as? String {
                    LabeledContent("Сборка") { Text(verbatim: commit).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            loginStatus = SMAppService.mainApp.status
        }
    }

    // MARK: Launch at login

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Не получилось изменить автозапуск: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    // MARK: Microphone

    private var microphoneState: PermissionRow.State {
        switch permissions.microphone {
        case .authorized: .granted
        case .notDetermined: .undecided
        default: .missing
        }
    }

    private var microphoneAction: (String, () -> Void) {
        permissions.microphone == .notDetermined
            ? ("Разрешить…", { Task { await permissions.requestMicrophone() } })
            : ("Открыть настройки", { PermissionsModel.openSettings(.microphone) })
    }
}

struct PermissionRow: View {
    enum State { case granted, undecided, missing, notNeeded }

    let title: String
    let state: State
    let action: (String, () -> Void)

    var body: some View {
        LabeledContent(title) {
            HStack {
                switch state {
                case .granted: Label("Разрешено", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .undecided:
                    Label("Не запрашивалось", systemImage: "questionmark.circle").foregroundStyle(.orange)
                    Button(action.0, action: action.1)
                case .missing:
                    Label("Нет доступа", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button(action.0, action: action.1)
                case .notNeeded: Text("не нужно в этой сборке").foregroundStyle(.secondary)
                }
            }
        }
    }
}
