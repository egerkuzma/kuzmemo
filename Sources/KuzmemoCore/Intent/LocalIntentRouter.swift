import Foundation

/// A rule-based shortcut for the most common questions in Russian and English ("что на сегодня" / "what's on today",
/// "что у меня завтра" / "what do I have tomorrow", "что дальше" / "what's next").
/// Matching is deliberately strict — the whole utterance must be such a question — so anything unusual still
/// goes to the model; a false positive here would be worse than a slower answer. Saves a whole model call.
public struct LocalIntentRouter: Sendable {
    public init() {}

    public func route(_ transcript: String, today: LocalDate) -> QueryPlan? {
        let words = SearchText.tokens(transcript).filter { !Self.filler.contains($0) }
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let joined = words.joined(separator: " ")

        // What is planned for a day
        for (phrase, offset) in Self.dayPhrases where Self.matches(joined, phrase) {
            let date = today.adding(days: offset)
            return QueryPlan(target: .days(date ... date))
        }
        // Week and coming events
        if Self.matches(joined, "на этой неделе") || Self.matches(joined, "на неделе") || Self.matches(joined, "на эту неделю")
            || Self.matches(joined, "this week") || Self.matches(joined, "for this week") {
            return QueryPlan(target: .days(today ... today.startOfWeek.adding(days: 6)))
        }
        if Self.matches(joined, "на следующей неделе") || Self.matches(joined, "на следующую неделю")
            || Self.matches(joined, "next week") || Self.matches(joined, "for next week") {
            let monday = today.startOfWeek.adding(days: 7)
            return QueryPlan(target: .days(monday ... monday.adding(days: 6)))
        }
        if Self.nextPhrases.contains(joined) { return QueryPlan(target: .upcoming(limit: 5)) }
        if Self.overduePhrases.contains(joined) { return QueryPlan(target: .overdue) }
        return nil
    }

    /// Words that do not change the meaning of these questions.
    static let filler: Set<String> = [
        "пожалуиста", "скажи", "расскажи", "покажи", "мне", "у", "меня", "есть", "будет", "какие", "какое", "какой",
        "что", "чего", "ну", "а", "и", "да", "все", "всё", "дела", "дел", "планы", "плана", "план", "запланировано", "мои", "мой", "моя", "там", "по", "плану", "планам",
        // English
        "what", "s", "is", "are", "on", "do", "i", "have", "got", "my", "me", "the", "there", "anything", "any", "tell", "show", "please",
        "plans", "planned", "schedule", "agenda", "going", "for", "about", "to", "up", "coming",
    ]

    static let dayPhrases: [(String, Int)] = [
        ("на сегодня", 0), ("сегодня", 0), ("на завтра", 1), ("завтра", 1), ("на послезавтра", 2), ("послезавтра", 2),
        ("today", 0), ("tomorrow", 1), ("day after tomorrow", 2),
    ]

    static let nextPhrases: Set<String> = ["дальше", "далее", "потом", "следующее", "ближаишее", "дальше по плану", "next", "upcoming", "next up"]
    static let overduePhrases: Set<String> = ["просрочено", "просроченные", "просроченное", "просрочил", "просрочила", "overdue", "past due"]

    /// Phrases are written naturally ("на этой неделе", "this week") and folded the same way as the transcript (й → и).
    static func matches(_ text: String, _ phrase: String) -> Bool { text == SearchText.normalize(phrase) }
}
