import Foundation
import KuzmemoCore
import UserNotifications

/// Turns a planned alert into the request the system notification center takes. Pure conversion: nothing here talks to
/// the notification center, so it can be inspected (and tested) without showing anything to the person.
enum NotificationRequestBuilder {
    static let category = "kuzmemo.entry"
    static let planPrefix = AlertPlanner.idPrefix
    static let snoozePrefix = "kzs|"
    static let testPrefix = "kzt|"

    static func request(for alert: PlannedAlert, now: Date, timeZone: TimeZone) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.threadIdentifier = "kz-\(alert.entryDate)"
        content.categoryIdentifier = category
        content.userInfo = [
            "itemID": alert.itemID, "occurrence": alert.occurrenceDate.map { "\($0)" } ?? "",
            "entryDate": "\(alert.entryDate)", "kind": alert.kind.rawValue,
        ]
        content.sound = alert.silent ? nil : sound(alert.sound)
        return UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger(at: alert.fireAt, now: now, timeZone: timeZone))
    }

    /// "Remind me again in …": the same notification, later.
    static func snooze(title: String, subtitle: String, thread: String, info: [String: String], minutes: Int, sound choice: AlertSound) -> UNNotificationRequest {
        let again = UNMutableNotificationContent()
        again.title = title
        again.subtitle = subtitle
        again.body = tr("Snoozed · for %1$@", Wording.duration(minutes: minutes))
        again.threadIdentifier = thread
        again.categoryIdentifier = category
        again.userInfo = info
        again.sound = sound(choice)
        return UNNotificationRequest(
            identifier: snoozePrefix + UUID().uuidString, content: again,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        )
    }

    /// A notification that appears in a second, to hear and see how a setting sounds.
    static func test(sound choice: AlertSound, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound(choice)
        return UNNotificationRequest(
            identifier: testPrefix + UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
    }

    /// The chosen sound as a notification sound; a file that cannot be found falls back to the default sound.
    static func sound(_ choice: AlertSound) -> UNNotificationSound? {
        guard choice.kind != .none else { return nil }
        if let name = SoundCatalog.notificationSoundName(for: choice) { return UNNotificationSound(named: UNNotificationSoundName(name)) }
        return .default
    }

    /// An absolute wall-clock time in the device's zone (so a floating "15:00" stays 15:00 wherever the Mac is), or one
    /// second from now when the moment is already here.
    static func trigger(at fireAt: Date, now: Date, timeZone: TimeZone) -> UNNotificationTrigger {
        if fireAt.timeIntervalSince(now) <= 1 { return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        // Components carry their calendar: without it the system reads year 2026 in the person's own calendar (Buddhist,
        // Japanese ...) and the alert never fires. The time zone is left out on purpose: a "15:00" stays 15:00 wherever the Mac is.
        parts.calendar = Calendar(identifier: .gregorian)
        return UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
    }

    /// One line describing a trigger, for logs and the control channel.
    static func describe(_ trigger: UNNotificationTrigger?) -> String {
        if let calendar = trigger as? UNCalendarNotificationTrigger, let parts = Optional(calendar.dateComponents) {
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
        if let interval = trigger as? UNTimeIntervalNotificationTrigger { return "in \(Int(interval.timeInterval)) s" }
        return "none"
    }
}
