import Foundation

/// Dates, counts, lengths of time and lists worded in the current language. Russian wording lives in `RussianFormat`
/// (cases and plural forms), English in `EnglishFormat`; anything that shows the person a date or a count goes
/// through here so that it follows the interface language.
public enum Wording {
    private static var isRussian: Bool { Localization.current == .russian }

    /// "30 сентября" / "September 30"
    public static func date(_ date: LocalDate) -> String {
        isRussian ? RussianFormat.date(date) : EnglishFormat.date(date)
    }

    /// "ср, 30 сентября" / "Wed, September 30"
    public static func dateWithWeekday(_ date: LocalDate) -> String {
        isRussian ? RussianFormat.dateWithWeekday(date) : EnglishFormat.dateWithWeekday(date)
    }

    /// "Сентябрь 2026" / "September 2026": the title of a month view.
    public static func monthTitle(_ date: LocalDate) -> String {
        isRussian ? RussianFormat.monthTitle(date) : EnglishFormat.monthTitle(date)
    }

    /// "пн" / "Mon": for the weekday row of a month view.
    public static func weekdayShortName(_ weekday: Weekday) -> String {
        isRussian ? RussianFormat.weekdayShortName(weekday) : EnglishFormat.weekdayShort[weekday.rawValue - 1]
    }

    /// "Среда, 30 сентября" / "Wednesday, September 30": the title of a day.
    public static func dayTitle(_ date: LocalDate) -> String {
        isRussian ? RussianFormat.dayTitle(date) : EnglishFormat.dayTitle(date)
    }

    public static func weekdayName(_ weekday: Weekday) -> String {
        isRussian ? RussianFormat.weekdayName(weekday) : EnglishFormat.weekdays[weekday.rawValue - 1]
    }

    /// "нет записей", "3 записи" / "no entries", "3 entries"
    public static func entryCount(_ count: Int) -> String {
        count == 0 ? tr("no entries") : trCount("%lld entries", count)
    }

    /// "15:00"
    public static func time(_ time: LocalTime) -> String { time.description }

    /// "завтра", "в пятницу, 2 октября" / "tomorrow", "on Friday, October 2", or the plain date when it is far off.
    public static func relativeDay(_ date: LocalDate, today: LocalDate) -> String {
        isRussian ? RussianFormat.relativeDay(date, today: today) : EnglishFormat.relativeDay(date, today: today)
    }

    // MARK: - Recurrence, "for <day>", "<day> at <time>"

    /// "каждый понедельник", "по будням" / "every Monday", "on weekdays"
    public static func recurrence(_ rule: Recurrence) -> String {
        isRussian ? RussianFormat.recurrence(rule) : EnglishFormat.recurrence(rule)
    }

    /// The rule with its end, for a list or an editor: "Каждую среду, до 31 декабря" / "Every Wednesday, until December 31".
    public static func recurrenceDetailed(_ rule: Recurrence) -> String {
        isRussian ? RussianFormat.recurrenceDetailed(rule) : EnglishFormat.recurrenceDetailed(rule)
    }

    /// "на завтра", "на пятницу, 2 октября" / "for tomorrow", "for Friday, October 2"
    public static func onDay(_ date: LocalDate, today: LocalDate) -> String {
        isRussian ? RussianFormat.onDay(date, today: today) : EnglishFormat.onDay(date, today: today)
    }

    /// When an item happens, for toasts: "завтра в 11:00", "без даты" / "tomorrow at 11:00", "no date".
    public static func when(date: LocalDate?, time: LocalTime?, today: LocalDate) -> String {
        isRussian ? RussianFormat.when(date: date, time: time, today: today) : EnglishFormat.when(date: date, time: time, today: today)
    }

    /// A time as it is said aloud: "в шестнадцать тридцать" / "at 4:30 PM".
    public static func spokenTime(_ time: LocalTime) -> String {
        isRussian ? AgendaSpeaker.russianSpokenTime(time) : EnglishFormat.spokenTime(time)
    }

    /// Text in the quotation marks of the current language: «Созвон» / “Team sync”.
    public static func quoted(_ text: String) -> String { tr("“%1$@”", text) }

    // MARK: - Lengths of time

    /// "5 минут" / "5 minutes", "1 час" / "1 hour", "2 дня" / "2 days": a whole number of minutes, hours or days.
    public static func duration(minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 { return trCount("%lld days", minutes / 1440) }
        if minutes >= 60, minutes % 60 == 0 { return trCount("%lld hours", minutes / 60) }
        return trCount("%lld minutes", minutes)
    }

    /// "Сейчас", "Через 5 минут" / "Now", "In 5 minutes"
    public static func leadPhrase(_ minutes: Int) -> String {
        minutes <= 0 ? tr("Now") : tr("In %1$@", duration(minutes: minutes))
    }

    /// "в момент начала", "за 5 минут" / "at the start", "5 minutes before": how a list of chosen lead times is read out.
    public static func leadBefore(_ minutes: Int) -> String {
        minutes <= 0 ? tr("at the start") : tr("%1$@ before", duration(minutes: minutes))
    }

    /// The short text of a choice chip: "В момент", "5 мин", "1 час" / "At start", "5 min", "1 hour".
    public static func leadChip(_ minutes: Int) -> String {
        if minutes <= 0 { return tr("At start") }
        if minutes >= 1440, minutes % 1440 == 0 { return trCount("%lld days", minutes / 1440) }
        if minutes >= 60, minutes % 60 == 0 { return trCount("%lld hours", minutes / 60) }
        return tr("%1$lld min", numbers: minutes)
    }

    /// "a", "a и b", "a, b и c" / "a", "a and b", "a, b and c"
    public static func list(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + tr(" and ") + last
    }
}

/// English wording for dates, the counterpart of `RussianFormat`.
enum EnglishFormat {
    static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let weekdayShort = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func date(_ date: LocalDate) -> String { "\(months[date.month - 1]) \(date.day)" }

    static func dateWithWeekday(_ date: LocalDate) -> String { "\(weekdayShort[date.weekday.rawValue - 1]), \(Self.date(date))" }

    static func monthTitle(_ date: LocalDate) -> String { "\(months[date.month - 1]) \(date.year)" }

    static func dayTitle(_ date: LocalDate) -> String { "\(weekdays[date.weekday.rawValue - 1]), \(Self.date(date))" }

    static func relativeDay(_ date: LocalDate, today: LocalDate) -> String {
        switch today.days(until: date) {
        case 0: "today"
        case 1: "tomorrow"
        case 2: "the day after tomorrow"
        case 3 ... 6: "on \(weekdays[date.weekday.rawValue - 1]), \(Self.date(date))"
        default: Self.date(date)
        }
    }
}

extension EnglishFormat {
    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st.
    static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch (number % 100, number % 10) {
        case (11 ... 13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(number)\(suffix)"
    }

    /// "every day", "on weekdays", "every Monday", "every 2 weeks on Fri", "every month, on the 25th"
    static func recurrence(_ rule: Recurrence) -> String {
        let n = rule.interval
        switch rule.freq {
        case .daily:
            return n == 1 ? "every day" : "every \(n) days"
        case .weekly:
            let days = Set(rule.byWeekday ?? []).sorted()
            let list = days.map { weekdayShort[$0.rawValue - 1] }.joined(separator: ", ")
            if n == 1 {
                if days == [.mon, .tue, .wed, .thu, .fri] { return "on weekdays" }
                if days.count == 1, let day = days.first { return "every \(weekdays[day.rawValue - 1])" }
                return days.isEmpty ? "every week" : "every week on \(list)"
            }
            return "every \(n) weeks" + (days.isEmpty ? "" : " on \(list)")
        case .monthly:
            let base = n == 1 ? "every month" : "every \(n) months"
            return rule.byMonthday.map { "\(base), on the \(ordinal($0))" } ?? base
        case .yearly:
            return n == 1 ? "every year" : "every \(n) years"
        }
    }

    /// The rule with its end: "Every Wednesday, until December 31", "Every day, 10 times".
    static func recurrenceDetailed(_ rule: Recurrence) -> String {
        var text = recurrence(rule).capitalizedFirstLetter
        if let until = rule.until { text += ", until \(date(until))" }
        if let count = rule.count { text += count == 1 ? ", once" : ", \(count) times" }
        return text
    }

    /// "for today", "for tomorrow", "for Friday, October 2" (within a week), "for October 12".
    static func onDay(_ date: LocalDate, today: LocalDate) -> String {
        switch today.days(until: date) {
        case 0: "for today"
        case 1: "for tomorrow"
        case 2: "for the day after tomorrow"
        case 3 ... 6: "for \(weekdays[date.weekday.rawValue - 1]), \(Self.date(date))"
        default: "for \(Self.date(date))"
        }
    }

    /// "tomorrow at 11:00", "on Wednesday, September 30", "no date".
    static func when(date: LocalDate?, time: LocalTime?, today: LocalDate) -> String {
        guard let date else { return "no date" }
        let day = relativeDay(date, today: today)
        return time.map { "\(day) at \($0)" } ?? day
    }

    /// "Today", "Tomorrow", "On Friday, October 2": the start of a spoken sentence.
    static func dayHeading(_ date: LocalDate, today: LocalDate) -> String {
        switch today.days(until: date) {
        case 0: "Today"
        case 1: "Tomorrow"
        case 2: "The day after tomorrow"
        case 3 ... 6: "On \(weekdays[date.weekday.rawValue - 1]), \(Self.date(date))"
        default: "On \(Self.date(date))"
        }
    }

    /// How a time is said aloud: "at midnight", "at noon", "at 9 AM", "at 4:30 PM".
    static func spokenTime(_ time: LocalTime) -> String {
        if time.hour == 0, time.minute == 0 { return "at midnight" }
        if time.hour == 12, time.minute == 0 { return "at noon" }
        let hour = time.hour % 12 == 0 ? 12 : time.hour % 12
        let suffix = time.hour < 12 ? "AM" : "PM"
        return time.minute == 0 ? "at \(hour) \(suffix)" : "at \(hour):\(time.minute < 10 ? "0" : "")\(time.minute) \(suffix)"
    }
}
