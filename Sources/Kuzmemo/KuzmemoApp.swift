import AppKit
import KuzmemoCore
import SwiftUI

@main
struct KuzmemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(env: env)
        } label: {
            MenuBarLabel(env: env)
        }
        .menuBarExtraStyle(.window)

        Window("Kuzmemo", id: "main") {
            MainWindowView(env: env)
        }
        .defaultSize(width: 900, height: 620)
    }
}

/// The app has no Dock icon while only the menu bar item is in use; it becomes a regular app while a real
/// window is open and returns to the background when the last one closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { AppDelegate.updateActivationPolicy() }
        }
    }

    @MainActor static func updateActivationPolicy() {
        let hasRealWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.title == "Kuzmemo" }
        NSApp.setActivationPolicy(hasRealWindow ? .regular : .accessory)
    }
}

struct MenuBarLabel: View {
    let env: AppEnvironment

    var body: some View {
        switch env.status {
        case .idle: Image(systemName: "calendar.badge.clock")
        case .recording: Image(systemName: "record.circle.fill")
        case .thinking: Image(systemName: "ellipsis.circle")
        case .error: Image(systemName: "exclamationmark.triangle")
        }
    }
}
