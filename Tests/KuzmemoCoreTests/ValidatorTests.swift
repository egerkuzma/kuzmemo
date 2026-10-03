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
    followUp: Bool = false, timeAsked: Bool = false, confirmed: BulkConfirmation? = nil
) async throws -> Interpretation {
    let response = try JSONDecoder().decode(ParserResponse.self, from: Data(json.utf8))
    let store = try store ?? makeStore()
    let context = ValidationContext(
        context: ContextPlan(entries: entries, expanded: false),
        resolver: RelativeDateResolver(anchor: anchor(anchorText)), store: store, isFollowUp: followUp, timeWasAsked: timeAsked,
        bulkConfirmation: confirmed
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
        // the same phrase in the afternoon is fine, and phrases without "завтра" ("tomorrow") are fine at night
        #expect(created(try await validate(json)).count == 1)
        let relative = try await validate(#"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Позвонить","when":{"mode":"minutes_from_now","minutes_from_now":120,"phrase":"через два часа"}}}]}"#, at: "2026-09-29 00:40")
        #expect(created(relative).count == 1)
    }

    @Test func anAnswerToAQuestionIsNotAskedAboutAgain() async throws {
        // "Пятница следующей недели, 9 октября" (Friday of next week, October 9) was picked from the offered options; the
        // guard must not fire again.
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
        let agreed = BulkConfirmation(operation: .delete, count: 3)
        guard case let .mutate(plan) = try await validate(json, entries: entries, followUp: true, confirmed: agreed) else { Issue.record("expected the deletions"); return }
        #expect(plan.actions.count == 3)
    }

    /// The model's answer to the yes is made anew: it covers what the person agreed to (the operation and the number of entries),
    /// not whatever the model names this time.
    @Test func aConfirmationCoversOnlyWhatWasAgreedTo() async throws {
        let entries = (1 ... 5).map { entry(item("i\($0)", "Запись \($0)", "2026-10-01")) }
        let agreedToDeleteThree = BulkConfirmation(operation: .delete, count: 3)
        let fourDeletes = #"{"intent":"delete","confidence":0.9,"actions":[\#((1 ... 4).map { #"{"op":"delete","ref":\#($0)}"# }.joined(separator: ","))]}"#
        #expect(clarification(try await validate(fourDeletes, entries: entries, followUp: true, confirmed: agreedToDeleteThree))?.question == "Удалить 4 записи?")
        let twoDeletes = #"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"delete","ref":2}]}"#
        guard case .mutate = try await validate(twoDeletes, entries: entries, followUp: true, confirmed: agreedToDeleteThree) else { Issue.record("fewer than agreed is fine"); return }
        // a yes to deleting does not cover changing, and the other way round
        let fourUpdates = #"{"intent":"update","confidence":0.9,"actions":[\#((1 ... 4).map { #"{"op":"update","ref":\#($0),"changes":{"title":"Новое \#($0)"}}"# }.joined(separator: ","))]}"#
        #expect(clarification(try await validate(fourUpdates, entries: entries, followUp: true, confirmed: agreedToDeleteThree))?.question == "Изменить 4 записи?")
        let threeDeletes = #"{"intent":"delete","confidence":0.9,"actions":[\#((1 ... 3).map { #"{"op":"delete","ref":\#($0)}"# }.joined(separator: ","))]}"#
        #expect(clarification(try await validate(threeDeletes, entries: entries, followUp: true, confirmed: BulkConfirmation(operation: .update, count: 4)))?.question == "Удалить 3 записи?")
    }

    /// Only a plain yes is a confirmation. A no is decided before the model is asked (`MemoProcessor`); anything in between
    /// ("yes, but not the third") is left to the model, with the limits in force.
    @Test func onlyAPlainYesLiftsTheLimitAndOnlyAPlainNoDeclines() {
        let asked = FollowUp(previous: "удали всё на завтра", question: "Удалить 3 записи?")
        #expect(asked.bulkQuestion == BulkConfirmation(operation: .delete, count: 3))
        #expect(FollowUp(previous: "x", question: "Change 4 entries?").bulkQuestion == BulkConfirmation(operation: .update, count: 4))
        #expect(FollowUp(previous: "x", question: "Изменить 1 запись?").bulkQuestion == BulkConfirmation(operation: .update, count: 1))
        #expect(FollowUp(previous: "x", question: "Delete 12 entries?").bulkQuestion == BulkConfirmation(operation: .delete, count: 12))
        for yes in ["да, удалить", "Да, удалить", "Yes, delete", "yes", "да", "удаляй их все", "Ок", "давай", "delete them all", "Sure, go ahead."] {
            #expect(asked.confirmedBulk(by: yes) == BulkConfirmation(operation: .delete, count: 3), "'\(yes)'")
            #expect(!FollowUp.declines(yes), "'\(yes)'")
        }
        for no in ["нет", "Нет", "нет, не надо", "не надо", "отмена", "не удаляй", "ничего не делай", "No", "no, cancel", "never mind", "don't"] {
            #expect(FollowUp.declines(no), "'\(no)'")
            #expect(asked.confirmedBulk(by: no) == nil, "'\(no)'")
        }
        for unclear in ["да, но не третью", "только первые две", "yes, except the dentist", "удали только созвон", "", "да нет"] {
            #expect(asked.confirmedBulk(by: unclear) == nil && !FollowUp.declines(unclear), "'\(unclear)'")
        }
        // the yes to another question is not a confirmation of anything
        #expect(FollowUp(previous: "x", question: "На какую дату напомнить?").confirmedBulk(by: "да") == nil)
    }

    /// Only the person's yes to the app's own "Delete 3 entries?" lifts the bulk limit. Any other follow-up (the answer to
    /// "At what time?", or something that has nothing to do with the question) is a new command.
    @Test func anAnswerToAnotherQuestionMeetsTheBulkLimitAgain() async throws {
        let entries = (1 ... 4).map { entry(item("i\($0)", "Запись \($0)", "2026-10-01")) }
        let deletes = (1 ... 3).map { #"{"op":"delete","ref":\#($0)}"# }.joined(separator: ",")
        let json = #"{"intent":"delete","confidence":0.9,"actions":[\#(deletes)]}"#
        let result = try await validate(json, entries: entries, followUp: true, confirmed: nil)
        #expect(clarification(result)?.reason == .destructiveConfirm)
        let updates = (1 ... 4).map { #"{"op":"update","ref":\#($0),"changes":{"title":"Новое \#($0)"}}"# }.joined(separator: ",")
        let bulkUpdate = #"{"intent":"update","confidence":0.9,"actions":[\#(updates)]}"#
        #expect(clarification(try await validate(bulkUpdate, entries: entries, followUp: true))?.reason == .destructiveConfirm)
        guard case .mutate = try await validate(bulkUpdate, entries: entries, followUp: true, confirmed: BulkConfirmation(operation: .update, count: 4)) else { Issue.record("expected the changes"); return }
    }

    @Test func theAppsOwnBulkQuestionIsRecognisedInBothLanguages() {
        for question in ["Delete 3 entries?", "Delete 1 entry?", "Change 4 entries?", "Удалить 3 записи?", "Удалить 5 записей?", "Удалить 1 запись?", "Изменить 4 записи?"] {
            #expect(FollowUp(previous: "x", question: question).askedToConfirmBulk, "question '\(question)'")
        }
        for question in ["На какую дату напомнить?", "Во сколько встреча?", "Удалить запись «Созвон»?", "Delete the call with Anna?", "Какую пятницу имеешь в виду?"] {
            #expect(!FollowUp(previous: "x", question: question).askedToConfirmBulk, "question '\(question)'")
        }
    }

    /// Every occurrence of a series is listed under a number of its own, so "delete all the stand-ups" can name one item
    /// three times: that is one entry (no bulk question), deleted once (a second delete of it would fail the whole plan).
    @Test func oneEntryNamedSeveralTimesIsDeletedOnce() async throws {
        let series = item("s1", "Планёрка", "2026-09-28", "10:00", recurrence: Recurrence(freq: .daily))
        let entries = ["2026-09-29", "2026-09-30", "2026-10-01"].map { entry(series, occurrence: $0) }
        let json = #"{"intent":"delete","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"delete","ref":2},{"op":"delete","ref":3}]}"#
        guard case let .mutate(plan) = try await validate(json, entries: entries) else { Issue.record("expected one deletion"); return }
        #expect(plan.actions == [.delete(itemID: "s1")])
        #expect(!plan.warnings.isEmpty)
    }

    @Test func aChangeToAnEntryDeletedInTheSameAnswerIsLeftOut() async throws {
        let entries = [entry(item("a", "Созвон", "2026-10-01", "11:00")), entry(item("b", "Обед", "2026-10-01", "13:00"))]
        let json = #"{"intent":"update","confidence":0.9,"actions":[{"op":"delete","ref":1},{"op":"update","ref":1,"changes":{"title":"Другое"}},{"op":"complete","ref":1},{"op":"update","ref":2,"changes":{"title":"Ланч"}}]}"#
        guard case let .mutate(plan) = try await validate(json, entries: entries) else { Issue.record("expected a plan"); return }
        #expect(plan.actions.count == 2)
        #expect(plan.actions.first == .delete(itemID: "a"))
        #expect(plan.actions.last?.targetItemID == "b")
    }

    @Test func anActionRepeatedInTheSameAnswerIsLeftOut() async throws {
        let entries = [entry(item("a", "Созвон", "2026-10-01", "11:00"))]
        let json = #"{"intent":"update","confidence":0.9,"actions":[{"op":"complete","ref":1},{"op":"complete","ref":1}]}"#
        guard case let .mutate(plan) = try await validate(json, entries: entries) else { Issue.record("expected a plan"); return }
        #expect(plan.actions == [.complete(itemID: "a", occurrenceDate: nil)])
    }

    /// A time with no date belongs to nothing: a task or a note that has none keeps no time either.
    @Test func aTimeWithoutADateIsNotKept() async throws {
        let json = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"task","title":"Позвонить маме","when":{"mode":"none","time":"17:00"}}}]}"#
        let new = try #require(created(try await validate(json)).first)
        #expect(new.date == nil && new.time == nil)
    }

    /// A second move of an occurrence that was moved before starts from where it stands: "to 18:00" keeps the day it is
    /// on now, "to Friday" keeps its hour, instead of going back to the rule's day and the series' time.
    @Test func aSecondMoveStartsFromWhereTheOccurrenceStands() async throws {
        let series = item("s1", "Планёрка", "2026-09-28", "10:00", recurrence: Recurrence(freq: .weekly))
        // the Monday 28th stand-up was moved to Wednesday 30th at 16:00 earlier
        let moved = AgendaEntry(item: series, date: LocalDate("2026-09-30")!, time: LocalTime("16:00")!, isDone: false,
                                occurrenceDate: LocalDate("2026-09-28"), wasMoved: true)
        let timeOnly = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"none","time":"18:00"}}}]}"#, entries: [moved])
        guard case let .mutate(first) = timeOnly else { Issue.record("expected a move"); return }
        #expect(first.actions == [.moveOccurrence(itemID: "s1", occurrenceDate: LocalDate("2026-09-28")!, newDate: LocalDate("2026-09-30")!, newTime: LocalTime("18:00"))])
        let dateOnly = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"when":{"mode":"weekday","weekday":"fri","week_offset":0}}}]}"#, entries: [moved])
        guard case let .mutate(second) = dateOnly else { Issue.record("expected a move"); return }
        #expect(second.actions == [.moveOccurrence(itemID: "s1", occurrenceDate: LocalDate("2026-09-28")!, newDate: LocalDate("2026-10-02")!, newTime: LocalTime("16:00"))])
    }

    /// The entry the model was shown knows the key of its own occurrence; the model's arithmetic is only a fallback.
    @Test func theListedOccurrenceBeatsTheModelsOccurrenceDate() async throws {
        let series = item("s1", "Планёрка", "2026-09-28", "10:00", recurrence: Recurrence(freq: .weekly))
        let listed = entry(series, occurrence: "2026-10-05")
        let json = #"{"intent":"update","confidence":0.9,"actions":[{"op":"skip_occurrence","ref":1,"occurrence_date":"2026-10-06"}]}"#
        guard case let .mutate(plan) = try await validate(json, entries: [listed]) else { Issue.record("expected a skip"); return }
        #expect(plan.actions == [.skipOccurrence(itemID: "s1", occurrenceDate: LocalDate("2026-10-05")!)])
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

    /// The model tends to repeat the entry's title or kind beside the one thing that differs. A repeated field is not a change:
    /// with it, the move of one occurrence became a change of the whole series (its start day and its time).
    @Test func fieldsThatRepeatWhatTheEntryHasAreNotChanges() async throws {
        let entries = [entry(weekly, occurrence: "2026-10-05")]
        let echoed = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"kind":"event","title":"Планёрка","when":{"mode":"weekday","weekday":"wed","week_offset":0,"time":"16:00","phrase":"на среду в четыре"}}}]}"#
        guard case let .mutate(plan) = try await validate(echoed, entries: entries) else { Issue.record("expected mutate"); return }
        #expect(plan.actions == [.moveOccurrence(itemID: "w1", occurrenceDate: LocalDate("2026-10-05")!, newDate: LocalDate("2026-09-30")!, newTime: LocalTime("16:00"))])

        // a repeated title with nothing else is nothing to do, and a repeated title beside a real rename is just the rename
        let nothing = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"title":"Планёрка","kind":"event"}}]}"#, entries: entries)
        guard case .unknown = nothing else { Issue.record("expected nothing to change: \(nothing)"); return }
        let oneOff = [entry(meeting)]
        guard case let .mutate(renamed) = try await validate(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"kind":"event","title":"Встреча с Анной"}}]}"#, entries: oneOff) else { Issue.record("expected mutate"); return }
        #expect(renamed.actions == [.update(itemID: "m1", changes: ItemChanges(title: "Встреча с Анной"))])
    }

    /// The plan carries the version of every entry it resolved, so that applying it can tell when one changed meanwhile.
    @Test func thePlanRemembersTheVersionsOfTheEntriesItTouches() async throws {
        var newer = meeting
        newer.version = 4
        let entries = [entry(item("a", "Другое", "2026-09-29")), entry(newer), entry(weekly, occurrence: "2026-10-05")]
        let json = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":2,"changes":{"title":"Встреча с Анной"}},{"op":"complete","ref":3}]}"#
        guard case let .mutate(plan) = try await validate(json, entries: entries) else { Issue.record("expected mutate"); return }
        #expect(plan.expectedVersions == ["m1": 4, "w1": 1])
        guard case let .mutate(creation) = try await validate(ParserResponseTests.create, entries: entries) else { Issue.record("expected mutate"); return }
        #expect(creation.expectedVersions.isEmpty) // a creation touches no existing entry
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

@Suite("ActionValidator: when a time was asked for, or a start is implied")
struct ValidatorTimeAndStartTests {
    private let meetingWithoutTime = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"event","title":"Встреча в кафе","when":{"mode":"days_from_today","days_from_today":1,"phrase":"завтра"}}}]}"#

    @Test func anAnswerToTheTimeQuestionThatGivesNoTimeMakesAnAllDayEvent() async throws {
        let result = try await validate(meetingWithoutTime, followUp: true, timeAsked: true)
        let new = try #require(created(result).first)
        #expect(new.kind == .event && new.date == LocalDate("2026-09-29") && new.time == nil)
    }

    @Test func anAnswerToAnotherQuestionStillGetsTheTimeAsked() async throws {
        let result = try await validate(meetingWithoutTime, followUp: true, timeAsked: false)
        #expect(clarification(result)?.reason == .missingTime)
        let first = try await validate(meetingWithoutTime)
        #expect(clarification(first)?.reason == .missingTime)
    }

    @Test func aQuestionAboutTheTimeIsRecognisedInBothLanguages() {
        #expect(FollowUp(previous: "x", question: "Во сколько завтра встреча в кафе?").askedForTime)
        #expect(FollowUp(previous: "x", question: "В какое время собеседование?").askedForTime)
        #expect(FollowUp(previous: "x", question: "At what time: “Meeting” tomorrow?").askedForTime)
        #expect(!FollowUp(previous: "x", question: "На какую дату напомнить?").askedForTime)
        #expect(!FollowUp(previous: "x", question: "Какую пятницу имеешь в виду?").askedForTime)
    }

    private func monthly(_ day: Int, whenJSON: String = #","when":{"mode":"month_part","month_offset":0,"phrase":"каждого двадцать пятого"}"#) -> String {
        #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Оплатить хостинг","recurrence":{"freq":"monthly","by_monthday":\#(day)}\#(whenJSON)}}]}"#
    }

    @Test func aMonthlyRuleWithoutAUsableStartBeginsOnTheNextMatchingDay() async throws {
        let later = try await validate(monthly(25), at: "2026-09-28 14:30")
        #expect(created(later).first?.date == LocalDate("2026-10-25"))
        let sooner = try await validate(monthly(25), at: "2026-09-20 10:00")
        #expect(created(sooner).first?.date == LocalDate("2026-09-25"))
        let today = try await validate(monthly(28), at: "2026-09-28 14:30")
        #expect(created(today).first?.date == LocalDate("2026-09-28"))
        let short = try await validate(monthly(31), at: "2026-11-05 10:00")
        #expect(created(short).first?.date == LocalDate("2026-11-30"), "the 31st of a 30-day month is its last day")
    }

    @Test func aWeeklyRuleWithoutAStartBeginsOnTheNextMatchingWeekday() async throws {
        let json = #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Проверять статистику","recurrence":{"freq":"weekly","by_weekday":["mon","tue","wed","thu","fri"]}}}]}"#
        let monday = try await validate(json, at: "2026-09-28 14:30")
        #expect(created(monday).first?.date == LocalDate("2026-09-28"))
        let saturday = try await validate(json, at: "2026-10-03 10:00")
        #expect(created(saturday).first?.date == LocalDate("2026-10-05"))
    }

    private func weekly(weekday: String, offset: Int = 0, time: String? = "18:00", days: String) -> String {
        let timePart = time.map { #","time":"\#($0)""# } ?? ""
        return #"{"intent":"create","confidence":0.9,"actions":[{"op":"create","item":{"kind":"reminder","title":"Проверять статистику","when":{"mode":"weekday","weekday":"\#(weekday)","week_offset":\#(offset)\#(timePart)},"recurrence":{"freq":"weekly","by_weekday":[\#(days)]}}}]}"#
    }

    @Test func aWeeklySeriesWhoseTimeIsStillAheadStartsToday() async throws {
        let weekdays = weekly(weekday: "mon", days: #""mon","tue","wed","thu","fri""#)
        let monday = try await validate(weekdays, at: "2026-09-28 14:30")
        #expect(created(monday).first?.date == LocalDate("2026-09-28"), "18:00 is still ahead of 14:30, so the series starts today")
        let evening = try await validate(weekdays, at: "2026-09-28 19:00")
        #expect(created(evening).first?.date == LocalDate("2026-09-29"), "today's time has gone: the next matching day")
        let single = try await validate(weekly(weekday: "mon", days: #""mon""#), at: "2026-09-28 14:30")
        #expect(created(single).first?.date == LocalDate("2026-09-28"))
    }

    @Test func aWeeklySeriesWhoseTimeHasGoneOrWhichWasPlacedLaterKeepsItsStart() async throws {
        let passed = try await validate(weekly(weekday: "mon", time: "10:00", days: #""mon""#), at: "2026-09-28 14:30")
        #expect(created(passed).first?.date == LocalDate("2026-10-05"))
        let nextWeek = try await validate(weekly(weekday: "mon", offset: 1, days: #""mon","tue""#), at: "2026-09-28 14:30")
        #expect(created(nextWeek).first?.date == LocalDate("2026-10-05"), "\"from next week\" is respected")
        let friday = try await validate(weekly(weekday: "fri", time: nil, days: #""fri""#), at: "2026-09-28 14:30")
        #expect(created(friday).first?.date == LocalDate("2026-10-02"))
    }

    @Test func aStartTheModelDidGiveIsKept() async throws {
        let json = monthly(25, whenJSON: #","when":{"mode":"absolute","date":"2026-11-25","phrase":"с ноября"}"#)
        let result = try await validate(json, at: "2026-09-28 14:30")
        #expect(created(result).first?.date == LocalDate("2026-11-25"))
    }
}
