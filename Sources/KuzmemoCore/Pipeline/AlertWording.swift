import Foundation

extension PlannedAlert {
    /// What sort of alert it is, for a list: "5 minutes before", "At the scheduled time", "All-day item".
    public var kindText: String {
        switch kind {
        case .headsUp: Wording.leadBefore(leadMinutes).capitalizedFirstLetter
        case .atTime: tr("At the scheduled time")
        case .allDay: tr("All-day item")
        }
    }

    /// When it goes off, read on the wall clock of `timeZone`: "Today, 14:25", "Tomorrow, 09:00", "On Friday, October 2, 09:00".
    public func whenText(now: Date, in timeZone: TimeZone) -> String {
        let moment = LocalDateTime(date: fireAt, in: timeZone)
        let today = LocalDateTime(date: now, in: timeZone).date
        return "\(Wording.relativeDay(moment.date, today: today).capitalizedFirstLetter), \(moment.time)"
    }
}
