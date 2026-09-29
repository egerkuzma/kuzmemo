import AppKit
import Foundation

/// Control-channel access to the real main window (dev bundle only): open it without stealing focus, describe it,
/// close it, and capture what it really draws (including an attached sheet) from inside the process, which needs no
/// screen-recording permission.
enum WindowRoutes {
    /// The calendar window (`main`) or the settings window (`settings`).
    private static func window(_ name: String) -> NSWindow? {
        let title = name == "settings" ? "Настройки" : "Kuzmemo"
        return NSApp.windows.first { $0.title == title && $0.styleMask.contains(.titled) }
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
            "open": true, "visible": window.isVisible, "key": window.isKeyWindow, "active": NSApp.isActive,
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

    /// `front` puts the window on top for a moment (without activating the app or taking keyboard focus) because
    /// SwiftUI does not redraw a window that is fully covered, so a covered window captures half empty.
    /// `chrome` draws the whole window as the person sees it, title bar and toolbar (or tab strip) included, by
    /// capturing the frame view around the content; without it only the content is drawn.
    static func capture(name: String = "main", sheet: Bool, front: Bool, chrome: Bool = false, scale: CGFloat) async -> HTTPResponse {
        guard let window = window(name) else { return .error("the \(name) window is not open", status: 404) }
        if front {
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(800))
        }
        defer { if front { window.orderBack(nil) } }
        let target: NSWindow? = sheet ? window.attachedSheet : window
        guard let content = target?.contentView else { return .error(sheet ? "no sheet is attached" : "no content view", status: 404) }
        let view = (chrome ? content.superview : nil) ?? content
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return .error("cannot capture", status: 500) }
        // The window's own background is not part of its content view: without this, light text of a dark window
        // lands on a white bitmap and looks like an empty pane.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            (target ?? window).effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: rep.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return .error("cannot encode", status: 500) }
        _ = scale
        return .png(data)
    }
}
