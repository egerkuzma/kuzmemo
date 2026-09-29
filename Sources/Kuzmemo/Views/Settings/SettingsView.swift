import KuzmemoCore
import SwiftUI

/// The settings window: a row of tabs across the top and the page of the chosen one below it. The tabs are drawn here,
/// not by `TabView`: in a window the system's tab view puts its tabs into the title bar, and six of them collapse into a
/// "»" menu that nobody finds.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, recording, recognition, speech, notifications, glossary
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "Общие"
            case .recording: "Запись"
            case .recognition: "Распознавание"
            case .speech: "Озвучка"
            case .notifications: "Уведомления"
            case .glossary: "Глоссарий"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .recognition: "waveform"
            case .speech: "speaker.wave.2"
            case .notifications: "bell"
            case .glossary: "character.book.closed"
            }
        }
    }

    static let size = CGSize(width: 760, height: 660)

    @Bindable var env: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $env.settingsTab)
            Divider()
            Self.page(env.settingsTab, env: env)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
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

/// Icon-over-label tabs of equal width, like the toolbar of a classic Preferences window.
struct SettingsTabBar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsView.Tab.allCases) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 19)).frame(height: 24)
                        Text(verbatim: tab.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(selection == tab ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
