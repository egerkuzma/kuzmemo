import Foundation

/// An answer as the "My voice" engine is fed it: one line per sentence, so that the first sentence can be played while the
/// next is being made. The text is made ready first (numbers, times and Latin words are spelled out, see `SpeechText`).
///
/// Every line costs the engine a fixed amount of work for the voice sample on top of the work for the words, so a run of
/// very short sentences is joined into one line, while a very long sentence is cut at its commas: a line that is much longer
/// than the one before it cannot be ready by the time the one before has been heard, and the answer would stall.
public enum OmniVoiceText {
    /// Sentences are joined while the line stays this short (about four seconds of speech).
    static let joinBelow = 60
    /// A sentence longer than this is cut at commas.
    static let cutAbove = 150

    public static func lines(for text: String) -> [String] {
        var lines: [String] = []
        for sentence in sentences(in: SpeechText.forNeuralVoice(text)) {
            for piece in cut(sentence) {
                if let last = lines.last, last.count + 1 + piece.count <= joinBelow {
                    lines[lines.count - 1] = last + " " + piece
                } else {
                    lines.append(piece)
                }
            }
        }
        return lines
    }

    /// Sentences end at . ! ? … followed by a space, or at a line break.
    static func sentences(in text: String) -> [String] {
        text.replacingOccurrences(of: #"(?<=[.!?…])[ \t]+"#, with: "\n", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A long sentence in pieces of at most `cutAbove` characters, at commas where there are any, else at spaces.
    static func cut(_ sentence: String) -> [String] {
        guard sentence.count > cutAbove else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true)
        for (index, word) in words.enumerated() {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > cutAbove, !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current = candidate
            }
            // prefer to break where the sentence has a comma once a piece is reasonably long
            if word.hasSuffix(","), current.count >= cutAbove / 2, index < words.count - 1 {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
