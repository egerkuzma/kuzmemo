/// An independent, deliberately conservative reading of common Russian relative-date phrases, used to
/// cross-check the model's date description. It returns `nil` whenever it does not recognise the phrase or
/// the phrase is ambiguous ("в следующую пятницу"), in which case nothing is overridden.
public enum PhraseDateHint {
    public static func date(for phrase: String, anchor: LocalDateTime) -> LocalDate? {
        let words = SearchText.tokens(phrase)
        guard !words.isEmpty else { return nil }
        // Words are normalised (й → и), so the prefixes below are written the same way.
        if words.contains(where: { $0.hasPrefix("следующ") || $0.hasPrefix("ближаиш") }) { return nil }

        if let index = words.firstIndex(of: "через"), let offset = relativeOffset(words: Array(words[(index + 1)...])) {
            switch offset {
            case let .minutes(n): return anchor.adding(minutes: n).date
            case let .days(n): return anchor.date.adding(days: n)
            case let .months(n): return anchor.date.adding(months: n)
            }
        }

        if words.contains("послезавтра") { return anchor.date.adding(days: 2) }
        if words.contains("завтра") { return anchor.date.adding(days: 1) }
        if words.contains("сегодня") { return anchor.date }
        if words.contains("позавчера") { return anchor.date.adding(days: -2) }
        if words.contains("вчера") { return anchor.date.adding(days: -1) }

        if let weekday = words.lazy.compactMap(weekday(for:)).first { return anchor.date.next(weekday) }

        if words.contains(where: { $0.hasPrefix("конец") || $0.hasPrefix("конц") }), words.contains(where: { $0.hasPrefix("месяц") }) {
            return anchor.date.lastOfMonth
        }
        return nil
    }

    private enum Offset {
        case minutes(Int), days(Int), months(Int)
    }

    /// Parses what follows "через": "два часа", "3 дня", "полчаса", "неделю", "двадцать пять минут".
    private static func relativeOffset(words: [String]) -> Offset? {
        guard let first = words.first else { return nil }
        if first == "полчаса" { return .minutes(30) }
        if first == "полтора" || first == "полторы", words.count > 1, words[1].hasPrefix("час") { return .minutes(90) }

        var amount = 0
        var consumed = 0
        for word in words {
            if let digits = Int(word) { amount += digits; consumed += 1; continue }
            if let value = numberWords[word] { amount += value; consumed += 1; continue }
            break
        }
        let unit: String? = consumed < words.count ? words[consumed] : nil
        if consumed == 0 { amount = 1 } // "через неделю", "через час"
        guard let unit = unit ?? (consumed == 0 ? words.first : nil), amount > 0 else { return nil }

        if unit.hasPrefix("минут") { return .minutes(amount) }
        if unit.hasPrefix("час") { return .minutes(amount * 60) }
        if unit.hasPrefix("недел") { return .days(amount * 7) }
        if unit.hasPrefix("месяц") { return .months(amount) }
        if unit == "день" || unit.hasPrefix("дн") { return .days(amount) }
        return nil
    }

    /// The weekday a normalised word names ("пятницу" → .fri), if any.
    static func weekday(for word: String) -> Weekday? {
        if word.hasPrefix("понедельник") { return .mon }
        if word.hasPrefix("вторник") { return .tue }
        if word == "среду" || word == "среда" || word == "среды" || word == "среде" { return .wed }
        if word.hasPrefix("четверг") { return .thu }
        if word.hasPrefix("пятниц") { return .fri }
        if word.hasPrefix("суббот") { return .sat }
        if word.hasPrefix("воскресен") { return .sun }
        return nil
    }

    /// Normalised (ё → е) Russian number words that appear after "через".
    private static let numberWords: [String: Int] = [
        "один": 1, "одну": 1, "одного": 1, "два": 2, "две": 2, "двух": 2, "три": 3, "трех": 3,
        "четыре": 4, "четырех": 4, "пять": 5, "пяти": 5, "шесть": 6, "шести": 6, "семь": 7, "семи": 7,
        "восемь": 8, "восьми": 8, "девять": 9, "девяти": 9, "десять": 10, "десяти": 10,
        "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14, "пятнадцать": 15,
        "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18, "девятнадцать": 19,
        "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50, "шестьдесят": 60,
    ]
}

extension RelativeDateResolver {
    public enum CrossCheck: Equatable, Sendable {
        /// The local reading of the phrase matches the model's date.
        case agrees
        /// The phrase was not recognised or is ambiguous; nothing to compare.
        case noHint
        /// The local reading differs; `localDate` is what the phrase says.
        case disagrees(localDate: LocalDate)
    }

    /// Compares the model's resolved date with an independent reading of `when.phrase`.
    public func crossCheck(_ when: When, resolved: ResolvedWhen) -> CrossCheck {
        guard let phrase = when.phrase, let hint = PhraseDateHint.date(for: phrase, anchor: anchor) else { return .noHint }
        return resolved.date == hint ? .agrees : .disagrees(localDate: hint)
    }
}
