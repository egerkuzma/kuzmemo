/// Whether a snoozed alert still has something to say. The person chose "snooze", and before it rang again the entry was ticked
/// off, skipped or deleted: ringing then is noise.
public enum SnoozedAlert {
    /// `item` is `nil` when the entry no longer exists. `occurrence` is the rule date the alert was for (a repeating entry's
    /// occurrences are ticked off one by one, in `exceptions`; the entry itself stays open for ever).
    public static func isStale(item: Item?, occurrence: LocalDate?, exceptions: [ItemException]) -> Bool {
        guard let item, item.deletedAt == nil else { return true }
        guard item.recurrence != nil else { return item.status == .done }
        guard let occurrence,
              let override = exceptions.first(where: { $0.itemID == item.id && $0.occDate == occurrence }) else { return false }
        return override.action == .done || override.action == .skip
    }
}
