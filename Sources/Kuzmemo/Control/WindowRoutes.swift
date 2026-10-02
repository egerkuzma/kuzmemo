import AppKit
import Foundation
import KuzmemoCore

/// Control-channel access to the real main window (dev bundle only): open it without stealing focus, describe it,
/// close it, and capture what it really draws (including an attached sheet) from inside the process, which needs no
/// screen-recording permission.
enum WindowRoutes {
    /// The calendar window (`main`) or the settings window (`settings`).
    private static func window(_ name: String) -> NSWindow? {
        (name == "settings" ? AppWindow.settings : AppWindow.main).window
    }

    /// Every window of the app with its class, so the menu-bar popover and other system-made windows can be identified.
    static func list() -> HTTPResponse {
        let windows = NSApp.windows.map { window -> [String: Any] in
            [
                "class": window.className, "title": window.title, "visible": window.isVisible, "key": window.isKeyWindow,
                "level": window.level.rawValue, "frame": "\(Int(window.frame.width))x\(Int(window.frame.height))",
                "origin": "\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y))", "canBecomeKey": window.canBecomeKey,
                "content": window.contentView.map { "\(type(of: $0))" } ?? "",
            ]
        }
        return .json(["windows": windows])
    }

    static func describe(_ name: String = "main") -> HTTPResponse {
        guard let window = window(name), window.isVisible else {
            return .json(["open": false, "policy": "\(NSApp.activationPolicy().rawValue)"])
        }
        return .json([
            "open": true, "title": window.title, "visible": window.isVisible, "key": window.isKeyWindow, "active": NSApp.isActive,
            "frame": "\(Int(window.frame.width))x\(Int(window.frame.height))", "sheets": window.sheets.count,
            "sheetAttached": window.attachedSheet != nil, "policy": "\(NSApp.activationPolicy().rawValue)",
            "onScreen": window.occlusionState.contains(.visible),
        ])
    }

    /// Opens the window through the scene, deliberately without activating the app: an accessory app's window then
    /// stays behind whatever the person is working in.
    static func open(_ env: AppEnvironment, name: String = "main") async -> HTTPResponse {
        guard window(name)?.isVisible != true else { return describe(name) }
        guard let action = name == "settings" ? env.openSettingsAction : env.openWindowAction else {
            return .error("the window-opening action is not registered yet", status: 409)
        }
        action() // also brings back a window that was closed and is only being kept by the scene
        for _ in 0 ..< 40 where window(name)?.isVisible != true { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(300)) // let the first layout pass finish
        return describe(name)
    }

    static func close(_ name: String = "main") -> HTTPResponse {
        window(name)?.close()
        return describe(name)
    }

    /// Presses the button with this title in the window, or in the sheet attached to it (a confirmation dialog is an AppKit alert
    /// whose buttons are real buttons), without activating the app. For checks of what a dialog does when it is confirmed.
    static func press(name: String = "main", title: String, sheet: Bool) -> HTTPResponse {
        guard let window = window(name), window.isVisible else { return .error("the \(name) window is not open", status: 404) }
        guard let target = sheet ? window.attachedSheet : window else { return .error("no sheet is attached", status: 404) }
        func buttons(in view: NSView) -> [NSButton] {
            var found: [NSButton] = []
            if let button = view as? NSButton { found.append(button) }
            for child in view.subviews { found += buttons(in: child) }
            return found
        }
        let all = target.contentView.map(buttons(in:)) ?? []
        guard let button = all.first(where: { $0.title == title }) else {
            return .error("no button «\(title)»; there are \(all.map(\.title))", status: 404)
        }
        button.performClick(nil)
        return .json(["pressed": title])
    }

    /// Types a key into the window, or into the sheet attached to it, the way the person would, without activating the app:
    /// `return` is the default button (Save), `escape` is Cancel. For checks of what a sheet does when it is saved or dismissed,
    /// where a window that is deliberately kept behind everything cannot be clicked.
    static func key(name: String = "main", key: String, sheet: Bool) -> HTTPResponse {
        guard let window = window(name), window.isVisible else { return .error("the \(name) window is not open", status: 404) }
        guard let target = sheet ? window.attachedSheet : window else { return .error("no sheet is attached", status: 404) }
        let typed: (characters: String, code: UInt16)
        switch key {
        case "return": typed = ("\r", 36)
        case "escape": typed = ("\u{1b}", 53)
        default: return .error("key is \"return\" or \"escape\"", status: 400)
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target.windowNumber, context: nil, characters: typed.characters, charactersIgnoringModifiers: typed.characters,
            isARepeat: false, keyCode: typed.code
        ) else { return .error("cannot make the key event", status: 500) }
        return .json(["handled": target.performKeyEquivalent(with: event)])
    }

    /// `front` puts the window on top for a moment (without activating the app or taking keyboard focus) because
    /// SwiftUI does not redraw a window that is fully covered, so a covered window captures half empty.
    /// `chrome` draws the whole window as the person sees it, title bar and toolbar (or tab strip) included, by
    /// capturing the frame view around the content; without it only the content is drawn.
    /// `scheme` ("light" or "dark") draws the window in that appearance instead of the system's, for the length of the
    /// capture; `scale` is the pixel density of the picture (2 for a retina picture).
    static func capture(
        name: String = "main", sheet: Bool, front: Bool, chrome: Bool = false, scale: CGFloat, scheme: String? = nil
    ) async -> HTTPResponse {
        guard let window = window(name) else { return .error("the \(name) window is not open", status: 404) }
        let appearance: NSAppearance? = scheme == "dark" ? NSAppearance(named: .darkAqua) : scheme == "light" ? NSAppearance(named: .aqua) : nil
        if let appearance {
            window.appearance = appearance
            try? await Task.sleep(for: .milliseconds(500)) // let SwiftUI draw the window again in the new appearance
        }
        defer { if appearance != nil { window.appearance = nil } }
        if front {
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(800))
        }
        defer { if front { window.orderBack(nil) } }
        let target: NSWindow? = sheet ? window.attachedSheet : window
        guard let content = target?.contentView else { return .error(sheet ? "no sheet is attached" : "no content view", status: 404) }
        let view = (chrome ? content.superview : nil) ?? content
        view.layoutSubtreeIfNeeded()
        let pixels = max(1, scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * pixels), pixelsHigh: Int(view.bounds.height * pixels),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return .error("cannot capture", status: 500) }
        rep.size = view.bounds.size // more pixels than points: the picture is drawn at `scale` x
        // The window's own background is not part of its content view: without this, light text of a dark window
        // lands on a white bitmap and looks like an empty pane. Everything is drawn in the window's own appearance
        // (not the system's), or a light window would get a dark title bar.
        (target ?? window).effectiveAppearance.performAsCurrentDrawingAppearance {
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: rep.size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return .error("cannot encode", status: 500) }
        return .png(data)
    }
}
