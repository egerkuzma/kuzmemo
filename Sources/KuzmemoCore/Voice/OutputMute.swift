import Foundation

/// How the sound output was silenced, kept so that exactly that can be undone (and remembered on disk, in case the app
/// is killed while the sound is off).
public struct SilenceToken: Codable, Equatable, Sendable {
    public var deviceUID: String
    /// The device has no mute switch, so its volume was set to zero instead.
    public var usedVolume: Bool
    /// The volume before it was set to zero (only meaningful with `usedVolume`).
    public var previousVolume: Float

    public init(deviceUID: String, usedVolume: Bool, previousVolume: Float = 0) {
        self.deviceUID = deviceUID
        self.usedVolume = usedVolume
        self.previousVolume = previousVolume
    }
}

/// What became of a silence the guard made.
public enum SilenceState: Sendable {
    /// The device is still as the guard left it: put it back.
    case silenced
    /// The person turned it up or unmuted it meanwhile: their choice stays.
    case changedByPerson
    /// The device is gone or cannot be read (a headset that dropped out): nothing can be said, so nothing is forgotten.
    case deviceUnavailable
}

/// The sound output of the Mac (headphones or speakers, whichever is the default one).
public protocol OutputAudioBackend: AnyObject {
    /// Silences the default output. `nil` when nothing was done: it is silent already (the person's own mute, which must
    /// stay), there is no output, or it has neither a mute switch nor a volume.
    func silenceDefaultOutput() -> SilenceToken?
    /// The device is still in the state `silenceDefaultOutput` left it in. If the person has turned it up or unmuted it
    /// meanwhile, this is `false` and their choice is left alone.
    func isStillSilenced(_ token: SilenceToken) -> Bool
    /// The same in three answers: a device that cannot be found is not one the person has touched.
    func state(of token: SilenceToken) -> SilenceState
    func restore(_ token: SilenceToken)
}

extension OutputAudioBackend {
    public func state(of token: SilenceToken) -> SilenceState { isStillSilenced(token) ? .silenced : .changedByPerson }
}

/// Where the guard writes down that it has silenced the output.
public protocol SilenceJournal: AnyObject {
    func load() -> SilenceToken?
    func save(_ token: SilenceToken)
    func clear()
}

public final class FileSilenceJournal: SilenceJournal {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> SilenceToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SilenceToken.self, from: data)
    }

    public func save(_ token: SilenceToken) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(token) { try? data.write(to: url, options: .atomic) }
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Silences the sound output while the person is recording (so that music or a video does not end up in the recording and
/// does not talk over them), and brings it back afterwards, exactly as it was. Only what it changed itself is undone.
@MainActor
public final class OutputMuteGuard {
    private let backend: any OutputAudioBackend
    private let journal: any SilenceJournal
    private var depth = 0
    private var token: SilenceToken?

    public init(backend: any OutputAudioBackend, journal: any SilenceJournal) {
        self.backend = backend
        self.journal = journal
    }

    /// The output is silent because of this guard.
    public var isSilencing: Bool { token != nil }

    /// A recording starts. Nested calls share one silence.
    public func begin() {
        depth += 1
        guard depth == 1 else { return }
        // A silence an earlier recording could not undo (its device was away) is put right first, if it can be now.
        if token == nil, let left = journal.load() { settle(left) }
        if let made = backend.silenceDefaultOutput() {
            token = made
            journal.save(made)
        }
    }

    /// A recording ended (every path: finished, cancelled, given up).
    public func end() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { restoreNow() }
    }

    /// The app is quitting, or something went wrong: put the sound back whatever the count says.
    public func forceEnd() {
        depth = 0
        restoreNow()
    }

    /// At launch: if the last run was killed while the sound was off, put it back.
    public func recoverAfterCrash() {
        guard token == nil, let left = journal.load() else { return }
        settle(left)
    }

    private func restoreNow() {
        guard let held = token else { return }
        token = nil
        settle(held)
    }

    /// Puts the sound back if it is still as the guard left it. The note of it is kept when the device cannot be found or
    /// read: a headset that dropped out mid-recording may come back still muted, and the next recording or launch can put
    /// that right (the note used to be wiped, and later recordings took that mute for the person's own).
    private func settle(_ held: SilenceToken) {
        switch backend.state(of: held) {
        case .silenced:
            backend.restore(held)
            journal.clear()
        case .changedByPerson:
            journal.clear()
        case .deviceUnavailable:
            journal.save(held)
        }
    }
}
