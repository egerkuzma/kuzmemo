import GRDB

/// One line of the calendar: a one-off item or a single occurrence of a recurring one.
extension AgendaEntry {
    /// Whether the entry's moment is behind `now`: it is on an earlier day, or it is today with a time whose end (the
    /// time plus the duration, when there is one) has gone by. An all-day entry does not pass during its day.
    public func hasPassed(at now: LocalDateTime) -> Bool {
        if date < now.date { return true }
        guard date == now.date, let time else { return false }
        let end = time.hour * 60 + time.minute + max(item.durationMin ?? 0, 0)
        return end <= now.time.hour * 60 + now.time.minute
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

    public init(item: Item, date: LocalDate, time: LocalTime?, isDone: Bool, occurrenceDate: LocalDate?, wasMoved: Bool) {
        self.item = item
        self.date = date
        self.time = time
        self.isDone = isDone
        self.occurrenceDate = occurrenceDate
        self.wasMoved = wasMoved
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
        try await writer.read { db in try Store.agenda(db, in: range, includeDone: includeDone) }
    }

    static func agenda(_ db: Database, in range: ClosedRange<LocalDate>, includeDone: Bool = true) throws -> [AgendaEntry] {
        let oneOffs = try items(db, in: range)
        let allSeries = try recurringSeries(db)
        let exceptions = try exceptions(db, for: allSeries.map(\.id))
        // A series that starts after the range has nothing in it, unless one of its occurrences was moved back into it (to a
        // day before the series' own start): those moves are looked at before the series is passed over.
        let movedIn = Set(exceptions.filter { $0.movedDate.map(range.contains) == true }.map(\.itemID))
        let series = allSeries.filter { ($0.date ?? range.upperBound) <= range.upperBound || movedIn.contains($0.id) }

        var entries: [AgendaEntry] = oneOffs.compactMap { item in
            guard let date = item.date else { return nil }
            return AgendaEntry(
                item: item, date: date, time: item.time, isDone: item.status == .done,
                occurrenceDate: nil, wasMoved: false
            )
        }
        for item in series {
            let expanded = RecurrenceExpander.occurrences(
                of: item, from: range.lowerBound, through: range.upperBound, exceptions: exceptions
            )
            for occurrence in expanded where occurrence.state != .skipped {
                entries.append(AgendaEntry(
                    item: item, date: occurrence.date, time: occurrence.time, isDone: occurrence.state == .done,
                    occurrenceDate: occurrence.originalDate, wasMoved: occurrence.wasMoved
                ))
            }
        }
        if !includeDone { entries.removeAll { $0.isDone } }
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
