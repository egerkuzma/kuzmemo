import Foundation
import Observation

/// One line about what an action on an entry did, and the journal entry that undoes it.
public struct ActionOutcome: Equatable, Sendable {
    public var op: Op?
    public var lines: [String]

    public init(op: Op?, lines: [String]) {
        self.op = op
        self.lines = lines
    }
}

/// A repeating item with its next occurrence, for the "Повторяющиеся" list.
public struct RecurringSeries: Identifiable, Equatable, Sendable {
    public var item: Item
    /// The next open occurrence within a year, if any.
    public var next: LocalDate?
    public var id: String { item.id }
}

/// What the calendar window shows and does: the selected day and the month around it, the Inbox, search and the
/// actions on entries. It has no UI in it so that it can be tested; the views only read it and call it.
@MainActor
@Observable
public final class CalendarModel {
    public enum Mode: String, CaseIterable, Sendable {
        case day, inbox, search, recurring
    }

    public private(set) var today: LocalDate
    public private(set) var selectedDate: LocalDate
    public private(set) var grid: MonthGrid
    public private(set) var markers: [LocalDate: DayMarker] = [:]
    public private(set) var dayEntries: [AgendaEntry] = []
    /// Open entries from before today; shown above today's list only while today is selected.
    public private(set) var overdueEntries: [AgendaEntry] = []
    public private(set) var inboxItems: [Item] = []
    public private(set) var failedMemos: [Memo] = []
    public private(set) var recurring: [RecurringSeries] = []
    public private(set) var searchResults: [Item] = []
    public private(set) var searchText = ""
    public var mode: Mode = .day

    /// Things that need the person in the Inbox: undated open items and memos that failed.
    public var inboxCount: Int { inboxItems.count + failedMemos.count }

    private let store: Store
    private let clock: any NowProvider
    private var reloadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var dayTimer: Task<Void, Never>?

    public init(store: Store, clock: any NowProvider = SystemNow()) {
        self.store = store
        self.clock = clock
        let now = clock.localNow().date
        today = now
        selectedDate = now
        grid = MonthGrid(containing: now)
    }

    // MARK: - Navigation

    public func select(_ date: LocalDate) {
        selectedDate = date
        mode = .day
        if !grid.isInMonth(date) { grid = MonthGrid(containing: date) }
        scheduleReload()
    }

    public func moveSelection(byDays days: Int) {
        select(selectedDate.adding(days: days))
    }

    /// Pages the month view; the selection keeps its day of the month (or the last day of a shorter month).
    public func moveMonth(by months: Int) {
        select(MonthGrid.date(selectedDate, movedBy: months))
    }

    public func goToToday() {
        today = clock.localNow().date
        select(today)
    }

    public func show(_ newMode: Mode) {
        mode = newMode
        scheduleReload()
    }

    /// Filters as the person types: the query runs shortly after the last keystroke.
    public func setSearchText(_ text: String) {
        searchText = text
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { mode = .search }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    // MARK: - Loading

    /// Reloads everything the window shows from the store.
    public func reload() async {
        today = clock.localNow().date
        let month = (try? await store.agenda(in: grid.range)) ?? []
        markers = CalendarSummary.markers(month)
        dayEntries = month.filter { $0.date == selectedDate }
        overdueEntries = selectedDate == today ? await loadOverdue() : []
        inboxItems = (try? await store.inbox()) ?? []
        failedMemos = (try? await store.failedMemos()) ?? []
        if mode == .recurring { recurring = await loadRecurring() }
        await runSearch()
    }

    /// Waits for the reload and the search that were scheduled (used by tests).
    public func settled() async {
        await reloadTask?.value
        await searchTask?.value
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.reload() }
    }

    private func loadOverdue() async -> [AgendaEntry] {
        let items = (try? await store.overdue(before: today, limit: 20)) ?? []
        return items.map { AgendaEntry(item: $0, date: $0.date ?? today, time: $0.time, isDone: false, occurrenceDate: nil, wasMoved: false) }
    }

    private func loadRecurring() async -> [RecurringSeries] {
        let series = (try? await store.recurringSeries()) ?? []
        let upcoming = (try? await store.agenda(in: today ... today.adding(days: 366), includeDone: false)) ?? []
        return series.map { item in
            RecurringSeries(item: item, next: upcoming.first { $0.item.id == item.id }?.date)
        }
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? [] : ((try? await store.search(query, limit: 100)) ?? [])
        searchResults = Self.ordered(found, today: today)
    }

    /// What is coming up first (from today on, soonest first), then what is past (latest first), then undated.
    static func ordered(_ items: [Item], today: LocalDate) -> [Item] {
        func rank(_ item: Item) -> Int {
            guard let date = item.date else { return 2 }
            return date >= today ? 0 : 1
        }
        return items.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            switch (lhs.date, rhs.date) {
            case let (l?, r?) where l != r: return rank(lhs) == 0 ? l < r : l > r
            default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    /// Keeps the window in step with the database, whoever changes it (voice, typing, the editor).
    public func startObserving() {
        guard observer == nil else { return }
        observer = Task { [weak self, store] in
            for await _ in store.changes() {
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
        dayTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.secondsUntilMidnight() + 1))
                await self.rolloverIfNeeded()
            }
        }
        scheduleReload()
    }

    public func stopObserving() {
        observer?.cancel(); observer = nil
        dayTimer?.cancel(); dayTimer = nil
    }

    /// The day changed while the window was open (or the Mac slept through midnight): move "today" along.
    public func rolloverIfNeeded() async {
        let now = clock.localNow().date
        guard now != today else { return }
        let followsToday = selectedDate == today
        today = now
        if followsToday { selectedDate = now }
        if !grid.isInMonth(selectedDate) { grid = MonthGrid(containing: selectedDate) }
        await reload()
    }

    private func secondsUntilMidnight() -> TimeInterval {
        let now = clock.localNow()
        return TimeInterval(24 * 3600 - now.time.minutesSinceMidnight * 60)
    }

    // MARK: - Actions on entries (each one is undoable through the returned op)

    /// Marks an entry done or open again; for a repeating item only that occurrence.
    @discardableResult
    public func toggleDone(_ entry: AgendaEntry) async throws -> ActionOutcome {
        let action: PlannedAction = entry.isDone
            ? .reopen(itemID: entry.item.id, occurrenceDate: entry.occurrenceDate)
            : .complete(itemID: entry.item.id, occurrenceDate: entry.occurrenceDate)
        return try await run(action, label: entry.isDone ? "Возврат записи" : "Запись выполнена")
    }

    /// Moves an entry to another day; for a repeating item only that occurrence (the series stays).
    @discardableResult
    public func move(_ entry: AgendaEntry, to date: LocalDate) async throws -> ActionOutcome {
        if let occurrence = entry.occurrenceDate {
            return try await run(
                .moveOccurrence(itemID: entry.item.id, occurrenceDate: occurrence, newDate: date, newTime: entry.time),
                label: "Перенос повторения"
            )
        }
        var changes = ItemChanges()
        changes.date = date
        return try await run(.update(itemID: entry.item.id, changes: changes), label: "Перенос записи")
    }

    @discardableResult
    public func moveToTomorrow(_ entry: AgendaEntry) async throws -> ActionOutcome {
        try await move(entry, to: today.adding(days: 1))
    }

    /// Leaves one occurrence of a repeating item out.
    @discardableResult
    public func skip(_ entry: AgendaEntry) async throws -> ActionOutcome {
        guard let occurrence = entry.occurrenceDate else { return ActionOutcome(op: nil, lines: []) }
        return try await run(.skipOccurrence(itemID: entry.item.id, occurrenceDate: occurrence), label: "Пропуск повторения")
    }

    /// Deletes the item (all of a series).
    @discardableResult
    public func delete(_ item: Item) async throws -> ActionOutcome {
        try await run(.delete(itemID: item.id), label: "Удаление записи")
    }

    @discardableResult
    public func create(_ draft: ItemDraft) async throws -> ActionOutcome {
        let made = try await store.create(draft)
        return ActionOutcome(op: made.op, lines: ["Создано · «\(made.item.title)»"])
    }

    @discardableResult
    public func save(_ draft: ItemDraft, as itemID: String) async throws -> ActionOutcome {
        let op = try await store.save(draft, as: itemID)
        return ActionOutcome(op: op, lines: ["Сохранено · «\(draft.title.trimmingCharacters(in: .whitespacesAndNewlines))»"])
    }

    /// The quick-add field without Claude: a task on the selected day, or in the Inbox when that is shown.
    @discardableResult
    public func quickAdd(_ text: String) async throws -> ActionOutcome {
        try await create(ItemDraft(kind: .task, title: text, date: mode == .day ? selectedDate : nil))
    }

    private func run(_ action: PlannedAction, label: String) async throws -> ActionOutcome {
        let result = try await store.perform(action, label: label)
        return ActionOutcome(op: result.op, lines: result.changes.map { $0.summary(today: today) })
    }
}
