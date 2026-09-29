import Foundation

extension PlannedAlert {
    /// What sort of alert it is, for a list: "За 5 минут", "В назначенное время", "Дело на весь день".
    public var kindText: String {
        switch kind {
        case .headsUp: RussianFormat.leadBefore(leadMinutes).capitalizedFirstLetter
        case .atTime: "В назначенное время"
        case .allDay: "Дело на весь день"
        }
    }

    /// When it goes off, read on the wall clock of `timeZone`: "Сегодня, 14:25", "Завтра, 09:00", "В пятницу, 2 октября, 09:00".
    public func whenText(now: Date, in timeZone: TimeZone) -> String {
        let moment = LocalDateTime(date: fireAt, in: timeZone)
        let today = LocalDateTime(date: now, in: timeZone).date
        return "\(RussianFormat.relativeDay(moment.date, today: today).capitalizedFirstLetter), \(moment.time)"
    }
}
