import Foundation

/// Removes text that Whisper is known to invent on silence, noise or music, and sound tags such as
/// "[музыка]" ("[music]"). Whole-utterance matching only, so a real command containing "спасибо" ("thanks") survives.
public enum HallucinationFilter {
    /// Normalised phrases (lowercase, no punctuation) that are hallucinations when they are the whole text.
    static let phrases: Set<String> = [
        "продолжение следует", "спасибо за просмотр", "спасибо за внимание", "подписывайтесь на канал",
        "подписывайтесь на мой канал", "ставьте лайки", "до новых встреч", "до свидания", "всем пока", "пока пока",
        "thank you", "thanks for watching", "thank you for watching", "you", "bye", "bye bye",
        "музыка", "аплодисменты", "смех", "звучит музыка", "играет музыка", "тишина", "конец",
    ]

    /// Normalised prefixes: credit lines Whisper learned from subtitle files.
    static let prefixes = [
        "субтитры сделал", "субтитры создавал", "субтитры подогнал", "редактор субтитров",
        "перевод субтитров", "amara org", "субтитры amara", "dimatorzok",
    ]

    /// The cleaned text, or `nil` when nothing real is left.
    public static func clean(_ text: String) -> String? {
        var working = text
        // sound tags: [музыка], (аплодисменты), *смех* ([music], (applause), *laughter*)
        working = working.replacingOccurrences(of: #"[\[\(\*][^\]\)\*]{0,40}[\]\)\*]"#, with: " ", options: .regularExpression)
        working = working.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let normalized = SearchText.tokens(working).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        if phrases.contains(normalized) { return nil }
        if prefixes.contains(where: { normalized.hasPrefix($0) }) { return nil }
        let words = normalized.split(separator: " ")
        // "Корректор А.Егорова": the credit line is the word followed by an initial (the tokens of "А.Егорова" are "а"
        // and "егорова"); "Корректор пришлёт правки в среду" is a sentence of somebody's day.
        if words.first == "корректор", words.count == 1 || words[1].count == 1 { return nil }
        // one token repeated over and over ("а а а а а", "да да да да да": "ah ah ah…", "yes yes yes…")
        if words.count >= 5, Set(words).count == 1 { return nil }
        // a lone letter or symbol; a lone digit is an answer ("2": the second of the offered options)
        if normalized.count <= 1, !normalized.contains(where: \.isNumber) { return nil }
        return working.trimmingCharacters(in: .whitespaces)
    }
}
