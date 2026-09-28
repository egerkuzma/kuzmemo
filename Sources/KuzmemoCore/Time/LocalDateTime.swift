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

    public init(epochMinutes: Int) {
        let day = Int((Double(epochMinutes) / 1440).rounded(.down))
        self.date = LocalDate(epochDay: day)
        self.time = LocalTime(minutesSinceMidnight: epochMinutes - day * 1440)
    }

    public func adding(minutes: Int) -> LocalDateTime { LocalDateTime(epochMinutes: epochMinutes + minutes) }

    public var description: String { "\(date) \(time)" }

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool { lhs.epochMinutes < rhs.epochMinutes }
}
