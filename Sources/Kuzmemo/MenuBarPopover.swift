import AppKit

/// The menu-bar popover. SwiftUI offers no call to close the popover of a `.window`-style menu bar extra (and its
/// status item has no action to click programmatically), so it is closed by hiding the window that hosts it.
enum MenuBarPopover {
    /// Hides the popover's window and clears the highlight the menu-bar item keeps while the popover is open.
    static func hide(_ window: NSWindow) {
        window.orderOut(nil)
        for statusWindow in NSApp.windows where statusWindow.className == "NSStatusBarWindow" {
            button(in: statusWindow.contentView)?.highlight(false)
        }
    }

    private static func button(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews { if let found = button(in: subview) { return found } }
        return nil
    }
}
