import GRDB

/// A calendar date without a time zone ("floating" local date), written `YYYY-MM-DD`.
///
/// All calendar arithmetic uses the proleptic Gregorian calendar and days-since-epoch math, so it
/// never depends on `Calendar`, the locale or the device time zone.
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
              day <= LocalDate.daysInMonth(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD` strictly.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    // MARK: Epoch-day conversion (Howard Hinnant's civil-date algorithms)

    /// Days since 1970-01-01.
    public var epochDay: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The first and the last day a `LocalDate` can hold (years 1 to 9999: the stored form is `YYYY-MM-DD`).
    public static let earliest = LocalDate(year: 1, month: 1, day: 1)!
    public static let latest = LocalDate(year: 9999, month: 12, day: 31)!

    /// A day that is out of range (a model's or a transcript's huge number) saturates at the first or last valid day instead
    /// of becoming a date that cannot be written down or read back.
    public init(epochDay: Int) {
        let epochDay = min(max(epochDay, LocalDate.earliest.epochDay), LocalDate.latest.epochDay)
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.year = y
        self.month = m
        self.day = d
    }

    // MARK: Calendar facts

    public static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        default: isLeap(year) ? 29 : 28
        }
    }

    public var daysInMonth: Int { LocalDate.daysInMonth(year: year, month: month) }

    /// 1970-01-01 was a Thursday.
    public var weekday: Weekday {
        let index = ((epochDay + 3) % 7 + 7) % 7 // 0 = Monday
        return Weekday(rawValue: index + 1)!
    }

    public var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1)! }
    public var lastOfMonth: LocalDate { LocalDate(year: year, month: month, day: daysInMonth)! }

    // MARK: Arithmetic

    public func adding(days: Int) -> LocalDate {
        let (sum, overflow) = epochDay.addingReportingOverflow(days)
        return LocalDate(epochDay: overflow ? (days > 0 ? Int.max : Int.min) : sum)
    }

    /// Adds calendar months and clamps the day to the length of the target month (Jan 31 + 1 month = Feb 28/29).
    public func adding(months: Int) -> LocalDate {
        let total = year * 12 + (month - 1) + min(max(months, -120_000), 120_000)
        let newYear = Int((Double(total) / 12).rounded(.down))
        let newMonth = total - newYear * 12 + 1
        let clamped = min(day, LocalDate.daysInMonth(year: newYear, month: newMonth))
        return LocalDate(year: newYear, month: newMonth, day: clamped) ?? self
    }

    public func adding(years: Int) -> LocalDate { adding(months: years * 12) }

    /// Number of days from `self` to `other` (positive when `other` is later).
    public func days(until other: LocalDate) -> Int { other.epochDay - epochDay }

    /// Monday of the ISO week that contains this date.
    public var startOfWeek: LocalDate { adding(days: -(weekday.rawValue - 1)) }

    /// The first date strictly after `self` that falls on `weekday`.
    public func next(_ target: Weekday) -> LocalDate {
        var delta = target.rawValue - weekday.rawValue
        if delta <= 0 { delta += 7 }
        return adding(days: delta)
    }

    public var description: String {
        let y = String(year)
        return String(repeating: "0", count: max(0, 4 - y.count)) + y
            + "-" + (month < 10 ? "0" : "") + String(month)
            + "-" + (day < 10 ? "0" : "") + String(day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool { lhs.epochDay < rhs.epochDay }
}

extension LocalDate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = LocalDate(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date '\(string)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension LocalDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalDate? {
        String.fromDatabaseValue(dbValue).flatMap(LocalDate.init)
    }
}
