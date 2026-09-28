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

    public init(date: LocalDate?, time: LocalTime?, approximate: Bool = false, issues: [Issue] = []) {
        self.date = date
        self.time = time
        self.approximate = approximate
        self.issues = issues
    }
}

/// Deterministic calendar arithmetic for the model's `When` descriptions, relative to the moment the
/// phrase was spoken (the anchor).
public struct RelativeDateResolver: Sendable {
    public let anchor: LocalDateTime
    public let dayParts: DayPartDefaults

    public init(anchor: LocalDateTime, dayParts: DayPartDefaults = .standard) {
        self.anchor = anchor
        self.dayParts = dayParts
    }

    public func resolve(_ when: When) -> ResolvedWhen {
        var date: LocalDate?
        var time = explicitTime(of: when)
        var approximate = when.approximate ?? false
        var issues: [ResolvedWhen.Issue] = []

        switch when.mode {
        case .none:
            break
        case .absolute:
            if let d = when.date { date = d } else { issues.append(.incomplete("date")) }
        case .daysFromToday:
            if let n = when.daysFromToday { date = anchor.date.adding(days: n) } else { issues.append(.incomplete("days_from_today")) }
        case .weekday:
            if let weekday = when.weekday {
                // `week_offset` counts calendar weeks (Monday first) from the current one. With 0 the weekday of
                // this week is used only while it is still ahead; today or a passed day rolls to next week.
                let offset = when.weekOffset ?? 0
                let inWeek = anchor.date.startOfWeek.adding(days: weekday.rawValue - 1 + 7 * offset)
                date = (offset == 0 && inWeek <= anchor.date) ? inWeek.adding(days: 7) : inWeek
            } else {
                issues.append(.incomplete("weekday"))
            }
        case .minutesFromNow:
            if let n = when.minutesFromNow {
                let moment = anchor.adding(minutes: n)
                date = moment.date
                time = moment.time
            } else {
                issues.append(.incomplete("minutes_from_now"))
            }
        case .monthPart:
            if let part = when.monthPart {
                let base = anchor.date.firstOfMonth.adding(months: when.monthOffset ?? 0)
                date = part == .start ? base : base.lastOfMonth
                if when.approximate == nil { approximate = true }
            } else {
                issues.append(.incomplete("month_part"))
            }
        }

        if let date, isPast(date: date, time: time) { issues.append(.inThePast) }
        return ResolvedWhen(date: date, time: time, approximate: approximate, issues: issues)
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
