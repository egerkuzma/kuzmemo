import Foundation
import Observation

/// What the floating HUD shows right now.
@Observable
final class HUDModel {
    enum State: Equatable {
        case hidden
        /// First launch: the speech model is being compiled for this Mac (a minute or two, once).
        case preparingModel
        case recording(handsFree: Bool)
        case transcribing
        case interpreting(String)
        case result(AppEnvironment.Toast)
        /// A question is on screen and the microphone is open for the answer.
        case listening(AppEnvironment.Toast)
        case note(String, AppEnvironment.Toast.Style)
    }

    var state: State = .hidden
    /// 0...1, smoothed microphone level while recording.
    var level: Float = 0
    var elapsed: TimeInterval = 0
    var hovering = false
}

/// What the buttons in the HUD do; wired up by the controller.
struct HUDActions {
    var cancel: () -> Void = {}
    var undo: (String) -> Void = { _ in }
    var choose: (String) -> Void = { _ in }
}
