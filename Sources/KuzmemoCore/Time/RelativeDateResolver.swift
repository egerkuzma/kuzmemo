import Foundation

/// The result of turning a `When` into a concrete local date/time.
public struct ResolvedWhen: Equatable, Sendable {
    public enum Issue: Equatable, Sendable {
        /// The mode needs a field the model did not provide (for example `absolute` without `date`).
        case incomplete(String)
        /// The resolved moment is earlier than the anchor.
        case inThePast
    }

    public var date: LocalDate?
    /// `nil` means all-day / date-only.
    public var time: LocalTime?
    public var approximate: Bool
    public var issues: [Issue]
    /// Epoch milliseconds for elapsed-time requests; a wall-clock reading alone loses the second reading of a DST fold.
    public var scheduledAt: Int64?

    public init(date: LocalDate?, time: LocalTime?, approximate: Bool = false, issues: [Issue] = [], scheduledAt: Int64? = nil) {
        self.date = date
        self.time = time
        self.approximate = approximate
        self.issues = issues
        self.scheduledAt = scheduledAt
    }
}

/// Deterministic calendar arithmetic for the model's `When` descriptions, relative to the moment the
/// phrase was spoken (the anchor).
public struct RelativeDateResolver: Sendable {
    public let anchor: LocalDateTime
    public let dayParts: DayPartDefaults
    public let timeZone: TimeZone
    public let anchorInstant: Date?

    public init(anchor: LocalDateTime, dayParts: DayPartDefaults = .standard, timeZone: TimeZone = .current, anchorInstant: Date? = nil) {
        self.anchor = anchor
        self.dayParts = dayParts
        self.timeZone = timeZone
        self.anchorInstant = anchorInstant
    }

    /// The model's numbers are not trusted: a date further from today than a person plans (a hundred years) is read as
    /// "no usable date", which makes the app ask, instead of being computed (an overflow, or a year that cannot be stored).
    static let maxDays = 36_500
    static let maxWeeks = 5_200
    static let maxMonths = 1_200
    static let maxMinutes = 52_560_000

    public func resolve(_ when: When) -> ResolvedWhen {
        var date: LocalDate?
        var time = explicitTime(of: when)
        var approximate = when.approximate ?? false
        var issues: [ResolvedWhen.Issue] = []
        var scheduledAt: Int64?

        switch when.mode {
        case .none:
            break
        case .absolute:
            if let d = when.date { date = d } else { issues.append(.incomplete("date")) }
        case .daysFromToday:
            if let n = when.daysFromToday, (-Self.maxDays ... Self.maxDays).contains(n) {
                date = anchor.date.adding(days: n)
            } else {
                issues.append(.incomplete("days_from_today"))
            }
        case .weekday:
            if let weekday = when.weekday, (-Self.maxWeeks ... Self.maxWeeks).contains(when.weekOffset ?? 0) {
                // `week_offset` counts calendar weeks (Monday first) from the current one. With 0 the weekday of
                // this week is used only while it is still ahead; today or a passed day rolls to next week.
                let offset = when.weekOffset ?? 0
                let inWeek = anchor.date.startOfWeek.adding(days: weekday.rawValue - 1 + 7 * offset)
                date = (offset == 0 && inWeek <= anchor.date) ? inWeek.adding(days: 7) : inWeek
            } else {
                issues.append(.incomplete(when.weekday == nil ? "weekday" : "week_offset"))
            }
        case .minutesFromNow:
            if let n = when.minutesFromNow, (-Self.maxMinutes ... Self.maxMinutes).contains(n) {
                let instant = (anchorInstant ?? anchor.instant(in: timeZone)).addingTimeInterval(TimeInterval(n) * 60)
                let moment = LocalDateTime(date: instant, in: timeZone)
                scheduledAt = Int64(instant.timeIntervalSince1970 * 1000)
                date = moment.date
                time = moment.time
            } else {
                issues.append(.incomplete("minutes_from_now"))
            }
        case .monthPart:
            if let part = when.monthPart, (-Self.maxMonths ... Self.maxMonths).contains(when.monthOffset ?? 0) {
                let base = anchor.date.firstOfMonth.adding(months: when.monthOffset ?? 0)
                date = part == .start ? base : base.lastOfMonth
                if when.approximate == nil { approximate = true }
            } else {
                issues.append(.incomplete(when.monthPart == nil ? "month_part" : "month_offset"))
            }
        }

        // "This evening" said at 20:00 is not a moment in the past: the default hour of the part (19:00) has gone, the part
        // has not. Such a reminder is set for a little later in the part instead of asking for another date.
        if when.mode != .minutesFromNow, let date, date == anchor.date, when.time == nil, let part = when.dayPart, let current = time, current < anchor.time,
           let later = laterInThePart(part) {
            time = later
        }

        // On a DST fold a future instant can have an earlier wall-clock time. Durations are judged by their sign.
        if when.mode == .minutesFromNow {
            if let n = when.minutesFromNow, n < 0, date != nil { issues.append(.inThePast) }
        } else if let date, isPast(date: date, time: time) {
            issues.append(.inThePast)
        }
        return ResolvedWhen(date: date, time: time, approximate: approximate, issues: issues, scheduledAt: scheduledAt)
    }

    /// A time inside the part of the day that is going on now (an hour from now, on a quarter, not past the part's end),
    /// or `nil` when the part is over (or has no fixed end, like the night).
    private func laterInThePart(_ part: When.DayPart) -> LocalTime? {
        let end: Int
        switch part {
        case .morning: end = 12 * 60
        case .day: end = 17 * 60
        case .evening: end = 23 * 60
        case .night: return nil
        }
        let now = anchor.time.minutesSinceMidnight
        guard now < end else { return nil }
        return LocalTime(minutesSinceMidnight: min((now + 60 + 14) / 15 * 15, end))
    }

    private func explicitTime(of when: When) -> LocalTime? {
        if let time = when.time { return time }
        if let part = when.dayPart { return dayParts.time(for: part) }
        return nil
    }

    /// Whether `date` (with `time`, if any) is already behind the anchor. All-day today is not past.
    func isPast(date: LocalDate, time: LocalTime?) -> Bool {
        if date < anchor.date { return true }
        if date == anchor.date, let time { return time < anchor.time }
        return false
    }
}
