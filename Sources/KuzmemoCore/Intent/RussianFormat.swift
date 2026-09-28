/// Russian wording for dates, used in clarification options, toasts and spoken answers.
public enum RussianFormat {
    static let monthsGenitive = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]
    static let weekdayNames = ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"]
    static let weekdayShort = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
    /// "on <weekday>" with the right preposition and case.
    static let weekdayOn = ["в понедельник", "во вторник", "в среду", "в четверг", "в пятницу", "в субботу", "в воскресенье"]

    /// "30 сентября"
    public static func date(_ date: LocalDate) -> String { "\(date.day) \(monthsGenitive[date.month - 1])" }

    /// "ср, 30 сентября"
    public static func dateWithWeekday(_ date: LocalDate) -> String {
        "\(weekdayShort[date.weekday.rawValue - 1]), \(Self.date(date))"
    }

    /// "15:00"
    public static func time(_ time: LocalTime) -> String { time.description }

    public static func weekdayName(_ weekday: Weekday) -> String { weekdayNames[weekday.rawValue - 1] }

    /// "сегодня", "завтра", "послезавтра", "в пятницу, 2 октября" (within a week) or "12 октября".
    public static func relativeDay(_ date: LocalDate, today: LocalDate) -> String {
        switch today.days(until: date) {
        case 0: return "сегодня"
        case 1: return "завтра"
        case 2: return "послезавтра"
        case 3...6: return "\(weekdayOn[date.weekday.rawValue - 1]), \(Self.date(date))"
        default: return Self.date(date)
        }
    }

    /// Chooses the plural form for a count: forms = ("запись", "записи", "записей").
    public static func plural(_ count: Int, _ forms: (String, String, String)) -> String {
        let n = abs(count) % 100
        let last = n % 10
        if n > 10 && n < 20 { return forms.2 }
        if last == 1 { return forms.0 }
        if last >= 2 && last <= 4 { return forms.1 }
        return forms.2
    }
}
