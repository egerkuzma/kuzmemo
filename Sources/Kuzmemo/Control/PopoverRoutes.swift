import AppKit
import Foundation
import SwiftUI

/// Checks the popover's close path without touching the person's screen or keyboard: the real popover cannot be
/// opened from a script (its menu-bar item cannot be clicked from inside the process), so a stand-in panel, kept far
/// outside every screen, hosts the same view and must be found, closed and forgotten by the same code.
enum PopoverRoutes {
    static func wiring(_ env: AppEnvironment) async -> HTTPResponse {
        let saved = env.popoverWindow
        defer { env.popoverWindow = saved }
        env.popoverWindow = nil
        let panel = NSPanel(contentRect: NSRect(x: -30000, y: -30000, width: 380, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PopoverView(env: env))
        panel.orderFrontRegardless()
        for _ in 0 ..< 20 where env.popoverWindow == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let registered = env.popoverWindow === panel
        let visibleBefore = panel.isVisible
        env.closePopover()
        let visibleAfter = panel.isVisible
        env.closePopover() // nothing to close any more: must be harmless
        panel.close()
        return .json(["registered": registered, "visibleBefore": visibleBefore, "visibleAfterClose": visibleAfter])
    }
}
