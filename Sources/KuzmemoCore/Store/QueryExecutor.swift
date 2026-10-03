import Foundation
import GRDB

public struct QueryResult: Equatable, Sendable {
    public var plan: QueryPlan
    public var entries: [AgendaEntry]
    /// A label for headings in the current language, for example "today" or "from September 28 to October 4".
    public var title: String
    /// How many of today's timed entries were left out because their time has gone by: "what's on today" is about what
    /// is still ahead, so a reminder from this morning is not read out at five in the afternoon.
    public var passedToday = 0
}

extension Store {
    /// A stream that yields whenever calendar rows (items, per-occurrence overrides) or memos change, so views can
    /// reload. The first value arrives immediately. A read that fails ends GRDB's observation, and a stream that ended with
    /// it would leave every window frozen on what it last showed until the app was restarted: the observation is started
    /// again after a pause (doubling up to half a minute), and its first value makes the views read afresh.
    public func changes(retryAfter: Duration = .seconds(1)) -> AsyncStream<Void> {
        let writer = self.writer
        return AsyncStream { continuation in
            let task = Task {
                var pause = retryAfter
                while !Task.isCancelled {
                    let observation = ValueObservation.tracking { db -> Int in
                        try Item.fetchCount(db) + ItemException.fetchCount(db) + Memo.fetchCount(db)
                    }
                    do {
                        for try await _ in observation.values(in: writer) {
                            continuation.yield()
                            pause = retryAfter
                        }
                        break // the database was closed: nothing more will change
                    } catch is CancellationError {
                        break
                    } catch {
                        try? await Task.sleep(for: pause)
                        pause = min(pause * 2, .seconds(30))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a validated query against the calendar.
    public func run(_ plan: QueryPlan, now: LocalDateTime) async throws -> QueryResult {
        let today = now.date
        let current = clock.now()
        let instant = LocalDateTime(date: current, in: clock.timeZone) == now ? current : now.instant(in: clock.timeZone)
        switch plan.target {
        case let .days(range):
            var entries = try await agenda(in: range, includeDone: plan.includeDone)
            var passed = 0
            if !plan.includeDone, range.contains(today) { // asking for the whole day (with done ones) keeps what has passed
                let before = entries.count
                entries.removeAll { $0.date == today && $0.hasPassed(at: now, timeZone: clock.timeZone, instant: instant) }
                passed = before - entries.count
            }
            return QueryResult(plan: plan, entries: entries, title: Self.title(for: range, today: today), passedToday: passed)

        case let .upcoming(limit):
            let entries = try await agenda(in: today ... today.adding(days: 60), includeDone: false)
                .filter { entry in
                    if let stamp = entry.scheduledAt { return Date(timeIntervalSince1970: TimeInterval(stamp) / 1000) >= instant }
                    return entry.date > today || (entry.date == today && (entry.time.map { $0 >= now.time } ?? true))
                }
            return QueryResult(plan: plan, entries: Array(entries.prefix(limit)), title: tr("upcoming"))

        case .overdue:
            let items = try await overdue(before: today, limit: 20)
            return QueryResult(plan: plan, entries: items.map { Self.entry($0, today: today) }, title: tr("overdue"))

        case .inbox:
            return QueryResult(plan: plan, entries: try await inbox().map { Self.entry($0, today: today) }, title: tr("no date"))

        case .recurring:
            return QueryResult(plan: plan, entries: try await recurringSeries().map { Self.entry($0, today: today) }, title: tr("repeating"))

        case let .search(text):
            var seen = Set<String>()
            var items: [Item] = []
            for variant in try await searchVariants(text) {
                for item in try await search(variant, limit: 20) where seen.insert(item.id).inserted { items.append(item) }
            }
            return QueryResult(plan: plan, entries: items.map { Self.entry($0.shown(in: clock.timeZone), today: today) }, title: Wording.quoted(text))
        }
    }

    /// The query itself plus the glossary spellings of any term it mentions ("Acme" ↔ "акме"),
    /// so a search finds entries typed in either script.
    func searchVariants(_ text: String) async throws -> [String] {
        let words = Set(SearchText.tokens(text))
        var variants = [text]
        for term in try await glossary() where term.enabled {
            let names = [term.canonical] + term.aliases
            let normalized = names.map { SearchText.normalize($0) }
            if normalized.contains(where: { name in words.contains(name) || SearchText.normalize(text).contains(name) }) {
                variants += names.filter { !variants.contains($0) }
            }
        }
        return variants
    }

    static func entry(_ item: Item, today: LocalDate) -> AgendaEntry {
        AgendaEntry(
            item: item, date: item.date ?? today, time: item.time, isDone: item.status == .done,
            occurrenceDate: nil, wasMoved: false, scheduledAt: item.scheduledAt
        )
    }

    static func title(for range: ClosedRange<LocalDate>, today: LocalDate) -> String {
        if range.lowerBound == range.upperBound { return Wording.relativeDay(range.lowerBound, today: today) }
        return tr("from %1$@ to %2$@", Wording.date(range.lowerBound), Wording.date(range.upperBound))
    }
}

public struct StoreCounts: Equatable, Sendable {
    public var items: Int
    public var memos: Int
    public var ops: Int
    public var unfinishedMemos: Int
}

extension Store {
    public func counts() async throws -> StoreCounts {
        try await writer.read { db in
            StoreCounts(
                items: try Item.filter(Column("deleted_at") == nil).fetchCount(db),
                memos: try Memo.fetchCount(db),
                ops: try Op.fetchCount(db),
                unfinishedMemos: try Memo.filter(!["applied", "answered", "discarded"].contains(Column("status"))).fetchCount(db)
            )
        }
    }

    /// Removes every item, memo and journal entry (the glossary stays). For the dev bundle's test resets only.
    public func eraseAllData() async throws {
        try await wipeContent { _ in () }
    }
}
