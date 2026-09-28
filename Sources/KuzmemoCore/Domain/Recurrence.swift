/// A repeat rule stored as JSON in `items.recurrence_json` and produced by the Claude response schema.
public struct Recurrence: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly
    }

    public var freq: Frequency
    /// Repeat every `interval` days/weeks/months/years. Always at least 1.
    public var interval: Int
    /// Weekly rules: the weekdays on which the item occurs. `nil` means the weekday of the start date.
    public var byWeekday: [Weekday]?
    /// Monthly rules: the day of month. `nil` means the day of the start date. Clamped to the month length.
    public var byMonthday: Int?
    /// Last date (inclusive) on which the series may occur.
    public var until: LocalDate?
    /// Total number of occurrences including the first one.
    public var count: Int?

    public init(
        freq: Frequency, interval: Int = 1, byWeekday: [Weekday]? = nil,
        byMonthday: Int? = nil, until: LocalDate? = nil, count: Int? = nil
    ) {
        self.freq = freq
        self.interval = max(1, interval)
        self.byWeekday = byWeekday
        self.byMonthday = byMonthday
        self.until = until
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case freq, interval
        case byWeekday = "by_weekday"
        case byMonthday = "by_monthday"
        case until, count
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            freq: try c.decode(Frequency.self, forKey: .freq),
            interval: try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1,
            byWeekday: try c.decodeIfPresent([Weekday].self, forKey: .byWeekday),
            byMonthday: try c.decodeIfPresent(Int.self, forKey: .byMonthday),
            until: try c.decodeIfPresent(LocalDate.self, forKey: .until),
            count: try c.decodeIfPresent(Int.self, forKey: .count)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(freq, forKey: .freq)
        try c.encode(interval, forKey: .interval)
        try c.encodeIfPresent(byWeekday, forKey: .byWeekday)
        try c.encodeIfPresent(byMonthday, forKey: .byMonthday)
        try c.encodeIfPresent(until, forKey: .until)
        try c.encodeIfPresent(count, forKey: .count)
    }
}

extension Recurrence {
    /// The rule with everything clamped to sane values: interval 1...99, at most 1000 occurrences, a valid day of
    /// month, unique sorted weekdays, and no end date before the start.
    public func normalized(start: LocalDate?) -> Recurrence {
        var rule = self
        rule.interval = min(max(rule.interval, 1), 99)
        if let count = rule.count { rule.count = count <= 0 ? nil : min(count, 1000) }
        if let day = rule.byMonthday, !(1 ... 31).contains(day) { rule.byMonthday = nil }
        if let days = rule.byWeekday { rule.byWeekday = days.isEmpty ? nil : Array(Set(days)).sorted() }
        if let until = rule.until, let start, until < start { rule.until = nil }
        return rule
    }
}
