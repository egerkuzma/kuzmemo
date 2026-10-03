import Foundation

/// The source of "now" for everything that depends on the current moment. Injected so tests and
/// the control channel can pin the clock to a fixed anchor.
public protocol NowProvider: Sendable {
    func now() -> Date
    var timeZone: TimeZone { get }
}

extension NowProvider {
    /// Current wall-clock reading in `timeZone`.
    public func localNow() -> LocalDateTime { LocalDateTime(date: now(), in: timeZone) }
}

public struct SystemNow: NowProvider {
    public init() {}
    public func now() -> Date { Date() }
    public var timeZone: TimeZone { TimeZone.autoupdatingCurrent }
}

public struct FixedNow: NowProvider {
    private let instant: Date
    public let timeZone: TimeZone

    public init(_ instant: Date, timeZone: TimeZone) {
        self.instant = instant
        self.timeZone = timeZone
    }

    /// Builds a fixed clock from a local wall-clock reading, e.g. `FixedNow(local: "2026-09-28 14:30", in: moscow)`.
    public init?(local: String, in timeZone: TimeZone) {
        let parts = local.split(separator: " ")
        guard parts.count == 2, let date = LocalDate(String(parts[0])), let time = LocalTime(String(parts[1])) else { return nil }
        self.init(LocalDateTime(date: date, time: time).instant(in: timeZone), timeZone: timeZone)
    }

    public func now() -> Date { instant }
}

extension LocalDateTime {
    /// Reads the wall clock of `instant` in `timeZone`.
    public init(date instant: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        self.init(
            date: LocalDate(year: c.year!, month: c.month!, day: c.day!)!,
            time: LocalTime(hour: c.hour!, minute: c.minute!)!
        )
    }

    /// The instant at which `timeZone`'s wall clock shows this reading (first match on DST folds).
    public func instant(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: date.year, month: date.month, day: date.day, hour: time.hour, minute: time.minute
        )
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: TimeInterval(epochMinutes * 60))
    }
}
