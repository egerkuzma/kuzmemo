import Foundation
import Testing
@testable import KuzmemoCore

private let moscow = TimeZone(identifier: "Europe/Moscow")!

/// "Now" is Monday 2026-09-28 12:00 Moscow unless a test says otherwise.
private func instant(_ local: String) -> Date { FixedNow(local: local, in: moscow)!.now() }

private func entry(
    _ title: String, kind: ItemKind = .reminder, on date: String, at time: String? = nil, lead: Int = 0,
    done: Bool = false, occurrence: String? = nil, id: String? = nil
) -> AgendaEntry {
    let item = Item(id: id ?? "id-\(title)", kind: kind, title: title, date: LocalDate(date), time: time.flatMap(LocalTime.init), remindLeadMin: lead)
    return AgendaEntry(item: item, date: LocalDate(date)!, time: item.time, isDone: done, occurrenceDate: occurrence.flatMap(LocalDate.init), wasMoved: false)
}

private func plan(_ entries: [AgendaEntry], _ settings: NotificationSettings = NotificationSettings(), now: String = "2026-09-28 12:00", limit: Int = 60) -> [PlannedAlert] {
    AlertPlanner.plan(entries: entries, settings: settings, now: instant(now), timeZone: moscow, limit: limit)
}

private func local(_ alert: PlannedAlert) -> String {
    let parts = Calendar(identifier: .gregorian).dateComponents(in: moscow, from: alert.fireAt)
    return String(format: "%04d-%02d-%02d %02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!)
}

@Suite("AlertPlanner")
struct AlertPlannerTests {
    @Test func anEventGetsAWarningAheadAndAnAlertAtTheStart() {
        let alerts = plan([entry("Созвон с Acme", kind: .event, on: "2026-09-29", at: "11:00")])
        #expect(alerts.map(local) == ["2026-09-29 10:55", "2026-09-29 11:00"])
        #expect(alerts.map(\.kind) == [.headsUp, .atTime])
        #expect(alerts.map(\.body) == ["Через 5 минут · 11:00", "Сейчас · 11:00"])
        #expect(alerts.map(\.subtitle) == ["Событие", "Событие"] && alerts.allSatisfy { $0.title == "Созвон с Acme" })
        #expect(alerts[0].sound == NotificationSettings().headsUpSound && alerts[1].sound == NotificationSettings().atTimeSound)
    }

    @Test func remindersAndTasksWithATimeAlertAtThatTimeOnlyByDefault() {
        let alerts = plan([entry("Позвонить в банк", on: "2026-09-28", at: "16:00"), entry("Ответить клиенту", kind: .task, on: "2026-09-28", at: "17:30")])
        #expect(alerts.map(local) == ["2026-09-28 16:00", "2026-09-28 17:30"] && alerts.allSatisfy { $0.kind == .atTime })
    }

    @Test func leadTimesAreConfigurableSeparatelyForEventsAndReminders() {
        var settings = NotificationSettings()
        settings.eventLeads = [15, 10, 0]
        settings.reminderLeads = [5, 0]
        let alerts = plan([
            entry("Встреча", kind: .event, on: "2026-09-28", at: "15:00"), entry("Оплатить", on: "2026-09-28", at: "18:00"),
        ], settings)
        #expect(alerts.map(local) == ["2026-09-28 14:45", "2026-09-28 14:50", "2026-09-28 15:00", "2026-09-28 17:55", "2026-09-28 18:00"])
        #expect(alerts.map(\.body) == ["Через 15 минут · 15:00", "Через 10 минут · 15:00", "Сейчас · 15:00", "Через 5 минут · 18:00", "Сейчас · 18:00"])
    }

    @Test func anEntrysOwnEarlyReminderIsAddedToTheDefaults() {
        let alerts = plan([entry("Отчёт", on: "2026-09-28", at: "18:00", lead: 60), entry("Не дублировать", kind: .event, on: "2026-09-28", at: "19:00", lead: 5)])
        #expect(alerts.map(local) == ["2026-09-28 17:00", "2026-09-28 18:00", "2026-09-28 18:55", "2026-09-28 19:00"]) // lead 5 was already there
    }

    @Test func aDayEntryWithoutATimeIsAnnouncedAtEachChosenTimeOfDay() {
        var settings = NotificationSettings()
        settings.allDayTimes = [LocalTime("09:00")!, LocalTime("14:00")!, LocalTime("18:00")!]
        let alerts = plan([entry("Оплатить хостинг", on: "2026-09-28"), entry("Сказать Дмитрию", on: "2026-09-29")], settings)
        // today it is already past 9:00, so only the later two; tomorrow all three
        #expect(alerts.map(local) == ["2026-09-28 14:00", "2026-09-28 18:00", "2026-09-29 09:00", "2026-09-29 14:00", "2026-09-29 18:00"])
        #expect(alerts.allSatisfy { $0.kind == .allDay && $0.body == "Сегодня · весь день" && $0.sound == settings.allDaySound })
    }

    @Test func anEventWithoutATimeIsNotAnAlarmAndNotesNeverAre() {
        let alerts = plan([entry("Встреча без времени", kind: .event, on: "2026-09-29"), entry("Идея", kind: .note, on: "2026-09-29", at: "10:00")])
        #expect(alerts.isEmpty)
    }

    @Test func doneEntriesDoNotAlert() {
        let alerts = plan([entry("Готово", on: "2026-09-29", at: "10:00", done: true), entry("Не готово", on: "2026-09-29", at: "10:00")])
        #expect(alerts.map(\.title) == ["Не готово"])
    }

    @Test func momentsThatPassedAreLeftOutExceptTheVeryRecentOnes() {
        let entries = [entry("Только что", on: "2026-09-28", at: "12:00"), entry("Давно", on: "2026-09-28", at: "10:00"), entry("Скоро", on: "2026-09-28", at: "12:01")]
        let now = FixedNow(local: "2026-09-28 12:00", in: moscow)!.now()
        let alerts = AlertPlanner.plan(entries: entries, settings: NotificationSettings(), now: now.addingTimeInterval(20), timeZone: moscow)
        #expect(alerts.map(\.title) == ["Только что", "Скоро"]) // 20 s after 12:00 is inside the grace period
        let later = AlertPlanner.plan(entries: entries, settings: NotificationSettings(), now: now.addingTimeInterval(60), timeZone: moscow)
        #expect(later.map(\.title) == ["Скоро"])
    }

    @Test func switchedOffMeansNothing() {
        var settings = NotificationSettings()
        settings.enabled = false
        #expect(plan([entry("Созвон", kind: .event, on: "2026-09-29", at: "11:00")], settings).isEmpty)
    }

    @Test func quietHoursKeepTheAlertButTakeAwayTheSound() {
        var settings = NotificationSettings()
        settings.quietHours.enabled = true
        let alerts = plan([entry("Поздно", on: "2026-09-28", at: "23:30"), entry("Рано", on: "2026-09-29", at: "07:00"), entry("Днём", on: "2026-09-29", at: "13:00")], settings)
        #expect(alerts.map(\.silent) == [true, true, false])
        #expect(QuietHours().contains(LocalTime("03:00")!) == false) // off by default
    }

    @Test func quietHoursMayRunPastMidnightOrStayWithinADay() {
        var hours = QuietHours()
        hours.enabled = true
        #expect(hours.contains(LocalTime("23:00")!) && hours.contains(LocalTime("02:00")!) && hours.contains(LocalTime("07:59")!))
        #expect(!hours.contains(LocalTime("08:00")!) && !hours.contains(LocalTime("12:00")!) && !hours.contains(LocalTime("22:59")!))
        hours.from = LocalTime("13:00")!; hours.to = LocalTime("14:00")!
        #expect(hours.contains(LocalTime("13:30")!) && !hours.contains(LocalTime("14:00")!) && !hours.contains(LocalTime("02:00")!))
    }

    @Test func aRepeatingOccurrenceAlertsAtItsOwnDateAndAMovedOneAtTheNewTime() {
        let moved = AgendaEntry(
            item: Item(id: "s", kind: .event, title: "Планёрка", date: LocalDate("2026-09-21"), time: LocalTime("10:00"), recurrence: Recurrence(freq: .weekly)),
            date: LocalDate("2026-10-01")!, time: LocalTime("16:30"), isDone: false, occurrenceDate: LocalDate("2026-09-28"), wasMoved: true
        )
        let alerts = plan([moved])
        #expect(alerts.map(local) == ["2026-10-01 16:25", "2026-10-01 16:30"])
        #expect(alerts.allSatisfy { $0.occurrenceDate == LocalDate("2026-09-28") && $0.itemID == "s" })
    }

    @Test func aBusyWeekIsCappedAtTheEarliestAlerts() {
        let entries = (0 ..< 100).map { entry("Дело \($0)", on: "2026-09-29", at: String(format: "%02d:%02d", 8 + $0 / 60, $0 % 60)) }
        let alerts = plan(entries, limit: 60)
        #expect(alerts.count == 60 && alerts.first?.title == "Дело 0" && alerts.last?.title == "Дело 59")
    }

    @Test func identifiersAreStableAndChangeWithWhatTheUserSees() {
        let a = plan([entry("Созвон", kind: .event, on: "2026-09-29", at: "11:00", id: "e1")])
        let same = plan([entry("Созвон", kind: .event, on: "2026-09-29", at: "11:00", id: "e1")])
        let renamed = plan([entry("Созвон с Acme", kind: .event, on: "2026-09-29", at: "11:00", id: "e1")])
        var otherSound = NotificationSettings()
        otherSound.atTimeSound = .system("Submarine")
        let resounded = plan([entry("Созвон", kind: .event, on: "2026-09-29", at: "11:00", id: "e1")], otherSound)
        #expect(a.map(\.id) == same.map(\.id) && Set(a.map(\.id)).count == 2)
        #expect(a.allSatisfy { $0.id.hasPrefix(AlertPlanner.idPrefix) })
        #expect(Set(a.map(\.id)).isDisjoint(with: renamed.map(\.id)))
        #expect(Set(a.map(\.id)) != Set(resounded.map(\.id)))
    }

    @Test func theDiffAddsWhatIsMissingRemovesWhatIsStaleAndLeavesForeignRequestsAlone() {
        let planned = plan([entry("Созвон", kind: .event, on: "2026-09-29", at: "11:00", id: "e1")])
        let keep = planned[0].id
        let diff = AlertDiff(planned: planned, pendingIDs: [keep, "kz|old|-|atTime|0|1|x", "kzs|snooze-1", "other-app"])
        #expect(diff.toAdd.map(\.id) == [planned[1].id])
        #expect(diff.toRemove == ["kz|old|-|atTime|0|1|x"]) // snoozes ("kzs|") and foreign ids are not touched
        #expect(AlertDiff(planned: planned, pendingIDs: Set(planned.map(\.id))).toAdd.isEmpty)
    }

    @Test func leadsAreWordedInRussian() {
        #expect(Wording.leadPhrase(0) == "Сейчас" && Wording.leadPhrase(1) == "Через 1 минуту")
        #expect(Wording.leadPhrase(5) == "Через 5 минут" && Wording.leadPhrase(22) == "Через 22 минуты")
        #expect(Wording.leadPhrase(60) == "Через 1 час" && Wording.leadPhrase(120) == "Через 2 часа" && Wording.leadPhrase(300) == "Через 5 часов")
        #expect(Wording.leadPhrase(1440) == "Через 1 день" && Wording.leadPhrase(2880) == "Через 2 дня" && Wording.leadPhrase(90) == "Через 90 минут")
    }

    @Test func chosenLeadsReadAsAList() {
        #expect(Wording.leadBefore(0) == "в момент начала" && Wording.leadBefore(1) == "за 1 минуту")
        #expect(Wording.leadBefore(5) == "за 5 минут" && Wording.leadBefore(60) == "за 1 час" && Wording.leadBefore(1440) == "за 1 день")
        #expect(Wording.leadChip(0) == "В момент" && Wording.leadChip(5) == "5 мин" && Wording.leadChip(90) == "90 мин")
        #expect(Wording.leadChip(60) == "1 час" && Wording.leadChip(120) == "2 часа" && Wording.leadChip(1440) == "1 день")
    }

    @Test func alertsAreDescribedForTheUpcomingList() {
        let alerts = plan([
            entry("Созвон", kind: .event, on: "2026-09-28", at: "15:00"), entry("Сказать Дмитрию", on: "2026-09-29"),
            entry("Отчёт", on: "2026-10-01", at: "10:00"), entry("Оплатить хостинг", on: "2026-10-12", at: "10:00"),
        ], now: "2026-09-28 12:00", limit: 60)
        let now = instant("2026-09-28 12:00")
        #expect(alerts.map { $0.whenText(now: now, in: moscow) } == [
            "Сегодня, 14:55", "Сегодня, 15:00", "Завтра, 09:00", "В четверг, 1 октября, 10:00", "12 октября, 10:00",
        ])
        #expect(alerts.map(\.kindText) == ["За 5 минут", "В назначенное время", "Дело на весь день", "В назначенное время", "В назначенное время"])
    }

    @Test func settingsAreReadForgivingly() async throws {
        let store = try makeStore()
        try await store.setSetting(#"{"eventLeads":[0,10,10,5,-3,99999],"allDayTimes":["18:00","09:00","09:00"],"horizonDays":500,"snoozeMinutes":[60,0,10,10]}"#, for: NotificationSettings.storageKey)
        let settings = await store.settings(NotificationSettings.self)
        #expect(settings.eventLeads == [10, 5, 0])
        #expect(settings.allDayTimes == [LocalTime("09:00")!, LocalTime("18:00")!])
        #expect(settings.horizonDays == 30 && settings.snoozeMinutes == [10, 60])
        #expect(settings.reminderLeads == [0] && settings.enabled) // untouched fields keep their defaults
        var custom = NotificationSettings()
        custom.atTimeSound = .file("/Users/me/Music/ring.aiff"); custom.quietHours.enabled = true; custom.speakTitle = true
        try await store.save(settings: custom)
        #expect(await store.settings(NotificationSettings.self) == custom)
    }
}
