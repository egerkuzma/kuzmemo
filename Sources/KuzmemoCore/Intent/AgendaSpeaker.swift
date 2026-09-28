import Foundation

/// Composes what the app says aloud, from real data only: nothing is invented. Times and numbers are
/// spelled out because system voices read "11:00" badly; brand names are swapped for the spoken form the
/// user gave in the glossary.
public struct AgendaSpeaker: Sendable {
    public var glossary: [GlossaryTerm]
    /// How many entries are read before "и ещё N".
    public var maxEntries = 6

    public init(glossary: [GlossaryTerm] = []) {
        self.glossary = glossary
    }

    // MARK: Answers

    public func speech(for result: QueryResult, today: LocalDate) -> String {
        let entries = result.entries
        let label = Self.label(for: result, today: today)

        if case .days = result.plan.target, result.plan.detail == .count {
            return entries.isEmpty ? "\(label) ничего нет." : "\(label) \(Self.countPhrase(entries.count))."
        }
        if entries.isEmpty { return Self.emptyPhrase(for: result, label: label) }

        if result.plan.detail == .first, let first = entries.first {
            return "Ближайшее: \(describe(first, today: today, withDay: true))."
        }

        var sentences = ["\(label) \(Self.countPhrase(entries.count)):"]
        for entry in entries.prefix(maxEntries) {
            sentences.append(describe(entry, today: today, withDay: Self.needsDay(result.plan.target)) + ".")
        }
        if entries.count > maxEntries {
            let rest = entries.count - maxEntries
            sentences.append("И ещё \(Self.number(rest)) \(RussianFormat.plural(rest, ("запись", "записи", "записей"))).")
        }
        return sentences.joined(separator: " ")
    }

    /// One entry as a phrase: "в одиннадцать часов созвон с Фигма", "в среду, без времени, оплатить инвойс".
    public func describe(_ entry: AgendaEntry, today: LocalDate, withDay: Bool) -> String {
        var parts: [String] = []
        if withDay { parts.append(RussianFormat.relativeDay(entry.date, today: today)) }
        if let time = entry.time {
            parts.append(Self.spokenTime(time))
        } else if entry.item.date != nil, !withDay {
            parts.append("без времени")
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

    static func label(for result: QueryResult, today: LocalDate) -> String {
        switch result.plan.target {
        case let .days(range):
            if range.lowerBound == range.upperBound {
                return RussianFormat.onDay(range.lowerBound, today: today).capitalizedFirstLetter + " у вас"
            }
            return "С \(RussianFormat.date(range.lowerBound)) по \(RussianFormat.date(range.upperBound)) у вас"
        case .upcoming: return "Дальше в планах"
        case .overdue: return "Просрочено"
        case .inbox: return "Без даты у вас"
        case .recurring: return "Повторяющихся"
        case .search: return "Нашёл"
        }
    }

    static func emptyPhrase(for result: QueryResult, label: String) -> String {
        switch result.plan.target {
        case .days: "\(label) ничего не запланировано."
        case .upcoming: "Ближайших дел нет."
        case .overdue: "Просроченных дел нет."
        case .inbox: "Записей без даты нет."
        case .recurring: "Повторяющихся записей нет."
        case .search: "Ничего не нашёл."
        }
    }

    /// "три дела", "одно дело", "пять дел"
    static func countPhrase(_ count: Int) -> String {
        "\(number(count, feminine: false, neuter: true)) \(RussianFormat.plural(count, ("дело", "дела", "дел")))"
    }

    static func number(_ n: Int, feminine: Bool = true, neuter: Bool = false) -> String {
        NumberWords.say(n, feminine: feminine, neuter: neuter)
    }

    /// "в девять часов", "в один час", "в шестнадцать тридцать", "в девять ноль пять"
    public static func spokenTime(_ time: LocalTime) -> String {
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
