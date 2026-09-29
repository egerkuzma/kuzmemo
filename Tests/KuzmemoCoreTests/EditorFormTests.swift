import Testing
@testable import KuzmemoCore

private func day(_ text: String) -> LocalDate { LocalDate(text)! }

@Suite("RecurrenceForm and wording")
struct EditorFormTests {
    @Test func aRuleSurvivesTheRoundTripThroughTheForm() {
        let rules = [
            Recurrence(freq: .daily),
            Recurrence(freq: .daily, interval: 3, count: 10),
            Recurrence(freq: .weekly, byWeekday: [.mon, .thu], until: day("2026-12-31")),
            Recurrence(freq: .weekly, interval: 2),
            Recurrence(freq: .monthly, byMonthday: 25),
            Recurrence(freq: .yearly),
        ]
        for rule in rules {
            #expect(RecurrenceForm(rule).rule(startingOn: day("2026-09-28")) == rule, "\(rule)")
        }
        #expect(RecurrenceForm(nil).rule(startingOn: day("2026-09-28")) == nil)
        #expect(RecurrenceForm(nil).repeatKind == .none)
    }

    @Test func fieldsThatDoNotApplyAreLeftOut() {
        var form = RecurrenceForm()
        form.repeatKind = .daily
        form.weekdays = [.mon]   // left over from an earlier choice of "weekly"
        form.monthday = 5        // and of "monthly"
        #expect(form.rule(startingOn: day("2026-09-28")) == Recurrence(freq: .daily))
        form.repeatKind = .weekly
        #expect(form.rule(startingOn: day("2026-09-28")) == Recurrence(freq: .weekly, byWeekday: [.mon]))
        form.weekdays = []
        #expect(form.rule(startingOn: day("2026-09-28"))?.byWeekday == nil) // the weekday of the start date
    }

    @Test func theIntervalIsWorded() {
        var form = RecurrenceForm()
        #expect(form.intervalText.isEmpty)
        form.repeatKind = .weekly
        #expect(form.intervalText == "1 неделя")
        form.interval = 2; #expect(form.intervalText == "2 недели")
        form.interval = 5; #expect(form.intervalText == "5 недель")
        form.repeatKind = .daily; form.interval = 21; #expect(form.intervalText == "21 день")
        form.repeatKind = .yearly; form.interval = 3; #expect(form.intervalText == "3 года")
    }

    @Test func theRuleIsClampedAndAnEndBeforeTheStartIsDropped() {
        var form = RecurrenceForm()
        form.repeatKind = .weekly
        form.interval = 500
        form.end = .until(day("2026-01-01"))
        let rule = form.rule(startingOn: day("2026-09-28"))
        #expect(rule?.interval == 99 && rule?.until == nil)
        form.end = .count(5000)
        #expect(form.rule(startingOn: day("2026-09-28"))?.count == 1000)
    }

    @Test func aMonthAndADayAreTitledInRussian() {
        #expect(RussianFormat.monthTitle(day("2026-09-28")) == "Сентябрь 2026")
        #expect(RussianFormat.monthTitle(day("2027-01-01")) == "Январь 2027")
        #expect(RussianFormat.dayTitle(day("2026-09-30")) == "Среда, 30 сентября")
        #expect(RussianFormat.weekdayShortName(.sun) == "вс")
        #expect(RussianFormat.entryCount(0) == "нет записей" && RussianFormat.entryCount(1) == "1 запись")
        #expect(RussianFormat.entryCount(3) == "3 записи" && RussianFormat.entryCount(12) == "12 записей" && RussianFormat.entryCount(21) == "21 запись")
    }

    @Test func aFailedMemoIsExplainedInPlainWords() {
        func memo(_ stage: String, _ reason: String) -> Memo {
            Memo(id: "m", createdAt: 0, anchorLocal: "2026-09-28 14:30", tz: "Europe/Moscow", inputKind: .voice, status: .failed, failStage: stage, failReason: reason)
        }
        #expect(MemoFailure.explanation(for: memo("llm", "notLoggedIn")).contains("claude auth login"))
        #expect(MemoFailure.explanation(for: memo("llm", "timedOut(seconds: 30.0)")) == "Claude не ответил вовремя.")
        #expect(MemoFailure.explanation(for: memo("llm", "rateLimited(\"limit\")")) == "Лимит Claude исчерпан.")
        #expect(MemoFailure.explanation(for: memo("llm", "schemaViolation(\"x\")")) == "Не удалось обработать запись.")
        #expect(MemoFailure.explanation(for: memo("stt", "modelMissing(\"/x\")")).contains("модель"))
        #expect(MemoFailure.explanation(for: memo("stt", "transcriptionFailed(\"x\")")).hasPrefix("Не удалось распознать"))
        #expect(MemoFailure.explanation(for: memo("apply", "x")).contains("календаре"))
    }
}
