import Foundation
import GRDB

/// One line of the calendar: a one-off item or a single occurrence of a recurring one.
extension AgendaEntry {
    /// Whether the entry's moment is behind `now`: it is on an earlier day, or it is today with a time whose end (the
    /// time plus the duration, when there is one) has gone by. An all-day entry does not pass during its day.
    public func hasPassed(at now: LocalDateTime, timeZone: TimeZone = .current, instant: Date? = nil) -> Bool {
        if date < now.date { return true }
        guard date == now.date, let time else { return false }
        let start = scheduledAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            ?? LocalDateTime(date: date, time: time).instant(in: timeZone)
        let end = start.addingTimeInterval(TimeInterval(max(item.durationMin ?? 0, 0)) * 60)
        return end <= (instant ?? now.instant(in: timeZone))
    }
}

public struct AgendaEntry: Hashable, Sendable, Identifiable {
    public var item: Item
    public var date: LocalDate
    /// `nil` means all-day / date-only.
    public var time: LocalTime?
    public var isDone: Bool
    /// The rule date of a recurring occurrence (the key of its overrides); `nil` for one-off items.
    public var occurrenceDate: LocalDate?
    public var wasMoved: Bool
    public var scheduledAt: Int64?

    public init(item: Item, date: LocalDate, time: LocalTime?, isDone: Bool, occurrenceDate: LocalDate?, wasMoved: Bool, scheduledAt: Int64? = nil) {
        self.item = item
        self.date = date
        self.time = time
        self.isDone = isDone
        self.occurrenceDate = occurrenceDate
        self.wasMoved = wasMoved
        self.scheduledAt = scheduledAt
    }

    public var isRecurring: Bool { occurrenceDate != nil }
    public var id: String { occurrenceDate.map { "\(item.id)@\($0)" } ?? item.id }
}

extension Store {
    /// Everything on the calendar within `range`: one-off items plus expanded occurrences of recurring
    /// items, all-day entries first within a day. Skipped occurrences are left out. One snapshot: the one-offs, the series
    /// and their overrides are read in a single transaction, so a write landing between them cannot show an entry twice,
    /// not at all, or with an override that belongs to another state of the series.
    public func agenda(in range: ClosedRange<LocalDate>, includeDone: Bool = true) async throws -> [AgendaEntry] {
        try await writer.read { db in try Store.agenda(db, in: range, includeDone: includeDone, timeZone: self.clock.timeZone) }
    }

    static func agenda(_ db: Database, in range: ClosedRange<LocalDate>, includeDone: Bool = true, timeZone: TimeZone = .current) throws -> [AgendaEntry] {
        // An elapsed-time entry may cross a date boundary when the device's time zone changes.
        let rawRange = range.lowerBound.adding(days: -2)...range.upperBound.adding(days: 2)
        let oneOffs = try items(db, in: rawRange)
        let allSeries = try recurringSeries(db)
        let exceptions = try exceptions(db, for: allSeries.map(\.id))
        // A series that starts after the range has nothing in it, unless one of its occurrences was moved back into it (to a
        // day before the series' own start): those moves are looked at before the series is passed over.
        let movedIn = Set(exceptions.filter { $0.movedDate.map(rawRange.contains) == true }.map(\.itemID))
        let series = allSeries.filter { ($0.date ?? rawRange.upperBound) <= rawRange.upperBound || movedIn.contains($0.id) }

        var entries: [AgendaEntry] = oneOffs.compactMap { item in
            let shown = item.shown(in: timeZone)
            guard let date = shown.date else { return nil }
            return AgendaEntry(
                item: shown, date: date, time: shown.time, isDone: item.status == .done,
                occurrenceDate: nil, wasMoved: false, scheduledAt: item.scheduledAt
            )
        }
        for item in series {
            let expanded = RecurrenceExpander.occurrences(
                of: item, from: rawRange.lowerBound, through: rawRange.upperBound, exceptions: exceptions
            )
            for occurrence in expanded where occurrence.state != .skipped {
                let stamp = occurrence.scheduledAt ?? (!occurrence.wasMoved && occurrence.originalDate == item.date ? item.scheduledAt : nil)
                let moment = stamp.map { LocalDateTime(date: Date(timeIntervalSince1970: TimeInterval($0) / 1000), in: timeZone) }
                entries.append(AgendaEntry(item: item, date: moment?.date ?? occurrence.date, time: moment?.time ?? occurrence.time,
                                          isDone: occurrence.state == .done, occurrenceDate: occurrence.originalDate,
                                          wasMoved: occurrence.wasMoved, scheduledAt: stamp))
            }
        }
        entries.removeAll { !range.contains($0.date) || (!includeDone && $0.isDone) }
        return entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            let lt = $0.time?.minutesSinceMidnight ?? -1
            let rt = $1.time?.minutesSinceMidnight ?? -1
            if lt != rt { return lt < rt }
            return $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
        }
    }

    public func agenda(on date: LocalDate, includeDone: Bool = true) async throws -> [AgendaEntry] {
        try await agenda(in: date...date, includeDone: includeDone)
    }
}
