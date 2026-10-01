import Foundation

/// A date plus a wall-clock time, both without a time zone.
public struct LocalDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let date: LocalDate
    public let time: LocalTime

    public init(date: LocalDate, time: LocalTime) {
        self.date = date
        self.time = time
    }

    /// Minutes since 1970-01-01 00:00 of this wall-clock reading.
    public var epochMinutes: Int { date.epochDay * 1440 + time.minutesSinceMidnight }

    /// Out-of-range readings saturate at the first and the last minute a `LocalDate` can hold.
    public init(epochMinutes: Int) {
        let first = LocalDate.earliest.epochDay * 1440, last = LocalDate.latest.epochDay * 1440 + 1439
        let minutes = min(max(epochMinutes, first), last)
        let day = Int((Double(minutes) / 1440).rounded(.down))
        self.date = LocalDate(epochDay: day)
        self.time = LocalTime(minutesSinceMidnight: minutes - day * 1440)
    }

    public func adding(minutes: Int) -> LocalDateTime {
        let (sum, overflow) = epochMinutes.addingReportingOverflow(minutes)
        return LocalDateTime(epochMinutes: overflow ? (minutes > 0 ? Int.max : Int.min) : sum)
    }

    public var description: String { "\(date) \(time)" }

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool { lhs.epochMinutes < rhs.epochMinutes }
}
