import Foundation
import GRDB
import UserNotifications
import Testing
@testable import Kuzmemo
import KuzmemoCore

@MainActor
@Suite("Settings load failures and retained edits")
struct AppSettingsTests {
    private func store() throws -> Store { Store(writer: try KuzmemoDatabase.inMemory()) }

    @Test func aFailedReadDoesNotAuthorizeDefaultsAndCanBeRetried() async throws {
        let store = try store()
        var off = NotificationSettings(); off.enabled = false
        try await store.save(settings: off)
        try await store.writer.write { db in try db.execute(sql: "ALTER TABLE kv RENAME TO unreadable_settings") }
        let settings = AppSettings(store: store)
        var notificationsObserved = false
        settings.observe { if $0 == .notifications { notificationsObserved = true } }
        await settings.load()
        #expect(!settings.isLoaded(.notifications) && !notificationsObserved && settings.lastReadError != nil)
        try await store.writer.write { db in try db.execute(sql: "ALTER TABLE unreadable_settings RENAME TO kv") }
        await settings.load()
        #expect(settings.loaded && settings.isLoaded(.notifications) && !settings.notifications.enabled)
        #expect(notificationsObserved && settings.lastReadError == nil)
        #expect(await settings.flush()) // cancels the scheduled read retry too
    }

    @Test func aFailedWriteStaysDirtyUntilTheSameValueIsSaved() async throws {
        let store = try store()
        let settings = AppSettings(store: store)
        await settings.load()
        try await store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER no_settings BEFORE INSERT ON kv BEGIN SELECT RAISE(ABORT, 'cannot write settings'); END")
        }
        settings.notifications.enabled = false
        #expect(await settings.flush() == false)
        #expect(settings.lastSaveError != nil)
        #expect(try await store.loadSettings(NotificationSettings.self).enabled)
        try await store.writer.write { db in try db.execute(sql: "DROP TRIGGER no_settings") }
        #expect(await settings.flush())
        #expect(settings.lastSaveError == nil && !settings.notifications.enabled)
        #expect(try await store.loadSettings(NotificationSettings.self).enabled == false)
    }

    @Test func flushSavesTheLatestEditOfEveryDirtyGroup() async throws {
        let store = try store()
        let settings = AppSettings(store: store)
        await settings.load()
        settings.notifications.enabled = false
        settings.notifications.enabled = true
        settings.recording.maxSeconds = 90
        #expect(await settings.flush())
        #expect(try await store.loadSettings(NotificationSettings.self).enabled)
        #expect(try await store.loadSettings(RecordingSettings.self).maxSeconds == 90)
    }
}

@MainActor
@Suite("Notification trigger instants")
struct NotificationTriggerTests {
    @Test func bothReadingsOfADstFoldKeepTheirPlannedInstant() throws {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let now = FixedNow(local: "2026-10-25 00:30", in: zone)!.now()
        let first = FixedNow(local: "2026-10-25 02:30", in: zone)!.now()
        for instant in [first, first.addingTimeInterval(3600)] {
            let trigger = NotificationRequestBuilder.trigger(at: instant, now: now, timeZone: zone)
            let interval = try #require(trigger as? UNTimeIntervalNotificationTrigger)
            #expect(interval.timeInterval == instant.timeIntervalSince(now))
        }
    }
}
