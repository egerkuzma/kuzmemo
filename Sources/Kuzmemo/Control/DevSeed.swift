import Foundation
import KuzmemoCore

/// Demo data for looking at the window from the control channel (dev bundle only): a believable week for a media
/// buyer, relative to the pinned clock, with done and overdue entries, series, undated notes and failed memos.
enum DevSeed {
    static func run(_ env: AppEnvironment) async throws {
        let store = env.store
        let today = env.clock.localNow().date
        func day(_ offset: Int) -> LocalDate { today.adding(days: offset) }
        func at(_ text: String) -> LocalTime { LocalTime(text)! }

        let weekdays: [Weekday] = [.mon, .tue, .wed, .thu, .fri]
        _ = try await store.create(ItemDraft(kind: .event, title: "Планёрка", details: "Задачи, сроки, план на день", date: day(0), time: at("10:00"), durationMin: 30,
                                         recurrence: Recurrence(freq: .weekly, byWeekday: weekdays)))
        _ = try await store.create(ItemDraft(kind: .event, title: "Созвон с Acme", date: day(0), time: at("11:00"), durationMin: 45, remindLeadMin: 15), source: .voice)
        let balance = try await store.create(ItemDraft(kind: .reminder, title: "Проверить подписку в Notion", date: day(0), time: at("13:30")), source: .voice).item
        _ = try await store.create(ItemDraft(kind: .task, title: "Ответить клиенту про чеклист", details: "Приложить скриншоты по разделам", date: day(0), time: at("16:00")))
        _ = try await store.create(ItemDraft(kind: .reminder, title: "Оплатить хостинг: 340 долларов", date: day(0)), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: "Проверить статистику по проектам", date: day(0), time: at("18:00"), recurrence: Recurrence(freq: .daily)), source: .voice)

        _ = try await store.create(ItemDraft(kind: .event, title: "Встреча с Дмитрием", details: "Обсудить доступ в Notion и сроки", date: day(1), time: at("15:00"), durationMin: 60), source: .voice)
        _ = try await store.create(ItemDraft(kind: .reminder, title: "Сказать Дмитрию про доступ в Notion", date: day(2)), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: "Обновить макеты для Q4", date: day(3)))
        _ = try await store.create(ItemDraft(kind: .event, title: "Ревью проектов в GitHub", date: day(5), time: at("12:00"), durationMin: 60))
        _ = try await store.create(ItemDraft(kind: .reminder, title: "Продлить домен", date: day(9)), source: .voice)
        _ = try await store.create(ItemDraft(kind: .reminder, title: "Оплатить хостинг", date: today.firstOfMonth.adding(days: 24).adding(months: today.day > 25 ? 1 : 0),
                                         recurrence: Recurrence(freq: .monthly, byMonthday: 25)))

        _ = try await store.create(ItemDraft(kind: .reminder, title: "Сверить отчёт по Slack", date: day(-3)), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: "Отправить счёт", date: day(-1), time: at("12:00")))

        _ = try await store.create(ItemDraft(kind: .note, title: "Идея: попробовать новый маршрут для пробежки"), source: .voice)
        _ = try await store.create(ItemDraft(kind: .task, title: "Разобрать макеты для Q4"))

        _ = try await store.perform(.complete(itemID: balance.id, occurrenceDate: nil), label: "seed")

        let anchor = "\(today) \(env.clock.localNow().time)"
        let soon = Int64(Date().addingTimeInterval(90).timeIntervalSince1970 * 1000)
        try await store.save(memo: Memo(
            id: "seed-1", createdAt: Int64(Date().timeIntervalSince1970 * 1000), anchorLocal: anchor, tz: env.clock.timeZone.identifier,
            inputKind: .voice, status: .failed, transcriptRaw: "напомни мне в среду проверить ставки в GitHub Ads",
            failStage: "llm", failReason: "timedOut(seconds: 30.0)", attempts: 1, nextRetryAt: soon
        ))
        try await store.save(memo: Memo(
            id: "seed-2", createdAt: Int64(Date().timeIntervalSince1970 * 1000) - 5, anchorLocal: anchor, tz: env.clock.timeZone.identifier,
            inputKind: .voice, status: .failed, failStage: "stt", failReason: "modelMissing(\"/nowhere\")", attempts: 1
        ))
    }
}
