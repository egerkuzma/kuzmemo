import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation

/// What the app is allowed to do right now. The status is re-read whenever the app becomes active, because
/// the user changes these in System Settings, outside our control.
@Observable
final class PermissionsModel {
    private(set) var microphone: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var inputMonitoring: Bool = CGPreflightListenEventAccess()

    var microphoneGranted: Bool { microphone == .authorized }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        inputMonitoring = CGPreflightListenEventAccess()
    }

    /// Asks the system for microphone access (shows the system prompt the first time).
    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Shows the Input Monitoring prompt. macOS only applies a new grant after the app restarts.
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
