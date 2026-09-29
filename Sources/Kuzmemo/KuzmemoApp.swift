import AppKit
import KuzmemoCore
import SwiftUI

@main
struct KuzmemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        let _ = env.language // the scene's texts (menu titles, window titles) are built again when the language changes
        MenuBarExtra {
            PopoverView(env: env).id(env.language)
        } label: {
            MenuBarLabel(env: env)
        }
        .menuBarExtraStyle(.window)

        Window("Kuzmemo", id: "main") {
            MainWindowView(env: env).id(env.language)
        }
        .defaultSize(width: 1000, height: 660)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(tr("Settings…")) { env.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(tr("Calendar")) {
                Button(tr("Today")) { env.calendar.goToToday() }.keyboardShortcut("t", modifiers: .command)
                Button(tr("Previous month")) { env.calendar.moveMonth(by: -1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button(tr("Next month")) { env.calendar.moveMonth(by: 1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button(tr("New entry…")) { env.newItem(on: env.calendar.mode == .day ? env.calendar.selectedDate : nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Button(tr("Find")) { env.focusSearch() }.keyboardShortcut("f", modifiers: .command)
                Divider()
                Button(tr("Inbox")) { env.calendar.show(.inbox) }.keyboardShortcut("1", modifiers: .command)
                Button(tr("Repeating")) { env.calendar.show(.recurring) }.keyboardShortcut("2", modifiers: .command)
            }
        }

        // A Window scene rather than the Settings scene: it can be opened from anywhere, including a toast.
        Window(tr("Settings"), id: "settings") {
            SettingsView(env: env).id(env.language)
        }
        .windowResizability(.contentSize)
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

    /// The Silero helper and the program of the cloned voice are child processes: stop them (briefly) before the app goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppEnvironment.shared.voice.speech.silero.shutDown()
            AppEnvironment.shared.voice.speech.clone.shutDown()
            try? await AppEnvironment.shared.store.checkpoint() // the file alone holds everything after a clean quit
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor static func updateActivationPolicy() {
        let hasRealWindow = NSApp.windows.contains {
            $0.isVisible && AppWindow.isAppWindow($0)
        }
        NSApp.setActivationPolicy(hasRealWindow ? .regular : .accessory)
    }
}

struct MenuBarLabel: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon.onAppear {
            // The label is always alive, so it is where the window-opening action is picked up for use elsewhere.
            env.openWindowAction = { openWindow(id: "main") }
            env.openSettingsAction = { openWindow(id: "settings") }
        }
    }

    @ViewBuilder private var icon: some View {
        switch env.status {
        case .idle: Image(systemName: "calendar.badge.clock")
        case .recording: Image(systemName: "record.circle.fill")
        case .thinking: Image(systemName: "ellipsis.circle")
        case .error: Image(systemName: "exclamationmark.triangle")
        }
    }
}
