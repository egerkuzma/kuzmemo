import Foundation
import Testing
@testable import KuzmemoCore

private func d(_ s: String) -> LocalDate { LocalDate(s)! }

private func series(
    _ start: String, _ recurrence: Recurrence, time: String? = nil, id: String = "s1"
) -> Item {
    Item(id: id, kind: .event, title: "Серия", date: d(start), time: time.flatMap(LocalTime.init), recurrence: recurrence)
}

private func dates(_ item: Item, _ from: String, _ through: String, exceptions: [ItemException] = []) -> [String] {
    RecurrenceExpander.occurrences(of: item, from: d(from), through: d(through), exceptions: exceptions).map { $0.date.description }
}

@Suite("RecurrenceExpander")
struct RecurrenceExpanderTests {
    @Test func dailyWithAndWithoutInterval() {
        let everyDay = series("2026-09-29", Recurrence(freq: .daily))
        #expect(dates(everyDay, "2026-09-28", "2026-10-02") == ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"])
        let everyThird = series("2026-01-01", Recurrence(freq: .daily, interval: 3))
        let got = dates(everyThird, "2026-10-01", "2026-10-10")
        // 2026-01-01 + 3k: 2026-10-01 is day 273 -> 273 % 3 == 0
        #expect(got == ["2026-10-01", "2026-10-04", "2026-10-07", "2026-10-10"])
    }

    @Test func weeklyOnTheStartWeekdayByDefault() {
        let mondays = series("2026-10-05", Recurrence(freq: .weekly), time: "10:00")
        #expect(dates(mondays, "2026-10-01", "2026-10-31") == ["2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26"])
    }

    @Test func weekdaysMondayToFriday() {
        let workdays = series("2026-09-28", Recurrence(freq: .weekly, byWeekday: [.mon, .tue, .wed, .thu, .fri]))
        #expect(dates(workdays, "2026-09-28", "2026-10-06") == [
            "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06",
        ])
    }

    @Test func everyOtherFriday() {
        let biweekly = series("2026-10-02", Recurrence(freq: .weekly, interval: 2, byWeekday: [.fri]))
        #expect(dates(biweekly, "2026-10-01", "2026-11-20") == ["2026-10-02", "2026-10-16", "2026-10-30", "2026-11-13"])
    }

    @Test func weeklyStartingOutsideTheChosenWeekdayBeginsOnTheNextOne() {
        let item = series("2026-09-30", Recurrence(freq: .weekly, byWeekday: [.mon])) // a Wednesday
        #expect(dates(item, "2026-09-28", "2026-10-13") == ["2026-10-05", "2026-10-12"])
    }

    @Test func monthlyOnAFixedDay() {
        let item = series("2026-09-25", Recurrence(freq: .monthly, byMonthday: 25))
        #expect(dates(item, "2026-09-01", "2027-01-31") == ["2026-09-25", "2026-10-25", "2026-11-25", "2026-12-25", "2027-01-25"])
    }

    @Test func monthlyDayThirtyOneClampsToTheLastDay() {
        let item = series("2026-01-31", Recurrence(freq: .monthly, byMonthday: 31))
        #expect(dates(item, "2026-01-01", "2026-06-30") == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31", "2026-06-30"])
        #expect(dates(item, "2028-02-01", "2028-02-29") == ["2028-02-29"])
    }

    @Test func monthlyEveryTwoMonthsUsesTheStartDay() {
        let item = series("2026-09-15", Recurrence(freq: .monthly, interval: 2))
        #expect(dates(item, "2026-09-01", "2027-03-31") == ["2026-09-15", "2026-11-15", "2027-01-15", "2027-03-15"])
    }

    @Test func monthlySkipsTheStartMonthWhenTheDayHasPassed() {
        // Started on the 20th but the rule is the 5th: the first occurrence is next month's 5th.
        let item = series("2026-09-20", Recurrence(freq: .monthly, byMonthday: 5))
        #expect(dates(item, "2026-09-01", "2026-11-30") == ["2026-10-05", "2026-11-05"])
    }

    @Test func yearlyKeepsMonthAndDayAndClampsLeapDay() {
        let birthday = series("2026-10-03", Recurrence(freq: .yearly))
        #expect(dates(birthday, "2026-01-01", "2029-12-31") == ["2026-10-03", "2027-10-03", "2028-10-03", "2029-10-03"])
        let leap = series("2028-02-29", Recurrence(freq: .yearly))
        #expect(dates(leap, "2028-01-01", "2032-12-31") == ["2028-02-29", "2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
    }

    @Test func countLimitsTotalOccurrencesEvenForLaterRanges() {
        let item = series("2026-10-05", Recurrence(freq: .weekly, count: 3))
        #expect(dates(item, "2026-01-01", "2027-12-31") == ["2026-10-05", "2026-10-12", "2026-10-19"])
        #expect(dates(item, "2026-10-13", "2026-12-31") == ["2026-10-19"])
        #expect(dates(item, "2026-11-01", "2026-12-31").isEmpty)
    }

    @Test func untilIsInclusive() {
        let item = series("2026-10-05", Recurrence(freq: .weekly, until: d("2026-10-19")))
        #expect(dates(item, "2026-10-01", "2026-12-31") == ["2026-10-05", "2026-10-12", "2026-10-19"])
    }

    @Test func rangesBeforeTheStartAreEmpty() {
        let item = series("2026-10-05", Recurrence(freq: .daily))
        #expect(dates(item, "2026-01-01", "2026-10-04").isEmpty)
    }

    @Test func farFutureRangesAreCheap() {
        let item = series("2026-01-01", Recurrence(freq: .weekly, byWeekday: [.mon, .thu]))
        let got = dates(item, "2040-05-01", "2040-05-31")
        #expect(got.count == 9)
        #expect(got.first == "2040-05-03" && got.last == "2040-05-31")
        for text in got { #expect([Weekday.mon, .thu].contains(d(text).weekday)) }
    }

    @Test func intervalBelowOneIsTreatedAsOne() {
        #expect(Recurrence(freq: .daily, interval: 0).interval == 1)
        #expect(Recurrence(freq: .daily, interval: -5).interval == 1)
    }

    @Test func overridesSkipCompleteAndMoveOccurrences() {
        let item = series("2026-10-05", Recurrence(freq: .weekly), time: "10:00")
        let exceptions = [
            ItemException(itemID: "s1", occDate: d("2026-10-12"), action: .skip),
            ItemException(itemID: "s1", occDate: d("2026-10-19"), action: .done),
            ItemException(itemID: "s1", occDate: d("2026-10-26"), action: .moved, movedDate: d("2026-10-28"), movedTime: LocalTime("15:30")),
            ItemException(itemID: "other", occDate: d("2026-10-05"), action: .skip), // another series: ignored
        ]
        let list = RecurrenceExpander.occurrences(of: item, from: d("2026-10-01"), through: d("2026-10-31"), exceptions: exceptions)
        #expect(list.map(\.date.description) == ["2026-10-05", "2026-10-12", "2026-10-19", "2026-10-28"])
        #expect(list.map(\.state) == [.open, .skipped, .done, .open])
        let moved = list[3]
        #expect(moved.wasMoved && moved.originalDate == d("2026-10-26") && moved.time == LocalTime("15:30"))
    }

    @Test func movedOccurrenceAppearsEvenWhenItsOriginalDateIsOutsideTheRange() {
        let item = series("2026-10-05", Recurrence(freq: .weekly))
        let exceptions = [ItemException(itemID: "s1", occDate: d("2026-10-26"), action: .moved, movedDate: d("2026-11-04"))]
        // 11-02 is a regular Monday outside this range; the moved 10-26 occurrence shows up on Wednesday 11-04
        #expect(dates(item, "2026-11-03", "2026-11-07", exceptions: exceptions) == ["2026-11-04"])
        #expect(dates(item, "2026-10-26", "2026-10-31", exceptions: exceptions).isEmpty)
        // moving onto a day that already has an occurrence gives two entries that day
        let onto = [ItemException(itemID: "s1", occDate: d("2026-10-26"), action: .moved, movedDate: d("2026-11-02"))]
        #expect(dates(item, "2026-11-01", "2026-11-07", exceptions: onto) == ["2026-11-02", "2026-11-02"])
    }

    /// "Stand-up every Monday", Monday the 26th moved to Wednesday the 28th, then the series edited to Tuesdays (or started later,
    /// or ended): the moved occurrence has no series behind it any more and used to keep showing, with an alert planned for it.
    @Test func aMoveOfADayTheEditedRuleNoLongerProducesIsNotShown() {
        let moved = [ItemException(itemID: "s1", occDate: d("2026-10-26"), action: .moved, movedDate: d("2026-10-28"), movedTime: LocalTime("15:30"))]
        let mondays = series("2026-10-05", Recurrence(freq: .weekly, byWeekday: [.mon]), time: "10:00")
        #expect(dates(mondays, "2026-10-26", "2026-10-31", exceptions: moved) == ["2026-10-28"]) // as long as the rule has that Monday
        let tuesdays = series("2026-10-05", Recurrence(freq: .weekly, byWeekday: [.tue]), time: "10:00")
        #expect(dates(tuesdays, "2026-10-26", "2026-10-31", exceptions: moved) == ["2026-10-27"])
        let startedLater = series("2026-11-02", Recurrence(freq: .weekly, byWeekday: [.mon]), time: "10:00")
        #expect(dates(startedLater, "2026-10-26", "2026-10-31", exceptions: moved).isEmpty)
        let ended = series("2026-10-05", Recurrence(freq: .weekly, byWeekday: [.mon], until: d("2026-10-20")), time: "10:00")
        #expect(dates(ended, "2026-10-26", "2026-10-31", exceptions: moved).isEmpty)
        let three = series("2026-10-05", Recurrence(freq: .weekly, byWeekday: [.mon], count: 3), time: "10:00")
        #expect(dates(three, "2026-10-26", "2026-10-31", exceptions: moved).isEmpty) // the 5th, 12th and 19th: the 26th is not one of them
        // a done occurrence that was moved follows the same rule
        let doneMoved = [ItemException(itemID: "s1", occDate: d("2026-10-26"), action: .done, movedDate: d("2026-10-28"))]
        #expect(dates(tuesdays, "2026-10-26", "2026-10-31", exceptions: doneMoved) == ["2026-10-27"])
        #expect(dates(mondays, "2026-10-26", "2026-10-31", exceptions: doneMoved) == ["2026-10-28"])
    }
}

@Suite("Store.agenda")
struct AgendaTests {
    @Test func mergesOneOffItemsAndRecurringOccurrencesInDayOrder() async throws {
        let store = try makeStore()
        var weekly = reminder("Планёрка", on: "2026-10-05", at: "10:00")
        weekly.recurrence = Recurrence(freq: .weekly, byWeekday: [.mon])
        let planning = weekly
        try await store.perform(label: "seed") { m in
            try m.insert(planning)
            try m.insert(reminder("Оплатить хостинг", on: "2026-10-05"))
            try m.insert(reminder("Созвон", on: "2026-10-05", at: "09:00"))
            try m.insert(reminder("Через неделю", on: "2026-10-12", at: "08:00"))
        }
        let week = try await store.agenda(in: LocalDate("2026-10-05")!...LocalDate("2026-10-12")!)
        #expect(week.map(\.item.title) == ["Оплатить хостинг", "Созвон", "Планёрка", "Через неделю", "Планёрка"])
        #expect(week.map(\.isRecurring) == [false, false, true, false, true])
        #expect(week[2].id == "id-1@2026-10-05")
    }

    @Test func skippedOccurrencesDisappearAndDoneOnesCanBeFiltered() async throws {
        let store = try makeStore()
        var daily = reminder("Витамины", on: "2026-10-05", at: "09:00")
        daily.recurrence = Recurrence(freq: .daily)
        let vitamins = daily
        try await store.perform(label: "seed") { try $0.insert(vitamins) }
        try await store.perform(label: "exceptions") { m in
            try m.setException(ItemException(itemID: "id-1", occDate: LocalDate("2026-10-06")!, action: .skip))
            try m.setException(ItemException(itemID: "id-1", occDate: LocalDate("2026-10-07")!, action: .done))
        }
        let range = LocalDate("2026-10-05")!...LocalDate("2026-10-08")!
        let all = try await store.agenda(in: range)
        #expect(all.map { $0.date.description } == ["2026-10-05", "2026-10-07", "2026-10-08"])
        #expect(all.map(\.isDone) == [false, true, false])
        let open = try await store.agenda(in: range, includeDone: false)
        #expect(open.map { $0.date.description } == ["2026-10-05", "2026-10-08"])
    }

    @Test func seriesStartingAfterTheRangeAreIgnored() async throws {
        let store = try makeStore()
        var later = reminder("Потом", on: "2026-12-01")
        later.recurrence = Recurrence(freq: .daily)
        let seed = later
        try await store.perform(label: "seed") { try $0.insert(seed) }
        #expect(try await store.agenda(on: LocalDate("2026-10-05")!).isEmpty)
        #expect(try await store.agenda(on: LocalDate("2026-12-02")!).count == 1)
    }
}
