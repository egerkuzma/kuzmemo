/// The repeat section of the editor as plain fields, and the conversion to and from a `Recurrence`. Keeping this
/// apart from the views makes the mapping testable.
public struct RecurrenceForm: Equatable, Sendable {
    public enum Repeat: String, CaseIterable, Sendable {
        case none, daily, weekly, monthly, yearly

        /// Text for a picker.
        public var title: String {
            switch self {
            case .none: tr("Does not repeat")
            case .daily: tr("Every day")
            case .weekly: tr("Every week")
            case .monthly: tr("Every month")
            case .yearly: tr("Every year")
            }
        }

        var frequency: Recurrence.Frequency? {
            switch self {
            case .none: nil
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
        }
    }

    public enum End: Equatable, Sendable {
        case never
        case until(LocalDate)
        case count(Int)
    }

    public var repeatKind: Repeat = .none
    public var interval = 1
    /// Weekly: the weekdays; empty means "the weekday of the start date".
    public var weekdays: Set<Weekday> = []
    /// Monthly: the day of the month; `nil` means "the day of the start date".
    public var monthday: Int?
    public var end: End = .never

    public init() {}

    public init(_ rule: Recurrence?) {
        guard let rule else { return }
        switch rule.freq {
        case .daily: repeatKind = .daily
        case .weekly: repeatKind = .weekly
        case .monthly: repeatKind = .monthly
        case .yearly: repeatKind = .yearly
        }
        interval = rule.interval
        weekdays = Set(rule.byWeekday ?? [])
        monthday = rule.byMonthday
        if let until = rule.until { end = .until(until) } else if let count = rule.count { end = .count(count) }
    }

    /// The rule for these fields, or `nil` when the item does not repeat. Fields that do not apply to the chosen
    /// frequency are left out.
    public func rule(startingOn start: LocalDate?) -> Recurrence? {
        guard let frequency = repeatKind.frequency else { return nil }
        var rule = Recurrence(freq: frequency, interval: interval)
        if frequency == .weekly, !weekdays.isEmpty { rule.byWeekday = weekdays.sorted() }
        if frequency == .monthly { rule.byMonthday = monthday }
        switch end {
        case .never: break
        case let .until(date): rule.until = date
        case let .count(count): rule.count = count
        }
        return rule.normalized(start: start)
    }

    /// The interval in words for the stepper: "1 week", "2 weeks" (in Russian "1 неделя", "2 недели", "5 недель").
    public var intervalText: String {
        switch repeatKind {
        case .none: ""
        case .daily: trCount("%lld days", interval)
        case .weekly: trCount("%lld weeks", interval)
        case .monthly: trCount("%lld months", interval)
        case .yearly: trCount("%lld years", interval)
        }
    }
}

/// A short, human reason a memo ended up in the Inbox as failed, for its card.
public enum MemoFailure {
    public static func explanation(for memo: Memo) -> String {
        let reason = memo.failReason ?? ""
        if memo.failStage == "stt" {
            if reason.contains("modelMissing") { return tr("The speech recognition model was not found. Your recording is saved.") }
            return tr("Could not recognize the speech. Your recording is saved.")
        }
        if reason.contains("notLoggedIn") { return tr("Claude is not signed in: run “claude auth login” in a terminal.") }
        if reason.contains("executableNotFound") { return tr("The claude program was not found.") }
        if reason.contains("unsupportedCLI") { return tr("The installed version of claude does not support the options the app needs.") }
        if reason.contains("rateLimited") { return tr("Claude’s usage limit is reached.") }
        if reason.contains("timedOut") { return tr("Claude did not answer in time.") }
        if memo.failStage == "apply" { return tr("Could not save the change in the calendar.") }
        return tr("Could not process the phrase.")
    }
}
