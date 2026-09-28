import Foundation
import Testing
@testable import KuzmemoCore

private let today = LocalDate("2026-09-28")!

private func change(_ kind: AppliedChange.Kind, _ item: Item, occurrence: String? = nil, newDate: String? = nil, newTime: String? = nil) -> AppliedChange {
    AppliedChange(kind: kind, item: item, occurrenceDate: occurrence.flatMap(LocalDate.init),
                  newDate: newDate.flatMap(LocalDate.init), newTime: newTime.flatMap(LocalTime.init))
}

@Suite("Summary text")
struct SummaryTests {
    @Test func createdItemsDescribeKindWhenAndTitle() {
        let reminder = Item(id: "1", kind: .reminder, title: "Сказать Дмитрию про доступ", date: LocalDate("2026-09-30"))
        #expect(change(.created, reminder).summary(today: today) == "Напоминание · послезавтра · «Сказать Дмитрию про доступ»")
        let event = Item(id: "2", kind: .event, title: "Созвон", date: LocalDate("2026-09-29"), time: LocalTime("11:00"))
        #expect(change(.created, event).summary(today: today) == "Событие · завтра в 11:00 · «Созвон»")
        let note = Item(id: "3", kind: .note, title: "Идея")
        #expect(change(.created, note).summary(today: today) == "Заметка · без даты · «Идея»")
        var weekly = Item(id: "4", kind: .event, title: "Планёрка", date: LocalDate("2026-10-05"), time: LocalTime("10:00"))
        weekly.recurrence = Recurrence(freq: .weekly, byWeekday: [.mon])
        #expect(change(.created, weekly).summary(today: today) == "Событие · 5 октября в 10:00 · каждый понедельник · «Планёрка»")
    }

    @Test func otherChangesAreShort() {
        let item = Item(id: "1", kind: .event, title: "Встреча", date: LocalDate("2026-10-01"), time: LocalTime("15:00"))
        #expect(change(.updated, item).summary(today: today) == "Изменено · «Встреча» · в четверг, 1 октября в 15:00")
        #expect(change(.moved, item, occurrence: "2026-10-05", newDate: "2026-10-07", newTime: "16:00").summary(today: today)
            == "Перенесено · «Встреча» · на 7 октября в 16:00")
        #expect(change(.moved, item, occurrence: "2026-10-05", newDate: "2026-10-02", newTime: "15:00").summary(today: today)
            == "Перенесено · «Встреча» · на пятницу, 2 октября в 15:00")
        #expect(change(.moved, item, occurrence: "2026-10-05", newDate: "2026-09-29").summary(today: today)
            == "Перенесено · «Встреча» · на завтра в 15:00")
        #expect(change(.completed, item).summary(today: today) == "Выполнено · «Встреча»")
        #expect(change(.completed, item, occurrence: "2026-10-05").summary(today: today) == "Выполнено · «Встреча» · 5 октября")
        #expect(change(.reopened, item).summary(today: today) == "Возвращено · «Встреча»")
        #expect(change(.deleted, item).summary(today: today) == "Удалено · «Встреча»")
        #expect(change(.skipped, item, occurrence: "2026-10-12").summary(today: today) == "Пропущено · «Встреча» · 12 октября")
    }

    @Test func recurrenceRulesReadNaturally() {
        #expect(RussianFormat.recurrence(Recurrence(freq: .daily)) == "каждый день")
        #expect(RussianFormat.recurrence(Recurrence(freq: .daily, interval: 3)) == "каждые 3 дня")
        #expect(RussianFormat.recurrence(Recurrence(freq: .weekly, byWeekday: [.mon, .tue, .wed, .thu, .fri])) == "по будням")
        #expect(RussianFormat.recurrence(Recurrence(freq: .weekly, byWeekday: [.wed])) == "каждую среду")
        #expect(RussianFormat.recurrence(Recurrence(freq: .weekly, byWeekday: [.sun])) == "каждое воскресенье")
        #expect(RussianFormat.recurrence(Recurrence(freq: .weekly, byWeekday: [.mon, .thu])) == "каждую неделю по пн, чт")
        #expect(RussianFormat.recurrence(Recurrence(freq: .weekly, interval: 2, byWeekday: [.fri])) == "каждые 2 недели по пт")
        #expect(RussianFormat.recurrence(Recurrence(freq: .weekly)) == "каждую неделю")
        #expect(RussianFormat.recurrence(Recurrence(freq: .monthly, byMonthday: 25)) == "каждый месяц, 25-го числа")
        #expect(RussianFormat.recurrence(Recurrence(freq: .monthly, interval: 2)) == "каждые 2 месяца")
        #expect(RussianFormat.recurrence(Recurrence(freq: .yearly)) == "каждый год")
    }
}
