import GRDB

/// One line of the calendar: a one-off item or a single occurrence of a recurring one.
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
    /// items, all-day entries first within a day. Skipped occurrences are left out.
    public func agenda(in range: ClosedRange<LocalDate>, includeDone: Bool = true) async throws -> [AgendaEntry] {
        let oneOffs = try await items(in: range)
        let series = try await recurringSeries().filter { ($0.date ?? range.upperBound) <= range.upperBound }
        let exceptions = try await exceptions(for: series.map(\.id))

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
