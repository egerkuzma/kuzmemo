import Foundation

/// How long a result card stays on screen after a voice command.
public enum ResultDisplay {
    /// A confirmation with Undo is short, 2 s (a second more for each extra line, 5 s at most): the change is already
    /// in the calendar, and a pointer resting on the card holds it. Everything else stays long enough to be read:
    /// 4 s at least, 12 s at most, more for longer texts.
    public static func seconds(characters: Int, lines: Int, undoable: Bool) -> TimeInterval {
        if undoable { return min(5, 2 + Double(max(lines - 1, 0))) }
        return min(12, max(4, 2.5 + Double(characters) * 0.06))
    }
}
