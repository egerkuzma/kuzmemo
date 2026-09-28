/// How the model describes a date/time. The model never does calendar arithmetic: it names the relative
/// offset (or the explicit date the user said) and `RelativeDateResolver` computes the calendar date.
/// Mirrors the `when` object of the response schema (docs/PLAN.md, appendix A).
public struct When: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case none
        case absolute
        case daysFromToday = "days_from_today"
        case weekday
        case minutesFromNow = "minutes_from_now"
        case monthPart = "month_part"
    }

    public enum MonthPart: String, Codable, Sendable { case start, end }
    public enum DayPart: String, Codable, Sendable { case morning, day, evening, night }

    public var mode: Mode
    /// The user's original wording, used to cross-check the model's arithmetic.
    public var phrase: String?
    public var date: LocalDate?
    public var daysFromToday: Int?
    public var weekday: Weekday?
    public var weekOffset: Int?
    public var minutesFromNow: Int?
    public var monthPart: MonthPart?
    public var monthOffset: Int?
    public var time: LocalTime?
    public var dayPart: DayPart?
    public var approximate: Bool?

    public init(
        mode: Mode, phrase: String? = nil, date: LocalDate? = nil, daysFromToday: Int? = nil,
        weekday: Weekday? = nil, weekOffset: Int? = nil, minutesFromNow: Int? = nil,
        monthPart: MonthPart? = nil, monthOffset: Int? = nil, time: LocalTime? = nil,
        dayPart: DayPart? = nil, approximate: Bool? = nil
    ) {
        self.mode = mode
        self.phrase = phrase
        self.date = date
        self.daysFromToday = daysFromToday
        self.weekday = weekday
        self.weekOffset = weekOffset
        self.minutesFromNow = minutesFromNow
        self.monthPart = monthPart
        self.monthOffset = monthOffset
        self.time = time
        self.dayPart = dayPart
        self.approximate = approximate
    }

    enum CodingKeys: String, CodingKey {
        case mode, phrase, date
        case daysFromToday = "days_from_today"
        case weekday
        case weekOffset = "week_offset"
        case minutesFromNow = "minutes_from_now"
        case monthPart = "month_part"
        case monthOffset = "month_offset"
        case time
        case dayPart = "day_part"
        case approximate
    }

    /// Lenient decoding: models sometimes write "9:00", "09:00:00" or a bare hour; a malformed explicit date
    /// still fails so the caller can retry instead of silently guessing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try c.decode(Mode.self, forKey: .mode),
            phrase: try c.decodeIfPresent(String.self, forKey: .phrase),
            date: try c.decodeIfPresent(LocalDate.self, forKey: .date),
            daysFromToday: try c.decodeIfPresent(Int.self, forKey: .daysFromToday),
            weekday: try c.decodeIfPresent(Weekday.self, forKey: .weekday),
            weekOffset: try c.decodeIfPresent(Int.self, forKey: .weekOffset),
            minutesFromNow: try c.decodeIfPresent(Int.self, forKey: .minutesFromNow),
            monthPart: try c.decodeIfPresent(MonthPart.self, forKey: .monthPart),
            monthOffset: try c.decodeIfPresent(Int.self, forKey: .monthOffset),
            time: (try c.decodeIfPresent(String.self, forKey: .time)).flatMap(LocalTime.lenient),
            dayPart: try c.decodeIfPresent(DayPart.self, forKey: .dayPart),
            approximate: try c.decodeIfPresent(Bool.self, forKey: .approximate)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(phrase, forKey: .phrase)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encodeIfPresent(daysFromToday, forKey: .daysFromToday)
        try c.encodeIfPresent(weekday, forKey: .weekday)
        try c.encodeIfPresent(weekOffset, forKey: .weekOffset)
        try c.encodeIfPresent(minutesFromNow, forKey: .minutesFromNow)
        try c.encodeIfPresent(monthPart, forKey: .monthPart)
        try c.encodeIfPresent(monthOffset, forKey: .monthOffset)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encodeIfPresent(dayPart, forKey: .dayPart)
        try c.encodeIfPresent(approximate, forKey: .approximate)
    }
}

extension LocalTime {
    /// Accepts "9:00", "09:00", "09:00:00" and a bare hour ("9"). Returns `nil` for anything else.
    public static func lenient(_ string: String) -> LocalTime? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let strict = LocalTime(trimmed) { return strict }
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 1:
            return Int(parts[0]).flatMap { LocalTime(hour: $0, minute: 0) }
        case 3:
            return LocalTime(parts[0] + ":" + parts[1])
        default:
            return nil
        }
    }
}

/// Default times for "morning/day/evening/night" when the user gives no exact time. Configurable in Settings.
public struct DayPartDefaults: Codable, Hashable, Sendable {
    public var morning: LocalTime
    public var day: LocalTime
    public var evening: LocalTime
    public var night: LocalTime
    /// When a reminder or task has a date but no time, it fires at this time.
    public var defaultReminder: LocalTime

    public init(morning: LocalTime, day: LocalTime, evening: LocalTime, night: LocalTime, defaultReminder: LocalTime) {
        self.morning = morning
        self.day = day
        self.evening = evening
        self.night = night
        self.defaultReminder = defaultReminder
    }

    public static let standard = DayPartDefaults(
        morning: LocalTime(hour: 9, minute: 0)!, day: LocalTime(hour: 13, minute: 0)!,
        evening: LocalTime(hour: 19, minute: 0)!, night: LocalTime(hour: 23, minute: 0)!,
        defaultReminder: LocalTime(hour: 9, minute: 0)!
    )

    public func time(for part: When.DayPart) -> LocalTime {
        switch part {
        case .morning: morning
        case .day: day
        case .evening: evening
        case .night: night
        }
    }
}
