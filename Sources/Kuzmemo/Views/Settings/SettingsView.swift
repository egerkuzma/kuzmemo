import KuzmemoCore
import SwiftUI

/// The settings window: one tab per area.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, recording, recognition, speech, glossary
        var id: String { rawValue }
    }

    @Bindable var env: AppEnvironment

    var body: some View {
        TabView(selection: $env.settingsTab) {
            GeneralSettingsTab(env: env)
                .tabItem { Label("Общие", systemImage: "gearshape") }.tag(Tab.general)
            RecordingSettingsTab(env: env)
                .tabItem { Label("Запись", systemImage: "mic") }.tag(Tab.recording)
            RecognitionSettingsTab(env: env)
                .tabItem { Label("Распознавание", systemImage: "waveform") }.tag(Tab.recognition)
            SpeechSettingsTab(env: env)
                .tabItem { Label("Озвучка", systemImage: "speaker.wave.2") }.tag(Tab.speech)
            GlossarySettingsTab(env: env)
                .tabItem { Label("Глоссарий", systemImage: "character.book.closed") }.tag(Tab.glossary)
        }
        .frame(width: 700, height: 600)
        .environment(\.locale, DateBridge.russian)
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
