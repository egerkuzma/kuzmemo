import AppKit
import SwiftUI

/// A floating, non-activating panel near the top of the active screen that shows what the app is doing
/// (recording, recognising, thinking) and the result, above full-screen apps and on every Space.
final class HUDController {
    let model = HUDModel()
    var actions = HUDActions() {
        didSet { rebuildHosting() }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideTask: Task<Void, Never>?

    /// Shows a state; `autoHideAfter` closes it after that many seconds (paused while the pointer is over it).
    func show(_ state: HUDModel.State, autoHideAfter seconds: TimeInterval? = nil) {
        hideTask?.cancel()
        model.state = state
        if state == .hidden { hide(); return }
        ensurePanel()
        resize()
        panel?.orderFrontRegardless()
        if let seconds {
            hideTask = Task { [weak self] in
                var remaining = seconds
                while remaining > 0 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if Task.isCancelled { return }
                    if self?.model.hovering != true { remaining -= 0.2 }
                }
                self?.hide()
            }
        }
    }

    func showNote(_ text: String, style: AppEnvironment.Toast.Style = .warning, seconds: TimeInterval = 3) {
        show(.note(text, style), autoHideAfter: seconds)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        model.state = .hidden
        model.hovering = false
        panel?.orderOut(nil)
    }

    /// Recording indicators refresh often; only the size is recalculated when the state changes.
    func updateRecording(level: Float, elapsed: TimeInterval) {
        model.level = level
        model.elapsed = elapsed
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        self.panel = panel
        rebuildHosting()
    }

    private func rebuildHosting() {
        guard let panel else { return }
        let view = NSHostingView(rootView: HUDView(model: model, actions: actions))
        view.sizingOptions = [.intrinsicContentSize]
        panel.contentView = view
        hosting = view
    }

    private func resize() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
    }
}
