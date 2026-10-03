import Foundation

public struct ValidationPolicy: Sendable {
    public var maxActions = 8
    /// More deletions (or bulk edits) than this in one phrase need an explicit confirmation.
    public var maxDeletesWithoutConfirmation = 2
    public var maxUpdatesWithoutConfirmation = 3
    public var maxTitleLength = 200
    public var maxDetailsLength = 1000
    public var maxSpeechLength = 400
    /// Between midnight and this time "tomorrow" is ambiguous (the person's day has not ended yet).
    public var lateNightUntil = LocalTime(hour: 4, minute: 0)!

    public init() {}
    public static let standard = ValidationPolicy()
}

public struct ValidationContext: Sendable {
    public var context: ContextPlan
    public var resolver: RelativeDateResolver
    public var store: Store
    public var policy: ValidationPolicy
    /// The transcript answers a question the app already asked: the ambiguity guards ("next Friday", "tomorrow" after
    /// midnight) have had their say and must not ask again.
    public var isFollowUp: Bool
    /// The question this transcript answers was about the time: an event that still has none is then an all-day event
    /// (the person said it does not matter), not a reason to ask once more.
    public var timeWasAsked: Bool
    /// Any plan is asked about before it is applied, however small (see `InterpretRequest.confirmAnyChange`).
    public var confirmAnyChange: Bool

    public init(
        context: ContextPlan, resolver: RelativeDateResolver, store: Store, policy: ValidationPolicy = .standard,
        isFollowUp: Bool = false, timeWasAsked: Bool = false, confirmAnyChange: Bool = false
    ) {
        self.context = context
        self.resolver = resolver
        self.store = store
        self.policy = policy
        self.isFollowUp = isFollowUp
        self.timeWasAsked = timeWasAsked
        self.confirmAnyChange = confirmAnyChange
    }

    /// The flags of an answer to a question come from the question itself, in one place for the pipeline and for the replay
    /// of recorded answers. The bulk limits are never lifted here: a plain yes to the app's own "Delete 3 entries?" applies the
    /// plan that was kept with the question (`MemoProcessor`) and never reaches the model; any other answer is a new command.
    public init(
        context: ContextPlan, resolver: RelativeDateResolver, store: Store, policy: ValidationPolicy = .standard, followUp: FollowUp?,
        confirmAnyChange: Bool = false
    ) {
        self.init(
            context: context, resolver: resolver, store: store, policy: policy, isFollowUp: followUp != nil,
            timeWasAsked: followUp?.askedForTime ?? false, confirmAnyChange: confirmAnyChange
        )
    }
}

/// Turns the model's answer into something the app may act on. The model is untrusted: this is the gate.
/// Dates are computed here, references must point at entries the model was shown, limits protect against
/// bulk damage, and anything doubtful becomes a clarification instead of a guess. Nothing is applied partially.
public enum ActionValidator {
    public static func validate(_ response: ParserResponse, in validation: ValidationContext) async -> Interpretation {
        var run = Run(response: response, vc: validation)
        do {
            return try await run.execute()
        } catch let stop as Stop {
            return stop.interpretation
        } catch {
            return .unknown("validator failure: \(error)")
        }
    }

    private struct Stop: Error {
        let interpretation: Interpretation
        init(_ interpretation: Interpretation) { self.interpretation = interpretation }
    }

    private struct Target {
        var item: Item
        /// The date the rule generated (the key of an override), when the entry the person means was listed.
        var occurrenceDate: LocalDate?
        /// Where the entry stands now: the date and time the model was shown, which differ from the rule's for an
        /// occurrence that was moved (a second move starts from there, not from the series).
        var shownDate: LocalDate? = nil
        var shownTime: LocalTime? = nil
    }

    private struct Run {
        let response: ParserResponse
        let vc: ValidationContext
        var warnings: [String] = []
        /// The revision of every entry a target resolved to, so that the plan is applied only to the state it was made from.
        var seenRevisions: [String: Int] = [:]
        /// The entries the targets resolved to, by id (for the questions that name them).
        var seenItems: [String: Item] = [:]

        var policy: ValidationPolicy { vc.policy }
        var resolver: RelativeDateResolver { vc.resolver }
        var anchor: LocalDateTime { vc.resolver.anchor }

        init(response: ParserResponse, vc: ValidationContext) {
            self.response = response
            self.vc = vc
        }

        // MARK: Entry

        mutating func execute() async throws -> Interpretation {
            switch response.intent {
            case .unknown:
                return .unknown(nil)
            case .clarify:
                if let clarification = response.clarification { return .clarify(sanitize(clarification)) }
                if let speech = sanitizeSpeech(response.speech), !speech.isEmpty {
                    return .clarify(Clarification(question: speech, reason: .other))
                }
                return .unknown("clarify without a question")
            case .query:
                guard let query = response.query else { return .unknown("query without details") }
                return try resolve(query)
            case .create, .update, .delete:
                // A clarification next to actions means the model is unsure: ask, do not apply.
                if let clarification = response.clarification { return .clarify(sanitize(clarification)) }
                guard let actions = response.actions, !actions.isEmpty else {
                    return .unknown("\(response.intent) without actions")
                }
                return try await mutation(actions)
            }
        }

        // MARK: Mutations

        mutating func mutation(_ raw: [ParsedAction]) async throws -> Interpretation {
            var actions = raw
            if actions.count > policy.maxActions {
                actions = Array(actions.prefix(policy.maxActions))
                warnings.append("more than \(policy.maxActions) actions: truncated")
            }
            if !vc.isFollowUp {
                try nextWeekdayGuard(actions)
                try lateNightGuard(actions)
            }

            var planned: [PlannedAction] = []
            for action in actions { planned.append(contentsOf: try await plan(action)) }
            planned = settle(planned)
            guard !planned.isEmpty else { return .unknown("no valid actions") }
            let plan = MutationPlan(
                actions: planned, warnings: warnings,
                correctedTranscript: clean(response.transcriptCorrected), confidence: min(max(response.confidence, 0), 1),
                expectedRevisions: seenRevisions
            )
            // Entries, not actions: every occurrence of a series is listed under a number of its own, so "delete all the
            // stand-ups this week" can name one item three times. The plan is complete when the question is asked, and the
            // question carries it: a plain yes applies this very plan, not whatever the model would make of the yes. A plan that
            // replaces one the person already agreed to is asked about whatever its size (`confirmAnyChange`).
            let deleted = planned.compactMap { if case let .delete(id) = $0 { id } else { nil } }
            let edited = planned.compactMap { if case let .update(id, _) = $0 { id } else { nil } }
            let changed = edited + planned.compactMap { if case let .moveOccurrence(id, _, _, _) = $0 { id } else { nil } }
            // Deleting a repeating entry deletes the whole series, and the model may have chosen that for one occurrence the
            // person named: the question says so, and on its own it offers the occurrence instead ("only this occurrence" is
            // an answer the model turns into a skip).
            let seriesDeleted = Set(deleted).compactMap { seenItems[$0] }.filter { $0.recurrence != nil }
            if !deleted.isEmpty, vc.confirmAnyChange || Set(deleted).count > policy.maxDeletesWithoutConfirmation || !seriesDeleted.isEmpty {
                if planned.count == 1, let only = seriesDeleted.first {
                    throw Stop(.clarify(Clarification(
                        question: tr("Delete the whole series “%1$@”?", only.title), reason: .destructiveConfirm,
                        options: [tr("Yes, delete"), tr("Only this occurrence"), tr("No")], pending: plan
                    )))
                }
                throw Stop(.clarify(Clarification(
                    question: naming(deleted, in: trCount("Delete %lld entries?", Set(deleted).count), seriesWide: Set(deleted)),
                    reason: .destructiveConfirm, options: [tr("Yes, delete"), tr("No")], pending: plan
                )))
            }
            if !changed.isEmpty, vc.confirmAnyChange || Set(changed).count > policy.maxUpdatesWithoutConfirmation {
                throw Stop(.clarify(Clarification(
                    question: naming(changed, in: trCount("Change %lld entries?", Set(changed).count), seriesWide: Set(edited)),
                    reason: .destructiveConfirm, options: [tr("Yes, change"), tr("No")], pending: plan
                )))
            }
            if vc.confirmAnyChange {
                throw Stop(.clarify(Clarification(
                    question: trCount("Apply %lld changes?", planned.count), reason: .destructiveConfirm, options: [tr("Yes"), tr("No")], pending: plan
                )))
            }
            return .mutate(plan)
        }

        /// "Delete 3 entries?" names the entries when there are few enough to say: "Delete 3 entries: “A”, “B”, “C”?". The person
        /// then confirms something they can see; `FollowUp.askedToConfirm` knows both forms. A repeating entry among those in
        /// `seriesWide` is marked "(the whole series)": the scope of what will happen to it is part of what is confirmed.
        func naming(_ itemIDs: [String], in question: String, seriesWide: Set<String>) -> String {
            var titles: [String] = []
            var named = Set<String>()
            // in the order of the list the model was shown (the order the person's phrase named them, as a rule)
            for id in vc.context.entries.map(\.item.id) where itemIDs.contains(id) && named.insert(id).inserted {
                guard let item = seenItems[id] else { return question }
                let quoted = Wording.quoted(item.title)
                titles.append(item.recurrence != nil && seriesWide.contains(id) ? tr("%1$@ (the whole series)", quoted) : quoted)
            }
            // an entry found by its words, not shown to the model, has no place in the list: no half list
            guard named.count == Set(itemIDs).count, (1 ... 4).contains(titles.count), question.hasSuffix("?") else { return question }
            return String(question.dropLast()) + ": " + titles.joined(separator: ", ") + "?"
        }

        /// One answer can name the same entry twice. A second delete of an item, or any later change to an item the plan
        /// already deletes, would fail inside the transaction and take the whole plan down with it, so it is left out; an
        /// action on an existing entry that repeats an earlier one is too.
        mutating func settle(_ planned: [PlannedAction]) -> [PlannedAction] {
            var deleted = Set<String>()
            var result: [PlannedAction] = []
            for action in planned {
                if let id = action.targetItemID {
                    if deleted.contains(id) {
                        warnings.append("an action on an entry that is deleted in the same answer was left out")
                        continue
                    }
                    if case .delete = action { deleted.insert(id) }
                }
                if case .create = action {} else if result.contains(action) { // two identical creations are left as they came
                    warnings.append("an action repeated in the same answer was left out")
                    continue
                }
                result.append(action)
            }
            return result
        }

        /// One parsed action becomes one planned action, except an update that moves one occurrence of a series AND changes
        /// its fields: that is a move of the occurrence and an edit of the series, two actions.
        mutating func plan(_ action: ParsedAction) async throws -> [PlannedAction] {
            switch action.op {
            case .create:
                guard let item = action.item else { throw Stop(.unknown("create without an item")) }
                return [.create(try newItem(from: item))]
            case .update:
                let target = try await resolveTarget(action)
                guard let changes = action.changes else { throw Stop(.unknown("update without changes")) }
                return try updateActions(target: target, action: action, changes: changes)
            case .complete:
                let target = try await resolveTarget(action)
                return [.complete(itemID: target.item.id, occurrenceDate: try occurrence(for: target, action: action))]
            case .reopen:
                let target = try await resolveTarget(action)
                return [.reopen(itemID: target.item.id, occurrenceDate: try occurrence(for: target, action: action))]
            case .delete:
                let target = try await resolveTarget(action)
                return [.delete(itemID: target.item.id)]
            case .skipOccurrence:
                let target = try await resolveTarget(action)
                guard target.item.recurrence != nil, let date = target.occurrenceDate ?? action.occurrenceDate else {
                    throw Stop(.clarify(Clarification(question: tr("Which occurrence should I skip?"), reason: .ambiguousTarget)))
                }
                return [.skipOccurrence(itemID: target.item.id, occurrenceDate: date)]
            }
        }

        /// Recurring items are completed per occurrence; one-off items have no occurrence date.
        func occurrence(for target: Target, action: ParsedAction) throws -> LocalDate? {
            guard target.item.recurrence != nil else { return nil }
            guard let date = target.occurrenceDate ?? action.occurrenceDate else {
                throw Stop(.clarify(Clarification(question: tr("Which occurrence should I mark?"), reason: .ambiguousTarget)))
            }
            return date
        }

        // MARK: Targets

        mutating func resolveTarget(_ action: ParsedAction) async throws -> Target {
            let (target, revision) = try await findTarget(action)
            // The revision belongs to the same snapshot as the entry (the model's list, or the search that found it). An entry
            // without one (not in the database) gets a revision nothing can match, and the plan is refused at apply.
            seenRevisions[target.item.id] = revision ?? -1
            seenItems[target.item.id] = target.item
            return target
        }

        private mutating func findTarget(_ action: ParsedAction) async throws -> (Target, Int?) {
            if let ref = action.ref {
                if let entry = vc.context.entry(number: ref) {
                    return (Target(item: entry.item, occurrenceDate: entry.occurrenceDate, shownDate: entry.date, shownTime: entry.time), vc.context.revisions[entry.item.id])
                }
                warnings.append("ref \(ref) is not in the list the model was shown")
            }
            guard let hint = clean(action.targetHint) else {
                throw Stop(.clarify(Clarification(question: tr("Which entry do you mean?"), reason: .targetNotFound)))
            }
            let (hits, revisions) = try await vc.store.searchSnapshot(hint, limit: 5)
            switch hits.count {
            case 0:
                throw Stop(.clarify(Clarification(question: tr("I did not find the entry “%1$@”. What exactly should I change?", hint), reason: .targetNotFound)))
            case 1:
                return (Target(item: hits[0], occurrenceDate: action.occurrenceDate), revisions[hits[0].id])
            default:
                throw Stop(.clarify(Clarification(
                    question: tr("Which one of these entries?"), reason: .ambiguousTarget,
                    options: hits.prefix(3).map { describe($0) }
                )))
            }
        }

        func describe(_ item: Item) -> String {
            item.date.map { "\(item.title), \(Wording.date($0))" } ?? item.title
        }

        // MARK: Creation

        mutating func newItem(from parsed: ParsedItem) throws -> NewItem {
            guard let title = clean(parsed.title).map({ String($0.prefix(policy.maxTitleLength)) }) else {
                throw Stop(.clarify(Clarification(question: tr("I did not catch what to note. Could you repeat?"), reason: .unclearSpeech)))
            }
            var resolved = ResolvedWhen(date: nil, time: nil)
            if let when = parsed.when { resolved = resolveWhen(when) }
            // "Every weekday at six" said on a Monday morning starts today, not next week: the resolver moves a weekday that is
            // today to the following week, which is right for a single appointment but not for a series whose first day may
            // be today (the model has to name one weekday of the rule, and today's is often the one it names).
            if let rule = parsed.recurrence, rule.freq == .weekly, let days = rule.byWeekday, !days.isEmpty,
               let when = parsed.when, when.mode == .weekday, (when.weekOffset ?? 0) == 0, let date = resolved.date,
               let earlier = Self.firstWeeklyStart(days: days, anchor: anchor, time: resolved.time), earlier < date {
                resolved.date = earlier
                resolved.issues.removeAll { $0 == .inThePast }
            }
            // "Every 25th" needs no date from the model: the first day that fits the rule is the start.
            if resolved.date == nil, let rule = parsed.recurrence, let first = Self.firstDay(of: rule, from: anchor.date) {
                resolved.date = first
                resolved.issues.removeAll()
            }
            let hasDate = resolved.date != nil

            switch parsed.kind {
            case .event:
                if !hasDate {
                    throw Stop(.clarify(Clarification(question: tr("For which date: “%1$@”?", title), reason: .missingDate)))
                }
                if resolved.time == nil, !vc.timeWasAsked {
                    let day = Wording.relativeDay(resolved.date!, today: anchor.date)
                    throw Stop(.clarify(Clarification(question: tr("At what time: “%1$@” %2$@?", title, day), reason: .missingTime)))
                }
            case .reminder:
                if !hasDate {
                    throw Stop(.clarify(Clarification(question: tr("For which date should I remind you?"), reason: .missingDate)))
                }
            case .task, .note:
                break
            }

            if parsed.recurrence == nil, let date = resolved.date, resolved.issues.contains(.inThePast) {
                throw Stop(.clarify(Clarification(
                    question: tr("That date has passed (%1$@). Which date should I use?", Wording.date(date)), reason: .other
                )))
            }
            let recurrence = parsed.recurrence.flatMap { sanitize($0, start: resolved.date) }
            if parsed.recurrence != nil, !hasDate {
                throw Stop(.clarify(Clarification(question: tr("From which day should it repeat?"), reason: .missingDate)))
            }
            return NewItem(
                kind: parsed.kind, title: title,
                details: clean(parsed.details).map { String($0.prefix(policy.maxDetailsLength)) },
                keywords: (parsed.keywords ?? []).compactMap { clean($0) }.prefix(6).joined(separator: " "),
                date: resolved.date, time: resolved.date == nil ? nil : resolved.time, // a time alone belongs to nothing
                durationMin: parsed.durationMin.flatMap { (1 ... 1440).contains($0) ? $0 : nil },
                approximate: resolved.approximate, recurrence: recurrence
            )
        }

        // MARK: Updates

        mutating func updateActions(target: Target, action: ParsedAction, changes parsed: ParsedChanges) throws -> [PlannedAction] {
            var changes = ItemChanges()
            changes.kind = parsed.kind
            changes.title = clean(parsed.title).map { String($0.prefix(policy.maxTitleLength)) }
            changes.details = clean(parsed.details).map { String($0.prefix(policy.maxDetailsLength)) }
            if let keywords = parsed.keywords { changes.keywords = keywords.compactMap { clean($0) }.prefix(6).joined(separator: " ") }
            changes.durationMin = parsed.durationMin.flatMap { (1 ... 1440).contains($0) ? $0 : nil }
            changes.recurrence = parsed.recurrence.flatMap { sanitize($0, start: target.item.date) }
            changes.removeUnchanged(comparedWith: target.item)

            var newDate: LocalDate?
            var newTime: LocalTime?
            if let when = parsed.when, when.mode != .none || when.time != nil || when.dayPart != nil {
                let resolved = resolveWhen(when)
                if resolved.issues.contains(where: { if case .incomplete = $0 { true } else { false } }) {
                    throw Stop(.clarify(Clarification(question: tr("To which date should I move it?"), reason: .missingDate)))
                }
                if resolved.issues.contains(.inThePast), let date = resolved.date {
                    throw Stop(.clarify(Clarification(
                        question: tr("That date has passed (%1$@). To which date should I move it?", Wording.date(date)), reason: .other
                    )))
                }
                if when.mode != .none { newDate = resolved.date }
                newTime = resolved.time
            }

            if target.item.recurrence != nil, newDate != nil || newTime != nil, let occurrence = target.occurrenceDate ?? action.occurrenceDate {
                // A new date or time for one occurrence of a series moves that occurrence, never the series: "move it to 18:00"
                // keeps the day the entry is on now, "to Friday" keeps its time (for an occurrence that was moved before, that is
                // where it stands, not the rule's day and the series' hour). Whatever else changes (a title, details) has no
                // per-occurrence home and is an edit of the series, beside the move.
                let move = PlannedAction.moveOccurrence(
                    itemID: target.item.id, occurrenceDate: occurrence,
                    newDate: newDate ?? target.shownDate ?? occurrence, newTime: newTime ?? target.shownTime ?? target.item.time
                )
                return changes.isEmpty ? [move] : [move, .update(itemID: target.item.id, changes: changes)]
            }
            changes.date = newDate
            changes.time = newTime
            guard !changes.isEmpty else { throw Stop(.unknown("update changes nothing")) }
            return [.update(itemID: target.item.id, changes: changes)]
        }

        // MARK: Dates

        /// Resolves a `when` and lets the local reading of the user's own words override the model's arithmetic.
        mutating func resolveWhen(_ when: When) -> ResolvedWhen {
            var resolved = resolver.resolve(when)
            if case let .disagrees(local) = resolver.crossCheck(when, resolved: resolved) {
                warnings.append("«\(when.phrase ?? "")»: model gave \(resolved.date.map(\.description) ?? "no date"), local reading \(local)")
                resolved.date = local
                resolved.issues.removeAll()
                if resolver.isPast(date: local, time: resolved.time) { resolved.issues.append(.inThePast) }
            }
            return resolved
        }

        /// "Next Friday" (in Russian, "в следующую пятницу") can mean the coming Friday or the one after it: it was decided
        /// to always ask, so this is enforced here whatever the model answered.
        func nextWeekdayGuard(_ actions: [ParsedAction]) throws {
            for action in actions {
                guard let when = action.item?.when ?? action.changes?.when, let phrase = when.phrase else { continue }
                let words = SearchText.tokens(phrase)
                // Only "next" right before the weekday is ambiguous ("next Friday"); "next week on Friday" is not.
                guard let index = words.indices.first(where: { PhraseDateHint.weekday(for: words[$0]) != nil && $0 > 0 && PhraseDateHint.isNextMarker(words[$0 - 1]) }),
                      let weekday = PhraseDateHint.weekday(for: words[index]) else { continue }
                let nearest = anchor.date.next(weekday)
                let later = nearest.adding(days: 7)
                throw Stop(.clarify(Clarification(
                    question: tr("“%1$@” — is that %2$@ or %3$@?", phrase, Wording.date(nearest), Wording.date(later)),
                    reason: .ambiguousDate,
                    options: [Wording.dateWithWeekday(nearest), Wording.dateWithWeekday(later)]
                )))
            }
        }

        /// Between midnight and 04:00 "tomorrow" may mean the day that is already running: ask which.
        func lateNightGuard(_ actions: [ParsedAction]) throws {
            guard anchor.time < policy.lateNightUntil else { return }
            for action in actions {
                guard let when = action.item?.when ?? action.changes?.when, let phrase = when.phrase else { continue }
                let words = SearchText.tokens(phrase)
                guard let days = PhraseDateHint.daysAhead(words: words) else { continue }
                let early = anchor.date.adding(days: days - 1)
                let literal = anchor.date.adding(days: days)
                throw Stop(.clarify(Clarification(
                    question: tr("It is after midnight. “%1$@” — is that %2$@ or %3$@?", phrase, Wording.date(early), Wording.date(literal)),
                    reason: .ambiguousDate,
                    options: [Wording.dateWithWeekday(early), Wording.dateWithWeekday(literal)]
                )))
            }
        }

        /// The first day a weekly series can start on: today when it is one of the weekdays and its time (if any) is still
        /// ahead, else the next one.
        static func firstWeeklyStart(days: [Weekday], anchor: LocalDateTime, time: LocalTime?) -> LocalDate? {
            for offset in 0 ..< 7 {
                let day = anchor.date.adding(days: offset)
                guard days.contains(day.weekday) else { continue }
                if offset > 0 || time == nil || time! > anchor.time { return day }
            }
            return nil
        }

        /// The first day on or after `today` that a monthly rule with a day of the month, or a weekly rule with weekdays, allows.
        static func firstDay(of rule: Recurrence, from today: LocalDate) -> LocalDate? {
            switch rule.freq {
            case .monthly:
                guard let day = rule.byMonthday, (1 ... 31).contains(day) else { return nil }
                for offset in 0 ... 12 {
                    let month = today.firstOfMonth.adding(months: offset)
                    guard let candidate = LocalDate(year: month.year, month: month.month, day: min(day, month.daysInMonth)) else { continue }
                    if candidate >= today { return candidate }
                }
                return nil
            case .weekly:
                guard let days = rule.byWeekday, !days.isEmpty else { return nil }
                return (0 ..< 7).map { today.adding(days: $0) }.first { days.contains($0.weekday) }
            case .daily, .yearly:
                return nil
            }
        }

        func sanitize(_ recurrence: Recurrence, start: LocalDate?) -> Recurrence? {
            recurrence.normalized(start: start)
        }

        // MARK: Queries

        func resolve(_ query: ParsedQuery) throws -> Interpretation {
            let today = anchor.date
            let detail = query.detail ?? .digest
            let includeDone = query.includeDone ?? false
            let target: QueryPlan.Target
            switch query.scope {
            case .day:
                let date = query.when.flatMap { resolver.resolve($0).date } ?? today
                target = .days(date ... date)
            case .range:
                if let named = query.namedRange {
                    target = .days(namedRange(named))
                } else {
                    let start = query.when.flatMap { resolver.resolve($0).date } ?? today
                    let span = min(max(query.spanDays ?? 7, 1), 366)
                    target = .days(start ... start.adding(days: span - 1))
                }
            case .next:
                target = .upcoming(limit: detail == .first ? 1 : 5)
            case .overdue:
                target = .overdue
            case .inbox:
                target = .inbox
            case .recurring:
                target = .recurring
            case .search:
                guard let text = clean(query.text) else {
                    throw Stop(.clarify(Clarification(question: tr("What should I look for?"), reason: .unclearSpeech)))
                }
                target = .search(text)
            }
            return .query(QueryPlan(target: target, includeDone: includeDone, detail: detail))
        }

        func namedRange(_ range: NamedRange) -> ClosedRange<LocalDate> {
            let today = anchor.date
            let endOfWeek = today.startOfWeek.adding(days: 6)
            switch range {
            case .thisWeek: return today ... endOfWeek
            case .nextWeek: return endOfWeek.adding(days: 1) ... endOfWeek.adding(days: 7)
            case .thisMonth: return today ... today.lastOfMonth
            case .nextMonth:
                let first = today.firstOfMonth.adding(months: 1)
                return first ... first.lastOfMonth
            }
        }

        // MARK: Text hygiene

        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let collapsed = text
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }

        func sanitize(_ clarification: ParsedClarification) -> Clarification {
            let question = clean(clarification.question).map { String($0.prefix(160)) } ?? Self.defaultQuestion(clarification.reason)
            let options = (clarification.options ?? []).compactMap { clean($0) }.prefix(3).map { String($0.prefix(80)) }
            return Clarification(question: question, reason: clarification.reason, options: Array(options))
        }

        func sanitizeSpeech(_ speech: String?) -> String? {
            guard var text = clean(speech) else { return nil }
            text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"[*_`#\[\]<>]"#, with: "", options: .regularExpression)
            return clean(text).map { String($0.prefix(policy.maxSpeechLength)) }
        }

        static func defaultQuestion(_ reason: ClarificationReason) -> String {
            switch reason {
            case .missingDate: tr("For which date?")
            case .missingTime: tr("At what time?")
            case .ambiguousDate: tr("Which date do you mean?")
            case .ambiguousTime: tr("Which time do you mean?")
            case .ambiguousTarget: tr("Which entry exactly?")
            case .targetNotFound: tr("I did not find such an entry. What exactly should I change?")
            case .unclearSpeech: tr("I did not catch that. Please repeat.")
            case .destructiveConfirm: tr("Please confirm.")
            case .other: tr("Please clarify.")
            }
        }
    }
}

extension PlannedAction {
    /// The entry the action works on (`nil` for a creation).
    var targetItemID: String? {
        switch self {
        case .create: nil
        case let .update(id, _), let .moveOccurrence(id, _, _, _), let .complete(id, _), let .reopen(id, _), let .delete(id),
             let .skipOccurrence(id, _): id
        }
    }
}
