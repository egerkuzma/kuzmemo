/// The days a month view shows: whole weeks, Monday first, always six rows so the grid keeps its height when
/// the person pages between months.
public struct MonthGrid: Equatable, Sendable {
    /// The first day of the month being shown.
    public let month: LocalDate
    public let weeks: [[LocalDate]]

    public init(containing date: LocalDate) {
        let first = date.firstOfMonth
        let start = first.startOfWeek
        month = first
        weeks = (0 ..< 6).map { row in (0 ..< 7).map { column in start.adding(days: row * 7 + column) } }
    }

    public var days: [LocalDate] { weeks.flatMap { $0 } }

    /// Everything on screen, including the neighbouring months' days that fill the first and last rows.
    public var range: ClosedRange<LocalDate> { weeks[0][0] ... weeks[5][6] }

    public func isInMonth(_ date: LocalDate) -> Bool { date.year == month.year && date.month == month.month }

    public func adding(months: Int) -> MonthGrid { MonthGrid(containing: month.adding(months: months)) }

    /// The date to select after paging by `months`: the same day of the month, or the last day when it is shorter.
    public static func date(_ date: LocalDate, movedBy months: Int) -> LocalDate {
        let target = date.firstOfMonth.adding(months: months)
        return LocalDate(year: target.year, month: target.month, day: min(date.day, target.daysInMonth))!
    }
}

/// What a day cell shows about the day.
public struct DayMarker: Equatable, Sendable {
    /// Entries still to do, repeating ones included.
    public var open = 0
    public var done = 0
    /// How many of the open entries are occurrences of a repeating item.
    public var openRecurring = 0
    public var hasRecurring = false

    public var total: Int { open + done }
    /// Open entries that are one-off: what the month view marks with a coloured dot.
    public var openOneOff: Int { open - openRecurring }

    public init(open: Int = 0, done: Int = 0, openRecurring: Int = 0, hasRecurring: Bool = false) {
        self.open = open
        self.done = done
        self.openRecurring = openRecurring
        self.hasRecurring = hasRecurring
    }
}

public enum CalendarSummary {
    /// Counts per day for the month grid's dots and badges.
    public static func markers(_ entries: [AgendaEntry]) -> [LocalDate: DayMarker] {
        var result: [LocalDate: DayMarker] = [:]
        for entry in entries {
            var marker = result[entry.date] ?? DayMarker()
            if entry.isDone { marker.done += 1 } else { marker.open += 1 }
            if entry.isRecurring {
                marker.hasRecurring = true
                if !entry.isDone { marker.openRecurring += 1 }
            }
            result[entry.date] = marker
        }
        return result
    }
}
