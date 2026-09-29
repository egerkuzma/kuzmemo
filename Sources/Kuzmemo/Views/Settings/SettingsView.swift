import KuzmemoCore
import SwiftUI

/// The settings window: one tab per area.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, recording, recognition, speech, notifications, glossary
        var id: String { rawValue }
    }

    @Bindable var env: AppEnvironment

    var body: some View {
        TabView(selection: $env.settingsTab) {
            Self.page(.general, env: env)
                .tabItem { Label("Общие", systemImage: "gearshape") }.tag(Tab.general)
            Self.page(.recording, env: env)
                .tabItem { Label("Запись", systemImage: "mic") }.tag(Tab.recording)
            Self.page(.recognition, env: env)
                .tabItem { Label("Распознавание", systemImage: "waveform") }.tag(Tab.recognition)
            Self.page(.speech, env: env)
                .tabItem { Label("Озвучка", systemImage: "speaker.wave.2") }.tag(Tab.speech)
            Self.page(.notifications, env: env)
                .tabItem { Label("Уведомления", systemImage: "bell") }.tag(Tab.notifications)
            Self.page(.glossary, env: env)
                .tabItem { Label("Глоссарий", systemImage: "character.book.closed") }.tag(Tab.glossary)
        }
        .frame(width: 700, height: 600)
        .environment(\.locale, DateBridge.russian)
    }

    /// The content of one tab (also rendered on its own, taller than the window, by the control channel).
    @ViewBuilder static func page(_ tab: Tab, env: AppEnvironment) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(env: env)
        case .recording: RecordingSettingsTab(env: env)
        case .recognition: RecognitionSettingsTab(env: env)
        case .speech: SpeechSettingsTab(env: env)
        case .notifications: NotificationsSettingsTab(env: env)
        case .glossary: GlossarySettingsTab(env: env)
        }
    }
}

/// A caption under a setting.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
