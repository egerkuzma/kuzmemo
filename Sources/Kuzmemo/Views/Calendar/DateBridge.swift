import Foundation
import KuzmemoCore

/// Conversions between the app's floating dates and times and the `Date` values that SwiftUI pickers use. Both sides
/// are read in the device's time zone, so nothing shifts.
enum DateBridge {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = locale
        calendar.firstWeekday = 2
        return calendar
    }

    /// Noon of the day, so a daylight-saving shift can never move it to another date.
    static func date(_ local: LocalDate) -> Date {
        calendar.date(from: DateComponents(year: local.year, month: local.month, day: local.day, hour: 12)) ?? Date()
    }

    static func localDate(_ date: Date) -> LocalDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1) ?? LocalDate(epochDay: 0)
    }

    static func date(_ time: LocalTime) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    static func localTime(_ date: Date) -> LocalTime {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return LocalTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) ?? LocalTime(hour: 0, minute: 0)!
    }

    /// The locale that pickers and formatted times use: the interface language's, with a Monday-first week and 24-hour
    /// times like the rest of the app (which is why English is British English here).
    static var locale: Locale {
        switch Localization.current {
        case .russian: Locale(identifier: "ru_RU")
        case .english: Locale(identifier: "en_GB")
        }
    }
}
