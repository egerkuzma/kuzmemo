import Foundation

/// Composes what the app says aloud, from real data only: nothing is invented. In Russian, times and numbers are
/// spelled out because system voices read "11:00" badly; brand names are swapped for the spoken form the
/// person gave in the glossary. The wording follows the interface language.
public struct AgendaSpeaker: Sendable {
    public var glossary: [GlossaryTerm]
    /// How many entries are read before "and N more".
    public var maxEntries = 6

    public init(glossary: [GlossaryTerm] = []) {
        self.glossary = glossary
    }

    // MARK: Answers

    public func speech(for result: QueryResult, today: LocalDate) -> String {
        let entries = result.entries
        let label = Self.label(for: result, today: today)

        if case .days = result.plan.target, result.plan.detail == .count {
            if entries.isEmpty { return result.passedToday > 0 ? tr("%1$@ nothing left.", label) : tr("%1$@ nothing.", label) }
            return tr("%1$@ %2$@.", label, Self.countPhrase(entries.count))
        }
        if entries.isEmpty { return Self.emptyPhrase(for: result, label: label) }

        if result.plan.detail == .first, let first = entries.first {
            return tr("Next: %1$@.", describe(first, today: today, withDay: true))
        }

        var sentences = [Self.intro(for: result, today: today, count: Self.countPhrase(entries.count))]
        for entry in entries.prefix(maxEntries) {
            sentences.append(describe(entry, today: today, withDay: Self.needsDay(result.plan.target)) + ".")
        }
        if entries.count > maxEntries {
            sentences.append(tr("And %1$@.", Self.moreEntries(entries.count - maxEntries)))
        }
        return sentences.joined(separator: " ")
    }

    /// One entry as a phrase: "at 11 AM, Team sync", "on Wednesday, no time, Pay the invoice".
    public func describe(_ entry: AgendaEntry, today: LocalDate, withDay: Bool) -> String {
        var parts: [String] = []
        if withDay { parts.append(Wording.relativeDay(entry.date, today: today)) }
        if let time = entry.time {
            parts.append(Self.spokenTime(time))
        } else if entry.item.date != nil, !withDay {
            parts.append(tr("no time"))
        }
        parts.append(Glossary.spokenForm(of: entry.item.title, terms: glossary))
        return parts.joined(separator: ", ")
    }

    // MARK: Wording

    static func needsDay(_ target: QueryPlan.Target) -> Bool {
        switch target {
        case let .days(range): range.lowerBound != range.upperBound
        default: true
        }
    }

    /// The lead of a spoken answer about days: "Today you have" in English, "На сегодня у тебя" in Russian.
    static func label(for result: QueryResult, today: LocalDate) -> String {
        guard case let .days(range) = result.plan.target else { return "" }
        if range.lowerBound == range.upperBound {
            return Localization.current == .russian
                ? RussianFormat.onDay(range.lowerBound, today: today).capitalizedFirstLetter + " у тебя"
                : tr("%1$@ you have", EnglishFormat.dayHeading(range.lowerBound, today: today))
        }
        return tr("From %1$@ to %2$@ you have", Wording.date(range.lowerBound), Wording.date(range.upperBound))
    }

    /// The first sentence of a spoken list: "Today you have 3 items:", "You have 2 items overdue:".
    static func intro(for result: QueryResult, today: LocalDate, count: String) -> String {
        switch result.plan.target {
        case .days: tr("%1$@ %2$@:", label(for: result, today: today), count)
        case .upcoming: tr("Next up you have %1$@:", count)
        case .overdue: tr("You have %1$@ overdue:", count)
        case .inbox: tr("Without a date you have %1$@:", count)
        case .recurring: tr("You have %1$@ repeating:", count)
        case .search: tr("I found %1$@:", count)
        }
    }

    static func emptyPhrase(for result: QueryResult, label: String) -> String {
        switch result.plan.target {
        case .days: result.passedToday > 0 ? tr("%1$@ nothing left.", label) : tr("%1$@ nothing planned.", label)
        case .upcoming: tr("There is nothing coming up.")
        case .overdue: tr("Nothing is overdue.")
        case .inbox: tr("There are no undated entries.")
        case .recurring: tr("There are no repeating entries.")
        case .search: tr("I found nothing.")
        }
    }

    /// A count of entries read aloud: "3 items", "1 item" in English; "три дела", "одно дело", "пять дел" in Russian.
    static func countPhrase(_ count: Int) -> String {
        if Localization.current == .russian {
            return "\(number(count, feminine: false, neuter: true)) \(RussianFormat.plural(count, ("дело", "дела", "дел")))"
        }
        return trCount("%lld items", count)
    }

    /// The remainder after the first few are read: "3 more entries" in English, "три записи" in Russian.
    static func moreEntries(_ count: Int) -> String {
        if Localization.current == .russian {
            return "ещё \(number(count)) \(RussianFormat.plural(count, ("запись", "записи", "записей")))"
        }
        return trCount("%lld more entries", count)
    }

    static func number(_ n: Int, feminine: Bool = true, neuter: Bool = false) -> String {
        NumberWords.say(n, feminine: feminine, neuter: neuter)
    }

    /// A time as it is said aloud in the current language.
    public static func spokenTime(_ time: LocalTime) -> String { Wording.spokenTime(time) }

    /// A Russian time in words: "в девять часов", "в один час", "в шестнадцать тридцать", "в девять ноль пять"
/// (at nine o'clock, at one o'clock, at sixteen thirty, at nine oh five).
    static func russianSpokenTime(_ time: LocalTime) -> String {
        let hour = time.hour
        let minute = time.minute
        if hour == 0 && minute == 0 { return "в полночь" }
        if minute == 0 {
            let word = NumberWords.say(hour, feminine: false)
            let unit = RussianFormat.plural(hour, ("час", "часа", "часов"))
            return "в \(word) \(unit)"
        }
        let hourWord = NumberWords.say(hour, feminine: false)
        let minuteWord = minute < 10 ? "ноль " + NumberWords.say(minute, feminine: false) : NumberWords.say(minute, feminine: false)
        return "в \(hourWord) \(minuteWord)"
    }
}

/// Russian cardinal numbers for spoken output (0...99 is all the app needs).
enum NumberWords {
    private static let units = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let teens = [
        "десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать",
        "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать",
    ]
    private static let tens = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"]

    static func say(_ n: Int, feminine: Bool, neuter: Bool = false) -> String {
        guard n >= 0 else { return "минус " + say(-n, feminine: feminine, neuter: neuter) }
        guard n < 100 else { return String(n) }
        if n < 10 { return unit(n, feminine: feminine, neuter: neuter) }
        if n < 20 { return teens[n - 10] }
        let ten = tens[n / 10]
        let one = n % 10
        return one == 0 ? ten : ten + " " + unit(one, feminine: feminine, neuter: neuter)
    }

    private static func unit(_ n: Int, feminine: Bool, neuter: Bool) -> String {
        switch n {
        case 1: neuter ? "одно" : (feminine ? "одна" : "один")
        case 2: feminine ? "две" : "два"
        default: units[n]
        }
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
