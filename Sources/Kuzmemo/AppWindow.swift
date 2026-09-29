import AppKit
import KuzmemoCore

/// The app's two real windows, recognized by their titles (SwiftUI does not put the scene id on the `NSWindow`).
/// The settings title is translated, so a settings window counts under the title of every language.
enum AppWindow {
    case main, settings

    var titles: Set<String> {
        switch self {
        case .main: ["Kuzmemo"]
        case .settings: Set(AppLanguage.allCases.map { Localization.text("Settings", in: $0) })
        }
    }

    func matches(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && titles.contains(window.title)
    }

    /// The window of this kind, open or not (a closed window is kept by the scene).
    var window: NSWindow? { NSApp.windows.first(where: matches) }

    static func isAppWindow(_ window: NSWindow) -> Bool { AppWindow.main.matches(window) || AppWindow.settings.matches(window) }
}
