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
        .defaultSize(width: 1000, height: 660)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { env.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Календарь") {
                Button("Сегодня") { env.calendar.goToToday() }.keyboardShortcut("t", modifiers: .command)
                Button("Предыдущий месяц") { env.calendar.moveMonth(by: -1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Следующий месяц") { env.calendar.moveMonth(by: 1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Новая запись…") { env.newItem(on: env.calendar.mode == .day ? env.calendar.selectedDate : nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Найти") { env.focusSearch() }.keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Входящие") { env.calendar.show(.inbox) }.keyboardShortcut("1", modifiers: .command)
                Button("Повторяющиеся") { env.calendar.show(.recurring) }.keyboardShortcut("2", modifiers: .command)
            }
        }

        // A Window scene rather than the Settings scene: it can be opened from anywhere, including a toast.
        Window("Настройки", id: "settings") {
            SettingsView(env: env)
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

    @MainActor static func updateActivationPolicy() {
        let hasRealWindow = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && ($0.title == "Kuzmemo" || $0.title == "Настройки")
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
