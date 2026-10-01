import AppKit
import Foundation
import KuzmemoCore
import Observation
import UserNotifications

/// Keeps the system's notifications in step with the calendar. It plans the alerts (`AlertPlanner`), compares them
/// with what the notification center already holds and adds or removes the difference, on launch, whenever the
/// calendar or the notification settings change, after sleep and periodically. Delivery itself belongs to the system,
/// so alerts arrive even when the app is not running.
///
/// The automation build only plans (no request to the system, no permission prompt): it must never show anything to
/// the person, and its pinned clock would make the times meaningless.
@Observable
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    enum Access: Equatable { case unknown, notDetermined, denied, allowed }

    private(set) var access: Access = .unknown
    /// Everything planned for the coming days, soonest first.
    private(set) var planned: [PlannedAlert] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    @ObservationIgnored private unowned let env: AppEnvironment
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var voice: Task<Void, Never>?
    @ObservationIgnored private var spoken: Set<String> = []
    /// Alerts this session has already handed to the system. One whose moment has just passed is not pending any more (it
    /// has fired), and the planner still lists it for half a minute: without this note any sync in that half minute would
    /// add it again with a one-second trigger and the person would get a second banner and a second sound.
    @ObservationIgnored private var submitted: Set<String> = []

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    /// Talking to the system needs a real app bundle and is off in the automation build.
    var isLive: Bool { !AppPaths.isAutomation && Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: - Lifecycle

    func start() {
        if isLive {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            registerCategories()
            Task { @MainActor in
                await refreshAccess()
                if access == .notDetermined { _ = await requestAccess() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSync(after: .seconds(2)) }
        }
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                self?.requestSync()
            }
        }
    }

    // MARK: - Permission

    func refreshAccess() async {
        guard isLive else { access = .unknown; return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: access = .notDetermined
        case .denied: access = .denied
        default: access = .allowed
        }
    }

    @discardableResult
    func requestAccess() async -> Bool {
        guard isLive else { return false }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshAccess()
        requestSync()
        return access == .allowed
    }

    // MARK: - Syncing

    /// Plans again shortly (calendar edits often come in bursts).
    func requestSync(after delay: Duration = .milliseconds(800)) {
        pendingSync?.cancel()
        pendingSync = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // The sync is not a child of this task: a later request cancels the one that is waiting, and the database reads of
            // a cancelled task throw. The old code read that as "no entries" and removed every pending alert and snooze.
            await Task { @MainActor in await self?.sync() }.value
        }
    }

    func sync() async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await performSync()
        } while again
    }

    private func performSync() async {
        let settings = env.settings.notifications
        let now = env.clock.now()
        let zone = env.clock.timeZone
        let today = env.clock.localNow().date
        // A calendar that cannot be read is not an empty calendar: the system keeps what it holds until a read works.
        let entries: [AgendaEntry]
        do {
            entries = try await env.store.agenda(in: today ... today.adding(days: settings.horizonDays), includeDone: false)
        } catch {
            lastError = "\(error)"
            return
        }
        planned = AlertPlanner.plan(entries: entries, settings: settings, now: now, timeZone: zone)
        submitted.formIntersection(planned.map(\.id))
        lastSync = now
        scheduleVoice(settings)
        guard isLive else { return }
        registerCategories()
        await refreshAccess()
        guard access == .allowed else { return }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = Set(await center.deliveredNotifications().map(\.request.identifier))
        let diff = AlertDiff(planned: planned, pendingIDs: Set(pending.map(\.identifier)))
        if !diff.toRemove.isEmpty { center.removePendingNotificationRequests(withIdentifiers: diff.toRemove) }
        lastError = nil
        for alert in diff.toAdd {
            // An alert whose moment has come and that was handed over already (or is on screen) has fired: it is not pending
            // for that reason, and adding it again would show it again.
            if alert.fireAt <= now.addingTimeInterval(1), submitted.contains(alert.id) || delivered.contains(alert.id) { continue }
            do {
                try await center.add(NotificationRequestBuilder.request(for: alert, now: now, timeZone: zone))
                submitted.insert(alert.id)
            } catch {
                lastError = "\(error)"
            }
        }
        await dropSnoozesOfFinishedEntries(pending)
    }

    /// A snoozed reminder for something that was done or deleted meanwhile must not ring.
    private func dropSnoozesOfFinishedEntries(_ pending: [UNNotificationRequest]) async {
        var stale: [String] = []
        for request in pending where request.identifier.hasPrefix(NotificationRequestBuilder.snoozePrefix) {
            let info = request.content.userInfo
            guard let itemID = info["itemID"] as? String else { continue }
            // "No such entry" ends the snooze; a read that failed says nothing, and the snooze stays.
            let found: Item?
            do { found = try await env.store.item(id: itemID) } catch { continue }
            guard let item = found else { stale.append(request.identifier); continue }
            if item.recurrence == nil, item.status == .done { stale.append(request.identifier) }
        }
        if !stale.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale) }
    }

    // MARK: - Categories (the buttons on a notification)

    func registerCategories() {
        guard isLive else { return }
        let done = UNNotificationAction(identifier: "done", title: tr("Done"), options: [])
        let snoozes = env.settings.notifications.snoozeMinutes.map { minutes in
            UNNotificationAction(
                identifier: "snooze-\(minutes)",
                title: tr("Snooze for %1$@", Wording.duration(minutes: minutes)), options: []
            )
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: NotificationRequestBuilder.category, actions: [done] + snoozes, intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - Test

    /// Shows a notification in a second with the given sound, so the person can see and hear a setting.
    /// Returns a message when it cannot be shown.
    func sendTest(sound: AlertSound) async -> String? {
        guard isLive else { return tr("System notifications are turned off in this build.") }
        await refreshAccess()
        if access == .notDetermined { _ = await requestAccess() }
        guard access == .allowed else { return tr("Notifications are blocked: allow them in System Settings → Notifications → Kuzmemo.") }
        do {
            try await UNUserNotificationCenter.current().add(NotificationRequestBuilder.test(
                sound: sound, title: tr("Notification test"), body: tr("This is how a reminder will look · %1$@", "\(SoundCatalog.title(for: sound))")
            ))
            return nil
        } catch {
            return tr("Could not show the notification: %1$@", "\(error.localizedDescription)")
        }
    }

    // MARK: - Speaking the title (only while the app is running)

    private func scheduleVoice(_ settings: NotificationSettings) {
        voice?.cancel()
        voice = nil
        guard settings.speakTitle else { return }
        let now = env.clock.now()
        guard let next = planned.first(where: { $0.fireAt >= now.addingTimeInterval(-5) && !$0.silent && !spoken.contains($0.id) }) else { return }
        voice = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.fireAt.timeIntervalSince(now))))
            guard !Task.isCancelled, let self else { return }
            spoken.insert(next.id)
            // The sleep runs on the clock that stops while the Mac sleeps: a title due an hour ago must not be read out at wake.
            guard env.clock.now().timeIntervalSince(next.fireAt) < 60 else { return }
            let glossary = (try? await env.store.glossary()) ?? []
            let title = Glossary.spokenForm(of: next.title, terms: glossary)
            let phrase: String = switch next.kind {
            case .headsUp: tr("%1$@: %2$@", Wording.leadPhrase(next.leadMinutes), title)
            case .atTime: tr("Now: %1$@", title)
            case .allDay: tr("Reminder for today: %1$@", title)
            }
            await env.voice.speech.speak(phrase)
            requestSync(after: .seconds(1))
        }
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        // Only plain strings cross into the main actor (the notification objects are not Sendable).
        let info = (content.userInfo as? [String: String]) ?? [:]
        let title = content.title, subtitle = content.subtitle, thread = content.threadIdentifier
        await MainActor.run {
            self.handle(action: action, title: title, subtitle: subtitle, thread: thread, info: info)
        }
    }

    @MainActor
    private func handle(action: String, title: String, subtitle: String, thread: String, info: [String: String]) {
        let itemID = info["itemID"] ?? ""
        let occurrence = info["occurrence"] ?? ""
        let entryDate = info["entryDate"] ?? ""
        switch action {
        case "done":
            guard !itemID.isEmpty else { return }
            env.act {
                let result = try await self.env.store.perform(
                    .complete(itemID: itemID, occurrenceDate: LocalDate(occurrence)), label: tr("Completed from a notification")
                )
                return ActionOutcome(op: result.op, lines: result.changes.map { $0.summary(today: self.env.clock.localNow().date) })
            }
        case let name where name.hasPrefix("snooze-"):
            let minutes = Int(name.dropFirst(7)) ?? 10
            // A snooze that lands inside the quiet hours is silent, like every other alert there.
            let settings = env.settings.notifications
            let rings = !settings.quietHours.contains(env.clock.localNow().adding(minutes: minutes).time)
            let request = NotificationRequestBuilder.snooze(
                title: title, subtitle: subtitle, thread: thread, info: info, minutes: minutes, sound: rings ? settings.atTimeSound : .silent
            )
            UNUserNotificationCenter.current().add(request) { _ in }
        case UNNotificationDefaultActionIdentifier:
            if let date = LocalDate(entryDate) { env.calendar.select(date) }
            env.showMainWindow()
        default:
            break
        }
    }
}
