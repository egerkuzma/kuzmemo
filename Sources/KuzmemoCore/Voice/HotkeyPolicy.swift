import Foundation

/// The pure state machine behind the recording trigger (the Fn key, or a chord as a fallback). It knows
/// nothing about keyboards: feed it key-down/key-up/tick events with timestamps and act on what it returns.
///
/// - Tap (released within `holdThreshold`): recording keeps going (toggle mode); the next key-down stops it.
/// - Hold (released after `holdThreshold`): push-to-talk, recording stops on release.
/// - A chord (another key pressed while the trigger is held, early on) means the user was typing with a
///   modifier: the tentative recording is cancelled silently.
public struct HotkeyPolicy: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// The trigger is down and a recording is running (tentatively until we know tap from hold).
        case pressed(since: TimeInterval)
        /// A tap started a hands-free recording; the next key-down stops it.
        case toggled
        /// A hands-free recording is being stopped by the key-down we are still holding.
        case stopping
    }

    public enum Action: Equatable, Sendable {
        case startRecording
        case stopRecording
        /// Throw the recording away (a chord, an abort, or a too-short accident).
        case cancelRecording
        /// Stop speaking (barge-in) and start recording.
        case interruptSpeech
    }

    public struct Configuration: Sendable {
        /// Held at least this long means push-to-talk.
        public var holdThreshold: TimeInterval = 0.30
        /// Another key within this window after the press means typing with a modifier, not a command.
        public var chordWindow: TimeInterval = 0.5
        /// A hands-free recording is stopped after this much silence following speech (see the audio path).
        public var maxRecording: TimeInterval = 120
        public init() {}
    }

    public private(set) var state: State = .idle
    public var configuration: Configuration
    private var otherKeySeen = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The trigger went down. `speaking` is true while the app is reading an answer aloud.
    public mutating func triggerDown(at time: TimeInterval, speaking: Bool = false) -> [Action] {
        switch state {
        case .idle:
            state = .pressed(since: time)
            otherKeySeen = false
            return (speaking ? [.interruptSpeech] : []) + [.startRecording]
        case .toggled:
            state = .stopping
            return [.stopRecording]
        case .pressed, .stopping:
            return [] // key repeat or a duplicate event
        }
    }

    public mutating func triggerUp(at time: TimeInterval) -> [Action] {
        switch state {
        case let .pressed(since):
            if otherKeySeen {
                state = .idle
                return [.cancelRecording]
            }
            if time - since >= configuration.holdThreshold {
                state = .idle
                return [.stopRecording] // push-to-talk
            }
            state = .toggled // a tap: keep recording hands-free
            return []
        case .stopping:
            state = .idle // the key-up that belongs to the stopping key-down is swallowed
            return []
        case .idle, .toggled:
            return []
        }
    }

    /// Some other key was pressed while the trigger was held.
    public mutating func otherKeyPressed(at time: TimeInterval) -> [Action] {
        guard case let .pressed(since) = state else { return [] }
        otherKeySeen = true
        if time - since <= configuration.chordWindow {
            state = .idle
            return [.cancelRecording]
        }
        return [] // a long hold: the user is mid-sentence, ignore stray keys
    }

    /// A hands-free recording starts without a key press (the app listens for the answer to its own question).
    /// The next key-down stops it, exactly as after a tap.
    public mutating func beginHandsFree() -> [Action] {
        guard case .idle = state else { return [] }
        state = .toggled
        return [.startRecording]
    }

    /// The recording ended by itself (silence timeout, hard limit, error) or was cancelled elsewhere.
    public mutating func recordingEnded() {
        state = .idle
    }

    /// The system slept, the screen locked, or the event tap was lost while a key might be held.
    public mutating func reset() -> [Action] {
        defer { state = .idle }
        switch state {
        case .pressed, .toggled, .stopping: return [.cancelRecording]
        case .idle: return []
        }
    }

    public var isRecording: Bool {
        switch state {
        case .pressed, .toggled: true
        case .idle, .stopping: false
        }
    }
}
