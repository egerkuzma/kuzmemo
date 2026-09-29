import Foundation
import KuzmemoCore

/// Demo data for looking at the window from the control channel (dev bundle only): a believable working week, relative
/// to the pinned clock, with done and overdue entries, series, undated notes and failed memos. The texts follow the
/// interface language so that screenshots can be taken in either.
enum DevSeed {
    /// `english` in English, `russian` in Russian: the demo texts are data of this seed, not interface strings.
    private static func text(_ english: String, _ russian: String) -> String {
        Localization.current == .russian ? russian : english
    }

    static func run(_ env: AppEnvironment) async throws {
        let store = env.store
        let today = env.clock.localNow().date
        func day(_ offset: Int) -> LocalDate { today.adding(days: offset) }
        func at(_ text: String) -> LocalTime { LocalTime(text)! }

        let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]
        _ = try await store.create(ItemDraft(
            kind: .event, title: text("Team standup", "Планёрка"), details: text("Tasks, deadlines, the plan for the day", "Задачи, сроки, план на день"),
            date: day(0), time: at("10:00"), durationMin: 30, recurrence: Recurrence(freq: .weekly, byWeekday: weekdays)
        ))
        _ = try await store.create(ItemDraft(kind: .event, title: text("Call with Acme", "Созвон с Acme"), date: day(0), time: at("11:00"), durationMin: 45, remindLeadMin: 15), source: .voice)
        let subscription = try await store.create(ItemDraft(
            kind: .reminder, title: text("Check the Notion subscription", "Проверить подписку в Notion"), date: day(0), time: at("13:30")
        ), source: .voice).item
        _ = try await store.create(ItemDraft(
            kind: .task, title: text("Reply to the client about the checklist", "Ответить клиенту про чеклист"),
            details: text("Attach the screenshots for each section", "Приложить скриншоты по разделам"), date: day(0), time: at("16:00")
        ))
        _ = try await store.create(ItemDraft(kind: .reminder, title: text("Pay for hosting: 340 dollars", "Оплатить хостинг: 340 долларов"), date: day(0)), source: .voice)
        _ = try await store.create(ItemDraft(
            kind: .task, title: text("Check the project statistics", "Проверить статистику по проектам"), date: day(0), time: at("18:00"), recurrence: Recurrence(freq: .daily)
        ), source: .voice)

        _ = try await store.create(ItemDraft(
            kind: .event, title: text("Meeting with Dmitry", "Встреча с Дмитрием"),
            details: text("Discuss access to Notion and the deadlines", "Обсудить доступ в Notion и сроки"), date: day(1), time: at("15:00"), durationMin: 60
        ), source: .voice)
        _ = try await store.create(ItemDraft(
            kind: .reminder, title: text("Tell Dmitry about access to Notion", "Сказать Дмитрию про доступ в Notion"), date: day(2)
        ), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: text("Update the Q4 mockups", "Обновить макеты для Q4"), date: day(3)))
        _ = try await store.create(ItemDraft(kind: .event, title: text("Project review on GitHub", "Ревью проектов в GitHub"), date: day(5), time: at("12:00"), durationMin: 60))
        _ = try await store.create(ItemDraft(kind: .reminder, title: text("Renew the domain", "Продлить домен"), date: day(9)), source: .voice)
        _ = try await store.create(ItemDraft(
            kind: .reminder, title: text("Pay for hosting", "Оплатить хостинг"),
            date: today.firstOfMonth.adding(days: 24).adding(months: today.day > 25 ? 1 : 0), recurrence: Recurrence(freq: .monthly, byMonthday: 25)
        ))

        _ = try await store.create(ItemDraft(kind: .reminder, title: text("Reconcile the Slack report", "Сверить отчёт по Slack"), date: day(-3)), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: text("Send the invoice", "Отправить счёт"), date: day(-1), time: at("12:00")))

        _ = try await store.create(ItemDraft(kind: .note, title: text("Idea: try a new running route", "Идея: попробовать новый маршрут для пробежки")), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: text("Sort out the Q4 mockups", "Разобрать макеты для Q4")))

        _ = try await store.perform(.complete(itemID: subscription.id, occurrenceDate: nil), label: "seed")

        let anchor = "\(today) \(env.clock.localNow().time)"
        let soon = Int64(Date().addingTimeInterval(90).timeIntervalSince1970 * 1000)
        try await store.save(memo: Memo(
            id: "seed-1", createdAt: Int64(Date().timeIntervalSince1970 * 1000), anchorLocal: anchor, tz: env.clock.timeZone.identifier,
            inputKind: .voice, status: .failed,
            transcriptRaw: text("remind me on Wednesday to check the Notion subscription", "напомни мне в среду проверить подписку в Notion"),
            failStage: "llm", failReason: "timedOut(seconds: 30.0)", attempts: 1, nextRetryAt: soon
        ))
        try await store.save(memo: Memo(
            id: "seed-2", createdAt: Int64(Date().timeIntervalSince1970 * 1000) - 5, anchorLocal: anchor, tz: env.clock.timeZone.identifier,
            inputKind: .voice, status: .failed, failStage: "stt", failReason: "modelMissing(\"/nowhere\")", attempts: 1
        ))
    }
}
