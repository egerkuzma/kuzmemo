extension ItemKind {
    /// "Reminder", "Event", "Task", "Note" in the current language.
    public var displayName: String {
        switch self {
        case .reminder: tr("Reminder")
        case .event: tr("Event")
        case .task: tr("Task")
        case .note: tr("Note")
        }
    }
}

extension RussianFormat {
    /// "every Monday" in Russian, one form per weekday (the case depends on the weekday's grammatical gender).
    static let weekdayEvery = ["каждый понедельник", "каждый вторник", "каждую среду", "каждый четверг", "каждую пятницу", "каждую субботу", "каждое воскресенье"]

    /// "каждый понедельник", "по будням", "каждые 2 недели по пт", "каждое 25-е число"
    /// (every Monday, on weekdays, every 2 weeks on Fri, on the 25th of every month)
    public static func recurrence(_ rule: Recurrence) -> String {
        let n = rule.interval
        switch rule.freq {
        case .daily:
            return n == 1 ? "каждый день" : "каждые \(n) \(plural(n, ("день", "дня", "дней")))"
        case .weekly:
            let days = Set(rule.byWeekday ?? []).sorted()
            let list = days.map { weekdayShort[$0.rawValue - 1] }.joined(separator: ", ")
            if n == 1 {
                if days == [.mon, .tue, .wed, .thu, .fri] { return "по будням" }
                if days.count == 1, let day = days.first { return weekdayEvery[day.rawValue - 1] }
                return days.isEmpty ? "каждую неделю" : "каждую неделю по \(list)"
            }
            return "каждые \(n) \(plural(n, ("неделю", "недели", "недель")))" + (days.isEmpty ? "" : " по \(list)")
        case .monthly:
            let base = n == 1 ? "каждый месяц" : "каждые \(n) \(plural(n, ("месяц", "месяца", "месяцев")))"
            return rule.byMonthday.map { "\(base), \($0)-го числа" } ?? base
        case .yearly:
            return n == 1 ? "каждый год" : "каждые \(n) \(plural(n, ("год", "года", "лет")))"
        }
    }

    /// The rule for a list or an editor, with its end: "Каждую среду, до 31 декабря", "Каждый день, 10 раз"
    /// (Every Wednesday, until December 31; Every day, 10 times).
    public static func recurrenceDetailed(_ rule: Recurrence) -> String {
        var text = recurrence(rule).capitalizedFirstLetter
        if let until = rule.until { text += ", до \(date(until))" }
        if let count = rule.count { text += ", \(count) \(plural(count, ("раз", "раза", "раз")))" }
        return text
    }

    static let weekdayAccusative = ["понедельник", "вторник", "среду", "четверг", "пятницу", "субботу", "воскресенье"]

    /// "на завтра", "на пятницу, 2 октября" (within a week), "на 12 октября" (for tomorrow, for Friday, October 2, for October 12).
    public static func onDay(_ date: LocalDate, today: LocalDate) -> String {
        switch today.days(until: date) {
        case 0: return "на сегодня"
        case 1: return "на завтра"
        case 2: return "на послезавтра"
        case 3...6: return "на \(weekdayAccusative[date.weekday.rawValue - 1]), \(Self.date(date))"
        default: return "на \(Self.date(date))"
        }
    }

    /// When an item happens, for toasts: "завтра в 11:00", "в среду, 30 сентября", "без даты" (tomorrow at 11:00, on Wednesday,
    /// September 30, no date).
    public static func when(date: LocalDate?, time: LocalTime?, today: LocalDate) -> String {
        guard let date else { return "без даты" }
        let day = relativeDay(date, today: today)
        return time.map { "\(day) в \($0)" } ?? day
    }
}

extension AppliedChange {
    /// One line for the confirmation toast, for example `Reminder · the day after tomorrow · “Tell Dmitry”`.
    public func summary(today: LocalDate) -> String {
        let title = Wording.quoted(item.title)
        let when = Wording.when(date: item.date, time: item.time, today: today)
        switch kind {
        case .created:
            var parts = [item.kind.displayName, when, title]
            if let rule = item.recurrence { parts.insert(Wording.recurrence(rule), at: 2) }
            return parts.joined(separator: " · ")
        case .updated:
            return [tr("Changed"), title, when].joined(separator: " · ")
        case .moved:
            var target = newDate.map { Wording.onDay($0, today: today) } ?? tr("no date")
            if let time = newTime ?? item.time { target += tr(" at %1$@", Wording.time(time)) }
            return [tr("Moved"), title, target].joined(separator: " · ")
        case .completed:
            return [tr("Completed"), title, occurrenceDate.map { Wording.date($0) }].compactMap { $0 }.joined(separator: " · ")
        case .reopened:
            return [tr("Reopened"), title, occurrenceDate.map { Wording.date($0) }].compactMap { $0 }.joined(separator: " · ")
        case .deleted:
            return "\(tr("Deleted")) · \(title)"
        case .skipped:
            return [tr("Skipped"), title, occurrenceDate.map { Wording.date($0) }].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
