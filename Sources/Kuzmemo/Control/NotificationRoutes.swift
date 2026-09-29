import Foundation
import KuzmemoCore
import UserNotifications

/// Control-channel view of the notification plan. The automation build never talks to the notification center, so
/// the requests listed here are what *would* be handed to it: built by the same code, but not delivered.
enum NotificationRoutes {
    /// The permission, the settings that matter, and the next `limit` planned alerts with their requests.
    static func state(_ request: HTTPRequest, _ env: AppEnvironment) -> HTTPResponse {
        guard let scheduler = env.notifications else { return .error("notifications are not set up", status: 503) }
        let limit = min(max(Int(request.query["limit"] ?? "") ?? 20, 0), 60)
        let now = env.clock.now()
        let zone = env.clock.timeZone
        let alerts = scheduler.planned
        let described = alerts.prefix(limit).map { alert -> [String: Any] in
            let built = NotificationRequestBuilder.request(for: alert, now: now, timeZone: zone)
            return [
                "id": alert.id, "item": alert.itemID, "title": alert.title, "subtitle": alert.subtitle, "body": alert.body,
                "kind": alert.kind.rawValue, "kindText": alert.kindText, "lead": alert.leadMinutes,
                "fireAt": "\(LocalDateTime(date: alert.fireAt, in: zone))", "when": alert.whenText(now: now, in: zone),
                "silent": alert.silent, "sound": ["kind": alert.sound.kind.rawValue, "name": alert.sound.name],
                "soundFile": SoundCatalog.notificationSoundName(for: alert.silent ? .silent : alert.sound) ?? NSNull(),
                "trigger": NotificationRequestBuilder.describe(built.trigger), "category": built.content.categoryIdentifier,
                "thread": built.content.threadIdentifier,
            ]
        }
        let lastSync: Any = scheduler.lastSync.map { "\(LocalDateTime(date: $0, in: zone))" } ?? NSNull()
        let lastError: Any = scheduler.lastError ?? NSNull()
        return .json([
            "access": "\(scheduler.access)", "isLive": scheduler.isLive, "enabled": env.settings.notifications.enabled,
            "count": alerts.count, "alerts": described, "lastSync": lastSync, "lastError": lastError,
        ])
    }

    /// Plans again now (the settings and the calendar do this by themselves a moment after a change).
    static func sync(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        await env.notifications?.sync()
        return state(request, env)
    }
}
