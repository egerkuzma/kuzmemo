import Foundation
import Testing
@testable import KuzmemoCore

private func anchor(_ text: String = "2026-09-28 14:30") -> LocalDateTime {
    let parts = text.split(separator: " ")
    return LocalDateTime(date: LocalDate(String(parts[0]))!, time: LocalTime(String(parts[1]))!)
}

/// Runs a raw model answer through the validator against the given entries.
private func validate(
    _ json: String, entries: [AgendaEntry] = [], store: Store? = nil, at anchorText: String = "2026-09-28 14:30",
    followUp: Bool = false
) async throws -> Interpretation {
    let response = try JSONDecoder().decode(ParserResponse.self, from: Data(json.utf8))
    let store = try store ?? makeStore()
    let context = ValidationContext(
        context: ContextPlan(entries: entries, expanded: false),
        resolver: RelativeDateResolver(anchor: anchor(anchorText)), store: store, isFollowUp: followUp
    )
    return await ActionValidator.validate(response, in: context)
}

private func item(_ id: String, _ title: String, _ date: String?, _ time: String? = nil, recurrence: Recurrence? = nil,
                  kind: ItemKind = .reminder) -> Item {
    Item(id: id, kind: kind, title: title, date: date.flatMap(LocalDate.init), time: time.flatMap(LocalTime.init), recurrence: recurrence)
}

private func entry(_ item: Item, occurrence: String? = nil) -> AgendaEntry {
    AgendaEntry(item: item, date: item.date ?? LocalDate("2026-09-28")!, time: item.time, isDone: false,
                occurrenceDate: occurrence.flatMap(LocalDate.init), wasMoved: false)
}

private func created(_ interpretation: Interpretation) -> [NewItem] {
    guard case let .mutate(plan) = interpretation else { return [] }
    return plan.actions.compactMap { if case let .create(new) = $0 { new } else { nil } }
}

private func clarification(_ interpretation: Interpretation) -> Clarification? {
    if case let .clarify(c) = interpretation { c } else { nil }
}

@Suite("ActionValidator: creating")
struct ValidatorCreateTests {
    @Test func aReminderWithoutATimeIsAllDay() async throws {
        let result = try await validate(ParserResponseTests.create)
        let new = try #require(created(result).first)
        #expect(new.kind == .reminder && new.title == "Сказать Дмитрию про доступ в Notion")
        #expect(new.date == LocalDate("2026-09-30") && new.time == nil)
    }

    @Test func anEventNeedsADateAndATime() async throws {
        let ok = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон с Acme","when":{"mode":"days_from_today","days_from_today":1,"time":"11:00","phrase":"завтра в одиннадцать"}}}]}"#)
        let new = try #require(created(ok).first)
        #expect(new.date == LocalDate("2026-09-29") && new.time == LocalTime("11:00"))

        let noTime = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Встреча с Acme","when":{"mode":"days_from_today","days_from_today":2,"phrase":"послезавтра"}}}]}"#)
        #expect(clarification(noTime)?.reason == .missingTime)
        #expect(clarification(noTime)?.question.contains("Встреча с Acme") == true)
        #expect(clarification(noTime)?.question.contains("послезавтра") == true)

        let noDate = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Встреча","when":{"mode":"none","time":"15:00"}}}]}"#)
        #expect(clarification(noDate)?.reason == .missingDate)
    }

    @Test func aReminderNeedsADateButTasksAndNotesGoToTheInbox() async throws {
        let reminder = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Позвонить Дмитрию"}}]}"#)
        #expect(clarification(reminder)?.reason == .missingDate)
        let task = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"task","title":"Купить молоко"}}]}"#)
        #expect(created(task).first?.date == nil)
        let note = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"note","title":"Идея: маршрут для пробежки","when":{"mode":"none"}}}]}"#)
        #expect(created(note).first?.kind == .note && created(note).first?.date == nil)
    }

    @Test func momentsInThePastAreQuestioned() async throws {
        let yesterday = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Позвонить","when":{"mode":"days_from_today","days_from_today":-1}}}]}"#)
        #expect(clarification(yesterday)?.reason == .other && clarification(yesterday)?.question.contains("прошла") == true)
        let earlierToday = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"days_from_today","days_from_today":0,"time":"09:00"}}}]}"#)
        #expect(clarification(earlierToday)?.reason == .other)
        let laterToday = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"days_from_today","days_from_today":0,"time":"17:00"}}}]}"#)
        #expect(created(laterToday).first?.time == LocalTime("17:00"))
    }

    @Test func theLocalReadingOfTheUsersWordsOverridesWrongArithmetic() async throws {
        let wrong = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Позвонить","when":{"mode":"days_from_today","days_from_today":3,"phrase":"послезавтра"}}}]}"#)
        #expect(created(wrong).first?.date == LocalDate("2026-09-30"))
        guard case let .mutate(plan) = wrong else { Issue.record("expected mutate"); return }
        #expect(plan.warnings.count == 1 && plan.warnings[0].contains("послезавтра"))

        let weekday = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Планёрка","when":{"mode":"weekday","weekday":"mon","week_offset":2,"time":"10:00","phrase":"в понедельник в десять"}}}]}"#)
        #expect(created(weekday).first?.date == LocalDate("2026-10-05"))
    }

    @Test func nextWeekdayIsAlwaysAskedEvenIfTheModelGuessed() async throws {
        let guessed = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"weekday","weekday":"fri","week_offset":1,"time":"15:00","phrase":"в следующую пятницу в три"}}}]}"#)
        let c = try #require(clarification(guessed))
        #expect(c.reason == .ambiguousDate)
        #expect(c.options == ["пт, 2 октября", "пт, 9 октября"])
        #expect(c.question.contains("2 октября") && c.question.contains("9 октября"))
    }

    @Test func nextWeekPhrasesAreNotAmbiguous() async throws {
        let answer = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"weekday","weekday":"fri","week_offset":1,"time":"15:00","phrase":"на следующей неделе в пятницу в три"}}}]}"#
        let result = try await validate(answer)
        let new = try #require(created(result).first)
        #expect(new.date == LocalDate("2026-10-09") && new.time == LocalTime("15:00"))
        let approximate = try await validate(#"{"intent":"create","confidence":0.8,"actions":[{"op":"create","item":{"kind":"reminder","title":"Обсудить бюджет","when":{"mode":"weekday","weekday":"mon","week_offset":1,"phrase":"на следующей неделе","approximate":true}}}]}"#)
        #expect(created(approximate).first?.date == LocalDate("2026-10-05") && created(approximate).first?.approximate == true)
    }

    @Test func lateNightRelativeDaysAreAmbiguous() async throws {
        let json = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"days_from_today","days_from_today":1,"time":"10:00","phrase":"завтра в десять утра"}}}]}"#
        let night = try await validate(json, at: "2026-09-29 00:40")
        let c = try #require(clarification(night))
        #expect(c.reason == .ambiguousDate && c.options == ["вт, 29 сентября", "ср, 30 сентября"])
        // the same phrase in the afternoon is fine, and non-"завтра" phrases are fine at night
        #expect(created(try await validate(json)).count == 1)
        let relative = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Позвонить","when":{"mode":"minutes_from_now","minutes_from_now":120,"phrase":"через два часа"}}}]}"#, at: "2026-09-29 00:40")
        #expect(created(relative).count == 1)
    }

    @Test func anAnswerToAQuestionIsNotAskedAboutAgain() async throws {
        // "Пятница следующей недели, 9 октября" was picked from the offered options; the guard must not fire again.
        let nextFriday = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"weekday","weekday":"fri","week_offset":1,"time":"15:00","phrase":"в следующую пятницу"}}}]}"#
        #expect(clarification(try await validate(nextFriday)) != nil)
        let answered = try await validate(nextFriday, followUp: true)
        #expect(created(answered).first?.date == LocalDate("2026-10-09"))

        // The same for "tomorrow" after midnight, once the person said which day they meant.
        let tomorrow = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Созвон","when":{"mode":"days_from_today","days_from_today":1,"time":"10:00","phrase":"завтра, 30 сентября"}}}]}"#
        #expect(clarification(try await validate(tomorrow, at: "2026-09-29 00:40")) != nil)
        #expect(created(try await validate(tomorrow, at: "2026-09-29 00:40", followUp: true)).count == 1)
    }

    @Test func aConfirmedBulkChangeIsApplied() async throws {
        let entries = (1 ... 4).map { entry(item("i\($0)", "Запись \($0)", "2026-10-01")) }
        let deletes = (1 ... 3).map { #"{"op":"delete","ref":\#($0)}"# }.joined(separator: ",")
        let json = #"{"intent":"delete","confidence":0.9,"actions":[\#(deletes)]}"#
        #expect(clarification(try await validate(json, entries: entries))?.reason == .destructiveConfirm)
        guard case let .mutate(plan) = try await validate(json, entries: entries, followUp: true) else { Issue.record("expected the deletions"); return }
        #expect(plan.actions.count == 3)
    }

    @Test func recurrenceRulesAreClampedAndNeedAStartDate() async throws {
        let wild = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Планёрка","when":{"mode":"weekday","weekday":"mon","time":"10:00"},"recurrence":{"freq":"weekly","interval":500,"by_weekday":["mon","mon","tue"],"count":5000,"by_monthday":40,"until":"2026-01-01"}}}]}"#)
        let rule = try #require(created(wild).first?.recurrence)
        #expect(rule.interval == 99 && rule.count == 1000 && rule.byMonthday == nil && rule.until == nil)
        #expect(rule.byWeekday == [.mon, .tue])

        let noStart = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"task","title":"Зарядка","recurrence":{"freq":"daily"}}}]}"#)
        #expect(clarification(noStart)?.reason == .missingDate)
    }

    @Test func titlesAreCleanedAndBounded() async throws {
        let long = String(repeating: "я", count: 500)
        let result = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"task","title":"  Купить\n  молоко   и хлеб ","details":"  подробности  ","keywords":["молоко","хлеб","а","б","в","г","д","е"]}},{"op":"create","item":{"kind":"note","title":"\#(long)"}}]}"#)
        let items = created(result)
        #expect(items[0].title == "Купить молоко и хлеб" && items[0].details == "подробности")
        #expect(items[0].keywords == "молоко хлеб а б в г")
        #expect(items[1].title.count == 200)
        let empty = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"note","title":"   "}}]}"#)
        #expect(clarification(empty)?.reason == .unclearSpeech)
    }

    @Test func tooManyActionsAreTruncatedAndBulkDeletesNeedConfirmation() async throws {
        let create = #"{"op":"create","item":{"kind":"task","title":"Дело"}}"#
        let many = try await validate(#"{"intent":"create","confidence":0.9,"actions":[\#(Array(repeating: create, count: 12).joined(separator: ","))]}"#)
        guard case let .mutate(plan) = many else { Issue.record("expected mutate"); return }
        #expect(plan.actions.count == 8 && plan.warnings.contains { $0.contains("truncated") })

        let entries = (1 ... 4).map { entry(item("i\($0)", "Запись \($0)", "2026-10-01")) }
        let deletes = (1 ... 3).map { #"{"op":"delete","ref":\#($0)}"# }.joined(separator: ",")
        let bulk = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[\#(deletes)]}"#, entries: entries)
        #expect(clarification(bulk)?.reason == .destructiveConfirm && clarification(bulk)?.question == "Удалить 3 записи?")
        let two = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"delete","ref":2}]}"#, entries: entries)
        if case .mutate = two {} else { Issue.record("two deletions are allowed") }
        let updates = (1 ... 4).map { #"{"op":"update","ref":\#($0),"changes":{"title":"Новое"}}"# }.joined(separator: ",")
        let bulkUpdate = try await validate(#"{"intent":"update","confidence":0.9,"actions":[\#(updates)]}"#, entries: entries)
        #expect(clarification(bulkUpdate)?.question == "Изменить 4 записи?")
    }
}

@Suite("ActionValidator: existing entries")
struct ValidatorTargetTests {
    private let meeting = item("m1", "Встреча с Дмитрием", "2026-10-01", "15:00", kind: .event)
    private let weekly = item("w1", "Планёрка", "2026-09-28", "10:00", recurrence: Recurrence(freq: .weekly, byWeekday: [.mon]), kind: .event)

    @Test func updateResolvesTheNumberedEntry() async throws {
        let entries = [entry(item("a", "Другое", "2026-09-29")), entry(meeting)]
        let result = try await validate(#"{"intent":"update","confidence":0.92,"actions":[{"op":"update","ref":2,"changes":{"when":{"mode":"weekday","weekday":"thu","week_offset":0,"phrase":"на четверг"}}}]}"#, entries: entries)
        guard case let .mutate(plan) = result else { Issue.record("expected mutate: \(result)"); return }
        #expect(plan.actions == [.update(itemID: "m1", changes: ItemChanges(date: LocalDate("2026-10-01")))])
    }

    @Test func movingAnOccurrenceOfARepeatingItemCreatesAnOverride() async throws {
        let entries = [entry(weekly, occurrence: "2026-10-05")]
        let result = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"weekday","weekday":"wed","week_offset":0,"time":"16:00","phrase":"на среду в четыре"}}}]}"#, entries: entries)
        guard case let .mutate(plan) = result else { Issue.record("expected mutate: \(result)"); return }
        #expect(plan.actions == [.moveOccurrence(itemID: "w1", occurrenceDate: LocalDate("2026-10-05")!, newDate: LocalDate("2026-09-30")!, newTime: LocalTime("16:00"))])

        let rename = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"title":"Стендап"}}]}"#, entries: entries)
        guard case let .mutate(renamePlan) = rename else { Issue.record("expected mutate"); return }
        #expect(renamePlan.actions == [.update(itemID: "w1", changes: ItemChanges(title: "Стендап"))])
    }

    @Test func aTimeOnlyChangeKeepsTheDate() async throws {
        let entries = [entry(meeting)]
        let result = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"none","time":"16:00"}}}]}"#, entries: entries)
        guard case let .mutate(plan) = result else { Issue.record("expected mutate"); return }
        #expect(plan.actions == [.update(itemID: "m1", changes: ItemChanges(time: LocalTime("16:00")))])
    }

    @Test func hintsFallBackToSearchAndReportMissingOrAmbiguousTargets() async throws {
        let store = try makeStore()
        try await store.perform(label: "seed") { m in
            try m.insert(Item(id: "", kind: .reminder, title: "Оплатить инвойс", date: LocalDate("2026-10-03"), source: .voice))
            try m.insert(Item(id: "", kind: .event, title: "Созвон с Акме", date: LocalDate("2026-10-04"), source: .voice))
            try m.insert(Item(id: "", kind: .event, title: "Созвон с Клик", date: LocalDate("2026-10-05"), source: .voice))
        }
        let single = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","target_hint":"инвойс"}]}"#, store: store)
        if case let .mutate(plan) = single { #expect(plan.actions == [.delete(itemID: "id-1")]) } else { Issue.record("expected mutate") }

        let none = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","target_hint":"квартальный отчёт"}]}"#, store: store)
        #expect(clarification(none)?.reason == .targetNotFound && clarification(none)?.question.contains("квартальный отчёт") == true)

        let both = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","target_hint":"созвон","changes":{"title":"Звонок"}}]}"#, store: store)
        let c = try #require(clarification(both))
        #expect(c.reason == .ambiguousTarget && c.options.count == 2 && c.options[0].contains("Созвон"))

        let bogusRef = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":42,"target_hint":"инвойс"}]}"#, store: store)
        if case let .mutate(plan) = bogusRef { #expect(plan.warnings.contains { $0.contains("ref 42") }) } else { Issue.record("expected mutate") }
        let noHint = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":42}]}"#, store: store)
        #expect(clarification(noHint)?.reason == .targetNotFound)
    }

    @Test func completeReopenAndSkipUseTheOccurrenceOfRepeatingItems() async throws {
        let entries = [entry(meeting), entry(weekly, occurrence: "2026-10-05")]
        let oneOff = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"complete","ref":1}]}"#, entries: entries)
        guard case let .mutate(p1) = oneOff else { Issue.record("expected mutate"); return }
        #expect(p1.actions == [.complete(itemID: "m1", occurrenceDate: nil)])

        let repeating = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"complete","ref":2},{"op":"reopen","ref":1}]}"#, entries: entries)
        guard case let .mutate(p2) = repeating else { Issue.record("expected mutate"); return }
        #expect(p2.actions == [.complete(itemID: "w1", occurrenceDate: LocalDate("2026-10-05")), .reopen(itemID: "m1", occurrenceDate: nil)])

        let skip = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"skip_occurrence","ref":2}]}"#, entries: entries)
        guard case let .mutate(p3) = skip else { Issue.record("expected mutate"); return }
        #expect(p3.actions == [.skipOccurrence(itemID: "w1", occurrenceDate: LocalDate("2026-10-05")!)])

        let badSkip = try await validate(#"{"intent":"delete","confidence":0.9,"actions":[{"op":"skip_occurrence","ref":1}]}"#, entries: entries)
        #expect(clarification(badSkip)?.reason == .ambiguousTarget)
    }

    @Test func badUpdatesBecomeQuestionsOrAreDropped() async throws {
        let entries = [entry(meeting)]
        let nothing = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{}}]}"#, entries: entries)
        if case .unknown = nothing {} else { Issue.record("expected unknown, got \(nothing)") }
        let past = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"days_from_today","days_from_today":-2}}}]}"#, entries: entries)
        #expect(clarification(past)?.question.contains("прошла") == true)
        let incomplete = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"absolute"}}}]}"#, entries: entries)
        #expect(clarification(incomplete)?.reason == .missingDate)
    }
}

@Suite("ActionValidator: intents and queries")
struct ValidatorIntentTests {
    @Test func unknownClarifyAndMalformedAnswers() async throws {
        if case .unknown = try await validate(#"{"intent":"unknown","confidence":0.9}"#) {} else { Issue.record("unknown") }
        if case .unknown = try await validate(#"{"intent":"create","confidence":0.9}"#) {} else { Issue.record("create without actions") }
        if case .unknown = try await validate(#"{"intent":"query","confidence":0.9}"#) {} else { Issue.record("query without details") }

        let asked = try await validate(ParserResponseTests.clarify)
        let c = try #require(clarification(asked))
        #expect(c.reason == .ambiguousDate && c.options.count == 2)

        let speechOnly = try await validate(#"{"intent":"clarify","confidence":0.8,"speech":"На **какую** дату? https://evil.example/x"}"#)
        #expect(clarification(speechOnly)?.question == "На какую дату?")
        let empty = try await validate(#"{"intent":"clarify","confidence":0.8}"#)
        if case .unknown = empty {} else { Issue.record("clarify without question") }

        let long = String(repeating: "в", count: 400)
        let trimmed = try await validate(#"{"intent":"clarify","confidence":0.8,"clarification":{"question":"\#(long)","reason":"other","options":["1","2","3","4","5"]}}"#)
        #expect(clarification(trimmed)?.question.count == 160 && clarification(trimmed)?.options.count == 3)
    }

    @Test func aClarificationBesideActionsWinsAndNothingIsApplied() async throws {
        let json = #"{"intent":"create","confidence":0.5,"actions":[{"op":"create","item":{"kind":"task","title":"Дело"}}],"clarification":{"question":"Точно?","reason":"other"}}"#
        #expect(clarification(try await validate(json))?.question == "Точно?")
        if case .unknown = try await validate(#"{"intent":"unknown","confidence":0.9,"actions":[{"op":"create","item":{"kind":"task","title":"Дело"}}]}"#) {} else {
            Issue.record("unknown intent must not apply actions")
        }
    }

    @Test func dayQueries() async throws {
        let today = try await validate(ParserResponseTests.query)
        #expect(today == .query(QueryPlan(target: .days(LocalDate("2026-09-28")! ... LocalDate("2026-09-28")!))))
        let tomorrow = try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"day","when":{"mode":"days_from_today","days_from_today":1,"phrase":"завтра"},"detail":"count"}}"#)
        #expect(tomorrow == .query(QueryPlan(target: .days(LocalDate("2026-09-29")! ... LocalDate("2026-09-29")!), detail: .count)))
        let bare = try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"day"}}"#)
        #expect(bare == .query(QueryPlan(target: .days(LocalDate("2026-09-28")! ... LocalDate("2026-09-28")!))))
    }

    @Test(arguments: [
        ("this_week", "2026-09-28", "2026-10-04"),
        ("next_week", "2026-10-05", "2026-10-11"),
        ("this_month", "2026-09-28", "2026-09-30"),
        ("next_month", "2026-10-01", "2026-10-31"),
    ])
    func namedRanges(name: String, from: String, through: String) async throws {
        let result = try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"range","named_range":"\#(name)"}}"#)
        #expect(result == .query(QueryPlan(target: .days(LocalDate(from)! ... LocalDate(through)!))), "range \(name)")
    }

    @Test func spanAndOtherScopes() async throws {
        let span = try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"range","when":{"mode":"days_from_today","days_from_today":1},"span_days":3}}"#)
        #expect(span == .query(QueryPlan(target: .days(LocalDate("2026-09-29")! ... LocalDate("2026-10-01")!))))
        #expect(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"next"}}"#) == .query(QueryPlan(target: .upcoming(limit: 5))))
        #expect(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"next","detail":"first"}}"#) == .query(QueryPlan(target: .upcoming(limit: 1), detail: .first)))
        #expect(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"overdue"}}"#) == .query(QueryPlan(target: .overdue)))
        #expect(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"inbox"}}"#) == .query(QueryPlan(target: .inbox)))
        #expect(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"recurring","include_done":true}}"#) == .query(QueryPlan(target: .recurring, includeDone: true)))
        #expect(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"search","text":"  Акме "}}"#) == .query(QueryPlan(target: .search("Акме"))))
        #expect(clarification(try await validate(#"{"intent":"query","confidence":0.9,"query":{"scope":"search"}}"#))?.reason == .unclearSpeech)
    }
}
