import GRDB

/// A wall-clock time of day without a time zone, written `HH:MM` (24-hour).
public struct LocalTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Parses `HH:MM` (also accepts `H:MM`).
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    public init(minutesSinceMidnight: Int) {
        let clamped = min(max(minutesSinceMidnight, 0), 24 * 60 - 1)
        self.hour = clamped / 60
        self.minute = clamped % 60
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public var description: String {
        (hour < 10 ? "0" : "") + String(hour) + ":" + (minute < 10 ? "0" : "") + String(minute)
    }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

extension LocalTime: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = LocalTime(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid time '\(string)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension LocalTime: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalTime? {
        String.fromDatabaseValue(dbValue).flatMap(LocalTime.init)
    }
}
