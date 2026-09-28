/// One change that was actually made, for the confirmation toast and the log.
public struct AppliedChange: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case created, updated, moved, completed, reopened, deleted, skipped
    }

    public var kind: Kind
    /// The item after the change (for a deletion: the item that was deleted).
    public var item: Item
    public var occurrenceDate: LocalDate?
    /// For `.moved`: where the occurrence went.
    public var newDate: LocalDate?
    public var newTime: LocalTime?
}

public struct ApplyResult: Equatable, Sendable {
    /// The journal entry; pass its id to `Store.undo`. `nil` when nothing changed.
    public var op: Op?
    public var changes: [AppliedChange]
}

extension Store {
    /// Applies a validated plan in a single transaction (all or nothing) and journals it for Undo.
    public func apply(_ plan: MutationPlan, source: ItemSource, memoID: String?, label: String) async throws -> ApplyResult {
        let actions = plan.actions
        let result = try await performReturning(label: label, memoID: memoID) { mutator -> [AppliedChange] in
            var applied: [AppliedChange] = []
            for action in actions {
                switch action {
                case let .create(new):
                    let item = Item(
                        id: "", kind: new.kind, title: new.title, details: new.details, keywords: new.keywords,
                        date: new.date, time: new.time, durationMin: new.durationMin, approximate: new.approximate,
                        recurrence: new.recurrence, source: source, memoID: memoID
                    )
                    applied.append(AppliedChange(kind: .created, item: try mutator.insert(item)))

                case let .update(id, changes):
                    let saved = try mutator.update(id: id) { changes.apply(to: &$0) }
                    applied.append(AppliedChange(kind: .updated, item: saved))

                case let .moveOccurrence(id, occurrence, newDate, newTime):
                    guard let item = try mutator.item(id: id) else { throw StoreError.itemNotFound(id) }
                    try mutator.setException(ItemException(
                        itemID: id, occDate: occurrence, action: .moved, movedDate: newDate, movedTime: newTime
                    ))
                    applied.append(AppliedChange(
                        kind: .moved, item: item, occurrenceDate: occurrence, newDate: newDate, newTime: newTime
                    ))

                case let .complete(id, occurrence):
                    if let occurrence {
                        guard let item = try mutator.item(id: id) else { throw StoreError.itemNotFound(id) }
                        try mutator.setException(ItemException(itemID: id, occDate: occurrence, action: .done))
                        applied.append(AppliedChange(kind: .completed, item: item, occurrenceDate: occurrence))
                    } else {
                        let stamp = mutator.nowMs
                        let saved = try mutator.update(id: id) { $0.status = .done; $0.doneAt = stamp }
                        applied.append(AppliedChange(kind: .completed, item: saved))
                    }

                case let .reopen(id, occurrence):
                    if let occurrence {
                        guard let item = try mutator.item(id: id) else { throw StoreError.itemNotFound(id) }
                        try mutator.removeException(itemID: id, occDate: occurrence)
                        applied.append(AppliedChange(kind: .reopened, item: item, occurrenceDate: occurrence))
                    } else {
                        let saved = try mutator.update(id: id) { $0.status = .open; $0.doneAt = nil }
                        applied.append(AppliedChange(kind: .reopened, item: saved))
                    }

                case let .delete(id):
                    applied.append(AppliedChange(kind: .deleted, item: try mutator.softDelete(id: id)))

                case let .skipOccurrence(id, occurrence):
                    guard let item = try mutator.item(id: id) else { throw StoreError.itemNotFound(id) }
                    try mutator.setException(ItemException(itemID: id, occDate: occurrence, action: .skip))
                    applied.append(AppliedChange(kind: .skipped, item: item, occurrenceDate: occurrence))
                }
            }
            return applied
        }
        return ApplyResult(op: result.op, changes: result.value)
    }
}
