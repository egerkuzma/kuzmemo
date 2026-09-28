import AppKit

/// Short, quiet system sounds that confirm what happened without words.
final class SoundCues {
    enum Cue: String {
        /// A record was saved.
        case saved = "Pop"
        /// The app asks something or could not do what was asked.
        case attention = "Basso"
    }

    var muted = false
    var volume: Float = 0.35
    /// What was (or would have been) played, newest last; the control channel reads it.
    private(set) var log: [String] = []

    func play(_ cue: Cue) {
        log.append(cue.rawValue)
        if log.count > 100 { log.removeFirst(log.count - 100) }
        guard !muted, let sound = NSSound(named: NSSound.Name(cue.rawValue)) else { return }
        sound.volume = volume
        sound.play()
    }
}
