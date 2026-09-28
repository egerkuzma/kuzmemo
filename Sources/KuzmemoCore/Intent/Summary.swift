extension ItemKind {
    /// "Напоминание", "Событие", "Задача", "Заметка"
    public var russianName: String {
        switch self {
        case .reminder: "Напоминание"
        case .event: "Событие"
        case .task: "Задача"
        case .note: "Заметка"
        }
    }
}

extension RussianFormat {
    static let weekdayEvery = ["каждый понедельник", "каждый вторник", "каждую среду", "каждый четверг", "каждую пятницу", "каждую субботу", "каждое воскресенье"]

    /// "каждый понедельник", "по будням", "каждые 2 недели по пт", "каждое 25-е число"
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

    /// The rule for a list or an editor, with its end: "Каждую среду, до 31 декабря", "Каждый день, 10 раз".
    public static func recurrenceDetailed(_ rule: Recurrence) -> String {
        var text = recurrence(rule).capitalizedFirstLetter
        if let until = rule.until { text += ", до \(date(until))" }
        if let count = rule.count { text += ", \(count) \(plural(count, ("раз", "раза", "раз")))" }
        return text
    }

    static let weekdayAccusative = ["понедельник", "вторник", "среду", "четверг", "пятницу", "субботу", "воскресенье"]

    /// "на завтра", "на пятницу, 2 октября" (within a week), "на 12 октября".
    public static func onDay(_ date: LocalDate, today: LocalDate) -> String {
        switch today.days(until: date) {
        case 0: return "на сегодня"
        case 1: return "на завтра"
        case 2: return "на послезавтра"
        case 3...6: return "на \(weekdayAccusative[date.weekday.rawValue - 1]), \(Self.date(date))"
        default: return "на \(Self.date(date))"
        }
    }

    /// When an item happens, for toasts: "завтра в 11:00", "в среду, 30 сентября", "без даты".
    public static func when(date: LocalDate?, time: LocalTime?, today: LocalDate) -> String {
        guard let date else { return "без даты" }
        let day = relativeDay(date, today: today)
        return time.map { "\(day) в \($0)" } ?? day
    }
}

extension AppliedChange {
    /// One line for the confirmation toast, for example `Напоминание · послезавтра · «Сказать Дмитрию»`.
    public func summary(today: LocalDate) -> String {
        let title = "«\(item.title)»"
        switch kind {
        case .created:
            var parts = [item.kind.russianName, RussianFormat.when(date: item.date, time: item.time, today: today), title]
            if let rule = item.recurrence { parts.insert(RussianFormat.recurrence(rule), at: 2) }
            return parts.joined(separator: " · ")
        case .updated:
            return ["Изменено", title, RussianFormat.when(date: item.date, time: item.time, today: today)].joined(separator: " · ")
        case .moved:
            var target = newDate.map { RussianFormat.onDay($0, today: today) } ?? "без даты"
            if let time = newTime ?? item.time { target += " в \(time)" }
            return ["Перенесено", title, target].joined(separator: " · ")
        case .completed:
            return ["Выполнено", title, occurrenceDate.map { RussianFormat.date($0) }].compactMap { $0 }.joined(separator: " · ")
        case .reopened:
            return ["Возвращено", title, occurrenceDate.map { RussianFormat.date($0) }].compactMap { $0 }.joined(separator: " · ")
        case .deleted:
            return "Удалено · \(title)"
        case .skipped:
            return ["Пропущено", title, occurrenceDate.map { RussianFormat.date($0) }].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
