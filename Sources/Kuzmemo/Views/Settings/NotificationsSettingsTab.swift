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
            Section("Системные уведомления") {
                Toggle("Напоминать уведомлениями", isOn: $settings.notifications.enabled)
                PermissionRow(title: "Разрешение macOS", state: scheduler.permissionState, action: scheduler.permissionAction)
                permissionHint
            }
            Group {
                Section("Встречи и звонки") {
                    Hint("Записи типа «событие»: «созвон с Figma завтра в 11», «планёрка в понедельник в 10». Тип Kuzmemo определяет по вашей фразе; он виден в календаре и меняется в редакторе записи. О встрече можно предупредить заранее и ещё раз в момент начала.")
                    LeadChips(choices: Self.choices(settings.notifications.eventLeads), selection: $settings.notifications.eventLeads)
                    Hint(Self.summary(settings.notifications.eventLeads, what: "событии"))
                }
                Section("Напоминания и задачи") {
                    Hint("С точным временем: «напомни позвонить в банк в 16:00», «ответить саппорту в 17:30». Обычно хватает сигнала в нужный момент.")
                    LeadChips(choices: Self.choices(settings.notifications.reminderLeads), selection: $settings.notifications.reminderLeads)
                    Hint(Self.summary(settings.notifications.reminderLeads, what: "напоминании"))
                    Hint("У отдельной записи в редакторе можно добавить ещё один ранний сигнал.")
                }
                Section("Дела на весь день") {
                    Hint("Напоминания и задачи с датой, но без времени: «напомни послезавтра сказать Дмитрию». Пока дело не выполнено, Kuzmemo напомнит о нём в эти часы:")
                    TimeList(times: $settings.notifications.allDayTimes, limit: 6)
                    Hint(Self.allDaySummary(settings.notifications.allDayTimes))
                    Hint("Заметки и события без времени уведомлений не дают.")
                }
                Section("Звуки") {
                    SoundRow(title: "Заранее", detail: "как «встреча через 5 минут» в Zoom", sound: $settings.notifications.headsUpSound)
                    SoundRow(title: "В назначенное время", detail: "сама встреча или напоминание", sound: $settings.notifications.atTimeSound)
                    SoundRow(title: "Дела на весь день", detail: "напоминание «на сегодня»", sound: $settings.notifications.allDaySound)
                    HStack {
                        testMenu(settings.notifications)
                        if let testMessage { Hint(testMessage) }
                    }
                    if AppPaths.isAutomation { Hint("В этой сборке звук и уведомления выключены (для автоматических проверок).") }
                }
                Section("Ещё") {
                    Toggle("Читать название вслух", isOn: $settings.notifications.speakTitle)
                    Hint("Голосом из вкладки «Озвучка», пока Kuzmemo запущен.")
                    Toggle("Тихие часы: без звука", isOn: $settings.notifications.quietHours.enabled.animation())
                    if settings.notifications.quietHours.enabled {
                        LabeledContent("С") { TimeField(time: $settings.notifications.quietHours.from) }
                        LabeledContent("До") { TimeField(time: $settings.notifications.quietHours.to) }
                        Hint("В это время уведомления приходят, но без звука и без чтения вслух.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Кнопки «Отложить» на уведомлении")
                        LeadChips(choices: Self.snoozeChoices(settings.notifications.snoozeMinutes), selection: $settings.notifications.snoozeMinutes, limit: 3)
                        Hint("Не больше трёх. Рядом всегда есть кнопка «Готово».")
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
            Hint("Уведомления для Kuzmemo выключены. Включите их в Системных настройках → Уведомления → Kuzmemo («Разрешить уведомления»).")
        } else {
            Hint("Уведомления показывает сама macOS, поэтому они приходят в срок, даже если Kuzmemo закрыт. Вид (баннер или заметка) выбирается в Системных настройках → Уведомления → Kuzmemo.")
        }
        if let error = scheduler.lastError { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
    }

    // MARK: Test

    private func testMenu(_ settings: NotificationSettings) -> some View {
        Menu {
            Button("Как перед событием · \(SoundCatalog.title(for: settings.headsUpSound))") { test(settings.headsUpSound) }
            Button("Как в назначенное время · \(SoundCatalog.title(for: settings.atTimeSound))") { test(settings.atTimeSound) }
            Button("Как для дела на весь день · \(SoundCatalog.title(for: settings.allDaySound))") { test(settings.allDaySound) }
        } label: {
            Label("Проверить уведомление", systemImage: "bell.badge")
        }
        .fixedSize()
    }

    private func test(_ sound: AlertSound) {
        Task {
            testMessage = await scheduler.sendTest(sound: sound) ?? "Уведомление появится через секунду."
            try? await Task.sleep(for: .seconds(6))
            testMessage = nil
        }
    }

    // MARK: Upcoming

    @ViewBuilder private func upcomingSection(_ settings: NotificationSettings) -> some View {
        let alerts = scheduler.planned
        let shown = 8
        Section("Ближайшие уведомления") {
            if !settings.enabled {
                Hint("Уведомления выключены.")
            } else if alerts.isEmpty {
                Hint("Пока ничего не запланировано: нет записей на ближайшие \(settings.horizonDays) дней.")
            }
            ForEach(alerts.prefix(shown)) { alert in
                UpcomingRow(alert: alert, now: env.clock.now(), timeZone: env.clock.timeZone)
            }
            if alerts.count > shown { Hint("…и ещё \(alerts.count - shown)") }
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

    /// "Придёт: за 5 минут и в момент начала."
    static func summary(_ leads: [Int], what: String) -> String {
        let ordered = leads.sorted(by: >)
        guard !ordered.isEmpty else { return "Уведомлений о \(what) не будет." }
        return "Придёт: \(joined(ordered.map(RussianFormat.leadBefore)))."
    }

    static func allDaySummary(_ times: [LocalTime]) -> String {
        let sorted = Array(Set(times)).sorted()
        guard !sorted.isEmpty else { return "Без напоминаний: такие дела видны только в списке дня." }
        return "Например, «Сказать Дмитрию» напомнит о себе в \(joined(sorted.map(\.description))) — пока не отмечено выполненным."
    }

    /// "a", "a и b", "a, b и c".
    static func joined(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " и " + last
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
                Toggle(isOn: binding(minutes)) { Text(verbatim: RussianFormat.leadChip(minutes)) }
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
            LabeledContent("Напоминание \(index + 1)") {
                HStack(spacing: 10) {
                    TimeField(time: binding(index))
                    Button { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Убрать это время")
                }
            }
        }
        Button { add() } label: { Label("Добавить время", systemImage: "plus.circle") }
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
                        Text("Без звука").tag(AlertSound.silent)
                        Section("Мелодии Kuzmemo") {
                            ForEach(SoundCatalog.chimes) { chime in Text(verbatim: chime.title).tag(AlertSound.chime(chime.id)) }
                        }
                        Section("Системные звуки macOS") {
                            ForEach(Self.systemNames, id: \.self) { name in Text(verbatim: name).tag(AlertSound.system(name)) }
                        }
                        if !isListed {
                            Section("Выбрано") { Text(verbatim: SoundCatalog.title(for: sound)).tag(sound) }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    Button { SoundCatalog.preview(sound) } label: { Image(systemName: "play.fill") }
                        .disabled(sound.kind == .none)
                        .help("Прослушать")
                    Button("Свой файл…") { chooseFile() }
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
        panel.title = "Выберите звуковой файл"
        panel.message = "Подойдёт короткая мелодия до 30 секунд: wav, aiff, mp3, m4a."
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
            return ("Разрешить…", { Task { _ = await self.requestAccess() } })
        }
        return ("Открыть настройки", { PermissionsModel.openNotificationSettings() })
    }
}
