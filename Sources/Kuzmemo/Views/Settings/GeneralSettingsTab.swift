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
        @Bindable var env = env
        Form {
            Section(tr("Language")) {
                Picker(tr("Interface language"), selection: $env.languagePreference) {
                    Text(tr("Same as the system")).tag(LanguagePreference.system)
                    Text(AppLanguage.english.nativeName).tag(LanguagePreference.english)
                    Text(AppLanguage.russian.nativeName).tag(LanguagePreference.russian)
                }
                Hint(tr("Menus, messages, notifications and spoken answers follow this language. It does not change the language you speak: that is chosen in the Recognition tab."))
            }
            Section(tr("Launch")) {
                Toggle(tr("Open Kuzmemo at login"), isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                .disabled(AppPaths.isAutomation)
                if AppPaths.isAutomation {
                    Hint(tr("Launch at login is off in this build (it is used for automated checks)."))
                } else if loginStatus == .requiresApproval {
                    Hint(tr("Allow it in System Settings → General → Login Items."))
                    Button(tr("Open Login Items")) { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Hint(tr("The app lives in the menu bar and stays out of the Dock while its window is closed."))
                }
                if let loginError { Text(verbatim: loginError).font(.caption).foregroundStyle(.red) }
            }
            Section(tr("Permissions")) {
                PermissionRow(
                    title: tr("Microphone"), state: microphoneState,
                    action: microphoneAction
                )
                PermissionRow(
                    title: tr("Input Monitoring (the Fn key)"),
                    state: AppPaths.isAutomation ? .notNeeded : (permissions.inputMonitoring ? .granted : .missing),
                    action: (tr("Allow…"), { env.voice.requestInputMonitoring() })
                )
                Hint(tr("Without Input Monitoring the Fn key does not work, but the record button and the fallback shortcut still do."))
                PermissionRow(title: tr("Notifications"), state: env.notifications.permissionState, action: env.notifications.permissionAction)
                Hint(tr("Reminders arrive as system notifications. How they look and sound is set in the Notifications tab."))
            }
            Section(tr("About")) {
                LabeledContent(tr("Version")) { Text(verbatim: env.version).foregroundStyle(.secondary) }
                if let commit = Bundle.main.object(forInfoDictionaryKey: "KuzmemoGitCommit") as? String {
                    LabeledContent(tr("Build")) { Text(verbatim: commit).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            loginStatus = SMAppService.mainApp.status
        }
        .task { await env.notifications.refreshAccess() }
    }

    // MARK: Launch at login

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = tr("Could not change launch at login: %1$@", "\(error.localizedDescription)")
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
            ? (tr("Allow…"), { Task { await permissions.requestMicrophone() } })
            : (tr("Open Settings"), { PermissionsModel.openSettings(.microphone) })
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
                case .granted: Label(tr("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .undecided:
                    Label(tr("Not requested"), systemImage: "questionmark.circle").foregroundStyle(.orange)
                    Button(action.0, action: action.1)
                case .missing:
                    Label(tr("No access"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button(action.0, action: action.1)
                case .notNeeded: Text(tr("not needed in this build")).foregroundStyle(.secondary)
                }
            }
        }
    }
}
