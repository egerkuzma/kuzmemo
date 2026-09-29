import AppKit
import KuzmemoCore
import SwiftUI
import UniformTypeIdentifiers

/// System notifications: how early to be told about an event, when to announce entries that have a day but no time,
/// which sounds to use, and what is scheduled next.
struct NotificationsSettingsTab: View {
    let env: AppEnvironment
    @State private var testMessage: String?
    @State private var tidyTask: Task<Void, Never>?

    private var scheduler: NotificationScheduler { env.notifications }

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section(tr("System notifications")) {
                Toggle(tr("Remind with notifications"), isOn: $settings.notifications.enabled)
                PermissionRow(title: tr("macOS permission"), state: scheduler.permissionState, action: scheduler.permissionAction)
                permissionHint
            }
            Group {
                Section(tr("Meetings and calls")) {
                    Hint(tr("Entries of the “event” type: “team sync tomorrow at 11”, “stand-up on Monday at 10”. Kuzmemo decides the type from your phrase; it is shown in the calendar and can be changed in the entry editor. You can be warned ahead of a meeting and once more when it starts."))
                    LeadChips(choices: Self.choices(settings.notifications.eventLeads), selection: $settings.notifications.eventLeads)
                    Hint(Self.summary(settings.notifications.eventLeads, whenEmpty: tr("No notifications about events.")))
                }
                Section(tr("Reminders and tasks")) {
                    Hint(tr("With an exact time: “remind me to call the bank at 4 pm”, “answer the client at 5:30 pm”. A signal at the right moment is usually enough."))
                    LeadChips(choices: Self.choices(settings.notifications.reminderLeads), selection: $settings.notifications.reminderLeads)
                    Hint(Self.summary(settings.notifications.reminderLeads, whenEmpty: tr("No notifications about reminders.")))
                    Hint(tr("In the editor, an individual entry can get one more early alert."))
                }
                Section(tr("All-day items")) {
                    Hint(tr("Reminders and tasks with a date but no time: “remind me the day after tomorrow to pay for hosting”. Until the item is done, Kuzmemo reminds you about it at these times:"))
                    TimeList(times: $settings.notifications.allDayTimes, limit: 6)
                    Hint(Self.allDaySummary(settings.notifications.allDayTimes))
                    Hint(tr("Notes and events without a time never notify."))
                }
                Section(tr("Sounds")) {
                    SoundRow(title: tr("In advance"), detail: tr("like “meeting in 5 minutes” in Zoom"), sound: $settings.notifications.headsUpSound)
                    SoundRow(title: tr("At the scheduled time"), detail: tr("the meeting itself or the reminder"), sound: $settings.notifications.atTimeSound)
                    SoundRow(title: tr("All-day items"), detail: tr("the “for today” reminder"), sound: $settings.notifications.allDaySound)
                    HStack {
                        testMenu(settings.notifications)
                        if let testMessage { Hint(testMessage) }
                    }
                    if AppPaths.isAutomation { Hint(tr("Sound and notifications are off in this build (they are used for automated checks).")) }
                }
                Section(tr("More")) {
                    Toggle(tr("Read the title aloud"), isOn: $settings.notifications.speakTitle)
                    Hint(tr("With the voice chosen in the Speech tab, while Kuzmemo is running."))
                    Toggle(tr("Quiet hours: no sound"), isOn: $settings.notifications.quietHours.enabled.animation())
                    if settings.notifications.quietHours.enabled {
                        LabeledContent(tr("From")) { TimeField(time: $settings.notifications.quietHours.from) }
                        LabeledContent(tr("Until")) { TimeField(time: $settings.notifications.quietHours.to) }
                        Hint(tr("During this time notifications still arrive, but without sound and without reading aloud."))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Snooze buttons on the notification"))
                        LeadChips(choices: Self.snoozeChoices(settings.notifications.snoozeMinutes), selection: $settings.notifications.snoozeMinutes, limit: 3)
                        Hint(tr("Up to three. There is always a “Done” button next to them."))
                    }
                }
            }
            .disabled(!settings.notifications.enabled)
            upcomingSection(settings.notifications)
        }
        .formStyle(.grouped)
        .task { await scheduler.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await scheduler.refreshAccess() }
        }
        .onChange(of: settings.notifications.allDayTimes) { tidyLater() }
    }

    // MARK: Permission

    @ViewBuilder private var permissionHint: some View {
        if scheduler.isLive, scheduler.access == .denied {
            Hint(tr("Notifications for Kuzmemo are turned off. Turn them on in System Settings → Notifications → Kuzmemo (“Allow notifications”)."))
        } else {
            Hint(tr("Notifications are shown by macOS itself, so they arrive on time even when Kuzmemo is not running. The style (banner or alert) is set in System Settings → Notifications → Kuzmemo."))
        }
        if let error = scheduler.lastError { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
    }

    // MARK: Test

    private func testMenu(_ settings: NotificationSettings) -> some View {
        Menu {
            Button(tr("As before an event · %1$@", "\(SoundCatalog.title(for: settings.headsUpSound))")) { test(settings.headsUpSound) }
            Button(tr("As at the scheduled time · %1$@", "\(SoundCatalog.title(for: settings.atTimeSound))")) { test(settings.atTimeSound) }
            Button(tr("As for an all-day item · %1$@", "\(SoundCatalog.title(for: settings.allDaySound))")) { test(settings.allDaySound) }
        } label: {
            Label(tr("Test notification"), systemImage: "bell.badge")
        }
        .fixedSize()
    }

    private func test(_ sound: AlertSound) {
        Task {
            testMessage = await scheduler.sendTest(sound: sound) ?? tr("The notification will appear in a second.")
            try? await Task.sleep(for: .seconds(6))
            testMessage = nil
        }
    }

    // MARK: Upcoming

    @ViewBuilder private func upcomingSection(_ settings: NotificationSettings) -> some View {
        let alerts = scheduler.planned
        let shown = 8
        Section(tr("Upcoming notifications")) {
            if !settings.enabled {
                Hint(tr("Notifications are turned off."))
            } else if alerts.isEmpty {
                Hint(tr("Nothing scheduled yet: no entries in the next %1$lld days.", numbers: settings.horizonDays))
            }
            ForEach(alerts.prefix(shown)) { alert in
                UpcomingRow(alert: alert, now: env.clock.now(), timeZone: env.clock.timeZone)
            }
            if alerts.count > shown { Hint(tr("…and %1$lld more", numbers: alerts.count - shown)) }
        }
    }

    // MARK: Helpers

    /// The times of day are kept sorted and without repeats, but only once the person has stopped editing.
    private func tidyLater() {
        tidyTask?.cancel()
        tidyTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            let clean = Array(Set(env.settings.notifications.allDayTimes)).sorted()
            if clean != env.settings.notifications.allDayTimes { env.settings.notifications.allDayTimes = clean }
        }
    }

    /// The standard choices plus any value that is already saved (nothing the person set disappears).
    static func choices(_ selected: [Int]) -> [Int] {
        Array(Set(NotificationSettings.leadChoices).union(selected)).sorted()
    }

    static func snoozeChoices(_ selected: [Int]) -> [Int] {
        Array(Set([5, 10, 15, 30, 60, 120]).union(selected)).sorted()
    }

    /// "Will arrive: 5 minutes before and at the start."
    static func summary(_ leads: [Int], whenEmpty: String) -> String {
        let ordered = leads.sorted(by: >)
        guard !ordered.isEmpty else { return whenEmpty }
        return tr("Will arrive: %1$@.", Wording.list(ordered.map(Wording.leadBefore)))
    }

    static func allDaySummary(_ times: [LocalTime]) -> String {
        let sorted = Array(Set(times)).sorted()
        guard !sorted.isEmpty else { return tr("No reminders: such items are only visible in the day list.") }
        return tr("For example, “Pay for hosting” will remind you at %1$@ until it is marked done.", Wording.list(sorted.map(\.description)))
    }
}

// MARK: - Chips

/// A row of choice chips over minutes-before values; several can be on at once.
private struct LeadChips: View {
    let choices: [Int]
    @Binding var selection: [Int]
    var limit: Int?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(choices, id: \.self) { minutes in
                let isOn = selection.contains(minutes)
                Toggle(isOn: binding(minutes)) { Text(verbatim: Wording.leadChip(minutes)) }
                    .toggleStyle(ChipToggleStyle())
                    .disabled(!isOn && limit.map { selection.count >= $0 } == true)
            }
        }
        .padding(.vertical, 2)
    }

    private func binding(_ minutes: Int) -> Binding<Bool> {
        Binding(
            get: { selection.contains(minutes) },
            set: { on in
                var next = Set(selection)
                if on { next.insert(minutes) } else { next.remove(minutes) }
                selection = next.sorted(by: >) // latest first, as the settings keep them
            }
        )
    }
}

private struct ChipToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
                .background(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.16), in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Times of day

/// A time of day (hours and minutes) as a picker.
private struct TimeField: View {
    @Binding var time: LocalTime

    var body: some View {
        DatePicker(
            "", selection: Binding(get: { DateBridge.date(time) }, set: { time = DateBridge.localTime($0) }),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
    }
}

/// The times at which entries without a time are announced: a row per time, remove and add.
private struct TimeList: View {
    @Binding var times: [LocalTime]
    let limit: Int

    var body: some View {
        ForEach(times.indices, id: \.self) { index in
            LabeledContent(tr("Reminder %1$lld", numbers: index + 1)) {
                HStack(spacing: 10) {
                    TimeField(time: binding(index))
                    Button { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(tr("Remove this time"))
                }
            }
        }
        Button { add() } label: { Label(tr("Add a time"), systemImage: "plus.circle") }
            .disabled(times.count >= limit)
    }

    private func binding(_ index: Int) -> Binding<LocalTime> {
        Binding(
            get: { index < times.count ? times[index] : LocalTime(hour: 9, minute: 0)! },
            set: { if index < times.count { times[index] = $0 } }
        )
    }

    private func remove(_ index: Int) {
        guard index < times.count else { return }
        times.remove(at: index)
    }

    /// Adds the next sensible time that is not there yet: 12:00, 15:00, 18:00 …
    private func add() {
        let taken = Set(times)
        for hour in [9, 12, 15, 18, 21, 7, 10, 13, 16, 19] {
            let time = LocalTime(hour: hour, minute: 0)!
            if !taken.contains(time) {
                times.append(time)
                return
            }
        }
    }
}

// MARK: - Sounds

/// One sound choice: a menu of the app's chimes, macOS sounds and the person's own file, with a play button.
private struct SoundRow: View {
    let title: String
    let detail: String
    @Binding var sound: AlertSound
    @State private var problem: String?

    private static let systemNames = SoundCatalog.systemSoundNames

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    Picker("", selection: $sound) {
                        Text(tr("No sound")).tag(AlertSound.silent)
                        Section(tr("Kuzmemo sounds")) {
                            ForEach(SoundCatalog.chimes) { chime in Text(verbatim: chime.title).tag(AlertSound.chime(chime.id)) }
                        }
                        Section(tr("macOS system sounds")) {
                            ForEach(Self.systemNames, id: \.self) { name in Text(verbatim: name).tag(AlertSound.system(name)) }
                        }
                        if !isListed {
                            Section(tr("Chosen")) { Text(verbatim: SoundCatalog.title(for: sound)).tag(sound) }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    Button { SoundCatalog.preview(sound) } label: { Image(systemName: "play.fill") }
                        .disabled(sound.kind == .none)
                        .help(tr("Listen"))
                    Button(tr("Custom file…")) { chooseFile() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem { Text(verbatim: problem).font(.caption).foregroundStyle(.red) }
        }
    }

    /// Whether the current choice is one of the entries the menu lists anyway.
    private var isListed: Bool {
        switch sound.kind {
        case .none: true
        case .chime: SoundCatalog.chimes.contains { $0.id == sound.name }
        case .system: Self.systemNames.contains(sound.name)
        case .file: false
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose a sound file")
        panel.message = tr("A short sound up to 30 seconds: wav, aiff, mp3, m4a.")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            sound = try SoundCatalog.importFile(url)
            problem = nil
            SoundCatalog.preview(sound)
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Upcoming

private struct UpcomingRow: View {
    let alert: PlannedAlert
    let now: Date
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.silent || alert.sound.kind == .none ? "bell.slash" : "bell")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: alert.title).lineLimit(1)
                Text(verbatim: "\(alert.kindText) · \(SoundCatalog.title(for: alert.silent ? .silent : alert.sound))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(verbatim: alert.whenText(now: now, in: timeZone)).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The permission row (shared with the General tab)

extension NotificationScheduler {
    /// How a permission row shows what the system said.
    var permissionState: PermissionRow.State {
        guard isLive else { return .notNeeded }
        return switch access {
        case .allowed: .granted
        case .denied: .missing
        case .notDetermined, .unknown: .undecided
        }
    }

    /// The button beside it: ask (the first time) or open System Settings (once the person has decided).
    var permissionAction: (String, () -> Void) {
        if access == .notDetermined || access == .unknown {
            return (tr("Allow…"), { Task { _ = await self.requestAccess() } })
        }
        return (tr("Open Settings"), { PermissionsModel.openNotificationSettings() })
    }
}
