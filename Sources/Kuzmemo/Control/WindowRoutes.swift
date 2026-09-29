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

    /// The visible text and controls of the real window as assistive technology sees them: a way to check what is
    /// really on screen (and that everything has a Russian accessibility label) without drawing anything.
    static func texts(sheet: Bool) -> HTTPResponse {
        guard let window = window("main") else { return .error("the main window is not open", status: 404) }
        guard let root = (sheet ? window.attachedSheet : window) else { return .error("no sheet is attached", status: 404) }
        var found: [[String: String]] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 40, let object = element as? NSObject else { return }
            let role = (object as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue ?? ""
            let label = (object as? NSAccessibilityProtocol)?.accessibilityLabel() ?? ""
            var value = ""
            if let raw = (object as? NSAccessibilityProtocol)?.accessibilityValue() { value = "\(raw)" }
            let title = (object as? NSAccessibilityProtocol)?.accessibilityTitle() ?? ""
            if !(label.isEmpty && value.isEmpty && title.isEmpty) {
                found.append(["role": role, "label": label, "value": value, "title": title])
            }
            for child in (object as? NSAccessibilityProtocol)?.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root.contentView as Any, depth: 0)
        return .json(["count": found.count, "elements": found])
    }

    static func close(_ name: String = "main") -> HTTPResponse {
        window(name)?.close()
        return describe(name)
    }

    /// `front` puts the window on top for a moment (without activating the app or taking keyboard focus) because
    /// SwiftUI does not redraw a window that is fully covered, so a covered window captures half empty.
    static func capture(name: String = "main", sheet: Bool, front: Bool, scale: CGFloat) async -> HTTPResponse {
        guard let window = window(name) else { return .error("the \(name) window is not open", status: 404) }
        if front {
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(800))
        }
        defer { if front { window.orderBack(nil) } }
        let target: NSWindow? = sheet ? window.attachedSheet : window
        guard let view = target?.contentView else { return .error(sheet ? "no sheet is attached" : "no content view", status: 404) }
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
