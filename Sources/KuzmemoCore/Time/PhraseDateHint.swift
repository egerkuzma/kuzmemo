/// An independent, deliberately conservative reading of common relative-date phrases in Russian and English, used
/// to cross-check the model's date description. It returns `nil` whenever it does not recognise the phrase or
/// the phrase is ambiguous ("next Friday"), in which case nothing is overridden.
public enum PhraseDateHint {
    /// Whether a normalised word means "next" ("следующую", "ближайшую", "next"): a phrase with it is ambiguous.
    static func isNextMarker(_ word: String) -> Bool {
        word.hasPrefix("следующ") || word.hasPrefix("ближаиш") || word == "next"
    }

    /// Whether the words say "tomorrow" (1) or "the day after tomorrow" (2); `nil` for neither.
    static func daysAhead(words: [String]) -> Int? {
        if words.contains("послезавтра") { return 2 }
        if words.contains("завтра") { return 1 }
        if words.contains("tomorrow") { return words.contains("after") ? 2 : 1 }
        return nil
    }

    public static func date(for phrase: String, anchor: LocalDateTime) -> LocalDate? {
        let words = SearchText.tokens(phrase)
        guard !words.isEmpty else { return nil }
        // Words are normalised (й → и), so the prefixes below are written the same way.
        if words.contains(where: isNextMarker) { return nil }
        if let english = englishDate(words: words, anchor: anchor) { return english }

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

    /// "in two hours", "in 3 days", "tomorrow", "on Friday", "end of the month".
    private static func englishDate(words: [String], anchor: LocalDateTime) -> LocalDate? {
        if let index = words.firstIndex(of: "in"), let offset = englishOffset(words: Array(words[(index + 1)...])) {
            switch offset {
            case let .minutes(n): return anchor.adding(minutes: n).date
            case let .days(n): return anchor.date.adding(days: n)
            case let .months(n): return anchor.date.adding(months: n)
            }
        }
        if let ahead = daysAhead(words: words), words.contains("tomorrow") { return anchor.date.adding(days: ahead) }
        if words.contains("today") { return anchor.date }
        if words.contains("yesterday") { return anchor.date.adding(days: -1) }
        if let weekday = words.lazy.compactMap(englishWeekday(for:)).first { return anchor.date.next(weekday) }
        if words.contains("end"), words.contains("month") { return anchor.date.lastOfMonth }
        return nil
    }

    private static func englishOffset(words: [String]) -> Offset? {
        var amount = 0
        var consumed = 0
        if words.starts(with: ["half", "an", "hour"]) || words.starts(with: ["half", "hour"]) { return .minutes(30) }
        for word in words {
            if let digits = Int(word) { amount += digits; consumed += 1; continue }
            if let value = englishNumbers[word] { amount += value; consumed += 1; continue }
            break
        }
        let unit: String? = consumed < words.count ? words[consumed] : nil
        if consumed == 0 { amount = 1 } // "in an hour", "in a week"
        guard let unit = unit ?? words.first, amount > 0 else { return nil }
        if unit.hasPrefix("minute") { return .minutes(amount) }
        if unit.hasPrefix("hour") || unit == "hr" || unit == "hrs" { return .minutes(amount * 60) }
        if unit.hasPrefix("week") { return .days(amount * 7) }
        if unit.hasPrefix("month") { return .months(amount) }
        if unit.hasPrefix("day") { return .days(amount) }
        return nil
    }

    static func englishWeekday(for word: String) -> Weekday? {
        switch word {
        case "monday": .mon
        case "tuesday": .tue
        case "wednesday": .wed
        case "thursday": .thu
        case "friday": .fri
        case "saturday": .sat
        case "sunday": .sun
        default: nil
        }
    }

    private static let englishNumbers: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    ]

    private enum Offset {
        case minutes(Int), days(Int), months(Int)
    }

    /// Parses what follows "через" ("in"): "два часа", "3 дня", "полчаса", "неделю", "двадцать пять минут"
    /// (two hours, 3 days, half an hour, a week, twenty-five minutes).
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

    /// The weekday a normalised word names ("пятницу" or "friday" → .fri), if any.
    static func weekday(for word: String) -> Weekday? {
        if let english = englishWeekday(for: word) { return english }
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
