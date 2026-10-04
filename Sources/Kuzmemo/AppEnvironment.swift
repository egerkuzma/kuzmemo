import AppKit
import Foundation
import KuzmemoCore
import Observation

/// The composition root: owns the store, the Claude pipeline and everything the views observe.
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    enum Status: Equatable {
        case idle, recording, thinking, error
    }

    /// What the user sees after a command: confirmation lines, an answer, a question or an error.
    struct Toast: Equatable {
        enum Style: Equatable { case success, question, answer, warning, error }
        var style: Style
        var lines: [String]
        var options: [String] = []
        /// The journal entry this toast can undo.
        var undoOpID: String?
        /// A single item this toast is about, which the "Edit" button opens in the editor.
        var editItemID: String?
    }

    /// What the editor sheet is asked to show.
    enum EditorRequest: Identifiable {
        case new(ItemDraft)
        case edit(Item)

        var id: String {
            switch self {
            case .new: "new"
            case let .edit(item): item.id
            }
        }
    }

    /// A clarifying question waiting for an answer, typed, spoken or chosen.
    struct PendingQuestion: Equatable {
        var memoID: String
        var question: String
        var options: [String]
        /// 1 for the first question about a phrase; asking stops after `maxQuestions`.
        var round: Int
        var inputKind: MemoInputKind
    }

    static let maxQuestions = 2
    /// A question nobody answers within this long is closed and the phrase kept as a note.
    static let questionLifetime: TimeInterval = 120

    /// The language of the interface and of spoken output, and what the person chose (System / English / Русский).
    /// The choice lives in the user defaults so that it is known before the database is read.
    private(set) var language = AppLanguage.english
    var languagePreference = LanguagePreference.system {
        didSet { applyLanguagePreference() }
    }

    let paths: AppPaths
    let clock = AdjustableNow()
    let store: Store
    let data: DataMaintenance
    let processor: MemoProcessor
    let provider: ClaudeCLIProvider
    let calendar: CalendarModel
    let settings: AppSettings
    /// Downloads and copies of speech models, which go on whatever window is open.
    let models = ModelInstaller()

    private(set) var todayEntries: [AgendaEntry] = []
    private var baseStatus: Status = .idle
    private(set) var toast: Toast? {
        didSet { scheduleToastDismissal() }
    }
    /// Set to open the editor sheet in the main window (from a toast, a menu command or a double click).
    var editorRequest: EditorRequest?
    /// The tab the settings window shows.
    var settingsTab: SettingsView.Tab = .general
    /// Bumped by ⌘F; the window moves keyboard focus to its search field when this changes.
    private(set) var searchFocusRequest = 0
    /// The phrase in the Inbox whose "Discard" is waiting for the person's confirmation (its memo id).
    var discardRequest: String?

    func focusSearch() {
        showMainWindow()
        searchFocusRequest += 1
    }
    private(set) var queryResult: QueryResult?
    private(set) var pendingQuestion: PendingQuestion?
    private(set) var version: String

    @ObservationIgnored private(set) var voice: VoiceController!
    private(set) var notifications: NotificationScheduler!
    @ObservationIgnored private var controlServer: ControlServer?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var timeZoneObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var questionExpiry: Task<Void, Never>?
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    /// Registered by a SwiftUI view that is always alive (the menu-bar label): opens the main window's scene.
    @ObservationIgnored var openWindowAction: (() -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    /// The window that hosts the menu-bar popover, reported by the popover's own view.
    @ObservationIgnored weak var popoverWindow: NSWindow?

    /// What the menu-bar icon shows: recording and pending voice work take precedence over the last outcome.
    var status: Status {
        if voice?.isRecording == true { return .recording }
        if voice?.isBusy == true || baseStatus == .thinking { return .thinking }
        if data.hasProblem { return .error } // the menu-bar icon stays a warning until the database is sound again
        return baseStatus
    }

    init() {
        let stored = LanguagePreference(rawValue: UserDefaults.standard.string(forKey: Self.languageKey) ?? "") ?? .system
        let resolved = stored.resolved()
        languagePreference = stored
        language = resolved
        Localization.set(resolved)
        paths = AppPaths.resolve()
        version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let opened: (store: Store, outcome: DatabaseRecovery.Outcome)
        do {
            opened = try Store.openRecovering(at: paths.database, backups: paths.backups, clock: clock)
        } catch {
            Self.explainAndQuit(unopenable: paths.database, error: error)
        }
        store = opened.store
        data = DataMaintenance(store: opened.store, paths: paths, clock: clock, recovery: opened.outcome)
        provider = ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(workingDirectory: paths.claudeWorkingDirectory))
        processor = MemoProcessor(store: store, interpreter: Interpreter(store: store, provider: provider), clock: clock)
        calendar = CalendarModel(store: store, clock: clock)
        settings = AppSettings(store: store)
        start()
    }

    /// The database file could not be opened for a reason other than damage (damage is dealt with in `DatabaseRecovery`): a full
    /// disk, a folder without permission, a file locked by something else. Dying silently would leave a menu-bar app that
    /// simply never appears; this says what is wrong, changes nothing and quits.
    ///
    /// This runs while SwiftUI is still building the app, so it must not run the window system's own event loop: an `NSAlert`
    /// there lets SwiftUI draw a half-made scene and the process aborts. The system's notice dialog is shown by another
    /// process and only blocks this thread.
    private static func explainAndQuit(unopenable file: URL, error: any Error) -> Never {
        var response: CFOptionFlags = 0
        CFUserNotificationDisplayAlert(
            0, CFOptionFlags(kCFUserNotificationStopAlertLevel), nil, nil, nil,
            tr("Kuzmemo cannot open its database") as CFString,
            tr(
                "The file %1$@ could not be opened: %2$@. Nothing was changed. Check that the disk has room and that the folder is not locked, then start Kuzmemo again.",
                file.path, error.localizedDescription
            ) as CFString,
            tr("Quit") as CFString, nil, nil, &response
        )
        exit(1)
    }

    /// Save before deciding whether quitting is safe. Keep the control channel available if the quit is cancelled.
    func prepareToQuit() async -> Bool {
        let recordingsKept = await voice?.awaitAdmissions() ?? true
        await settings.flush()
        return recordingsKept
    }

    func finishTermination() { controlServer?.stop() }

    /// The system time zone changed (a flight, or the automatic setting): "today", the alerts and the calendar are worked out
    /// again. The clock follows the system zone, but nothing else would notice that a day had begun somewhere else.
    private func timeZoneChanged() {
        notifications?.requestSync(after: .seconds(1))
        Task {
            await calendar.rolloverIfNeeded()
            await reloadToday()
        }
    }

    private func start() {
        observer = Task { [weak self] in
            guard let store = self?.store else { return }
            for await _ in store.changes() {
                await self?.reloadToday()
                self?.notifications?.requestSync()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await processor.closeOrphanedQuestions()
            for outcome in await processor.recoverUnfinished() { await present(outcome, announce: false) }
        }
        calendar.startObserving()
        timeZoneObserver = NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeZoneChanged() }
        }
        // The Mac slept through midnight: the day timer fires late, and until then the window would show yesterday as today.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.calendar.rolloverIfNeeded()
                    await self.reloadToday()
                }
            }
        }
        voice = VoiceController(env: self)
        voice.start()
        notifications = NotificationScheduler(env: self)
        settings.observe { [weak self] group in if group == .notifications { self?.notifications.requestSync(after: .milliseconds(300)) } }
        notifications.start()
        data.onProblem = { [weak self] in self?.warnAboutDatabase() }
        data.start()
        if data.hasProblem { warnAboutDatabase() }
        if AppPaths.controlEnabled {
            let server = ControlServer(socketPath: paths.controlSocket.path) { request in
                await ControlRoutes.handle(request)
            }
            do { try server.start(); controlServer = server } catch { NSLog("Kuzmemo: control server failed: \(error)") }
        }
    }

    // MARK: - Data

    private func warnAboutDatabase() {
        toast = Toast(style: .error, lines: [tr("There is a problem with the database. Details: Settings → Data.")])
    }

    /// The Data page's "Erase all entries and history…": a copy is saved first, then the entries, saved phrases and the
    /// undo history go. Refused while a phrase is being recorded or processed.
    @discardableResult
    func eraseEntriesAndHistory() async -> EraseSummary? {
        guard voice?.isRecording != true, voice?.isBusy != true, baseStatus != .thinking else { return nil }
        guard let summary = await data.erase() else { return nil }
        queryResult = nil
        _ = takeQuestion()
        toast = nil
        await reloadToday()
        return summary
    }

    // MARK: - Language

    private static let languageKey = "interfaceLanguage"

    /// Puts a changed language choice to work: the texts of the whole app are built again in the new language.
    private func applyLanguagePreference() {
        UserDefaults.standard.set(languagePreference.rawValue, forKey: Self.languageKey)
        let resolved = languagePreference.resolved()
        guard resolved != language else { return }
        language = resolved
        Localization.set(resolved)
        AppWindow.settings.window?.title = tr("Settings")
        notifications?.requestSync(after: .milliseconds(200))
        voice?.languageChanged()
        Task { await reloadToday() }
    }

    // MARK: - Calendar

    func reloadToday() async {
        let today = clock.localNow().date
        todayEntries = (try? await store.agenda(on: today)) ?? []
    }

    // MARK: - Commands

    /// Text typed into the popover goes through the same pipeline as a spoken phrase.
    @discardableResult
    func submit(text: String, inputKind: MemoInputKind = .text) async -> ProcessOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, status != .thinking else { return nil }
        if pendingQuestion != nil { return await answer(trimmed, inputKind: inputKind) } // typed reply to a question
        baseStatus = .thinking
        toast = nil
        let outcome = await processor.submit(text: trimmed, inputKind: inputKind)
        await present(outcome, announce: true)
        return outcome
    }

    /// An answer (typed, chosen or recognised) to the pending question, read together with the phrase behind it.
    @discardableResult
    func answer(_ text: String, inputKind: MemoInputKind) async -> ProcessOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question = takeQuestion(), !trimmed.isEmpty else { return nil }
        baseStatus = .thinking
        toast = nil
        let outcome = await processor.submit(
            text: trimmed, inputKind: inputKind, parentMemoID: question.memoID, followupQuestion: question.question
        )
        await present(outcome, announce: true, round: question.round + 1)
        return outcome
    }

    /// The person did not answer (or cancelled). With `keep` the original words become a note without a date.
    /// `question` is the one being closed when it has already been taken out of play.
    func closeQuestion(_ taken: PendingQuestion? = nil, keep: Bool) async {
        guard let question = taken ?? takeQuestion() else { return }
        if keep, let outcome = await processor.keepAsNote(memoID: question.memoID), case let .applied(result) = outcome.kind {
            toast = Toast(
                style: .warning, lines: [tr("No answer came — saved as an undated note.")], undoOpID: result.op?.id
            )
        } else {
            await processor.discard(memoID: question.memoID, reason: "the question was cancelled")
            toast = nil
        }
        baseStatus = .idle
    }

    /// Takes the pending question out of play (it is being answered or closed).
    func takeQuestion() -> PendingQuestion? {
        questionExpiry?.cancel()
        questionExpiry = nil
        defer { pendingQuestion = nil }
        return pendingQuestion
    }

    private func expectAnswer(to question: PendingQuestion) {
        pendingQuestion = question
        questionExpiry?.cancel()
        questionExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.questionLifetime))
            guard !Task.isCancelled, self?.pendingQuestion?.memoID == question.memoID else { return }
            await self?.closeQuestion(keep: true)
        }
    }

    func undo(opID: String) async {
        do {
            try await store.undo(opID: opID)
            toast = Toast(style: .success, lines: [tr("Undone")])
        } catch {
            toast = Toast(style: .error, lines: [tr("Could not undo: the change was already affected by newer edits.")])
        }
    }

    func dismissToast() { toast = nil }

    /// Confirmations fade by themselves; questions, answers and errors stay until dealt with.
    private func scheduleToastDismissal() {
        toastDismissal?.cancel()
        toastDismissal = nil
        guard let shown = toast, shown.style == .success || shown.style == .warning, shown.options.isEmpty else { return }
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.toast == shown else { return }
            self?.toast = nil
        }
    }

    // MARK: - Actions from the window

    /// Runs an action from the calendar window and reports it with an undo toast (or the reason it failed).
    func act(_ work: @escaping @MainActor () async throws -> ActionOutcome) {
        Task { @MainActor in
            if let error = await attempt(work) { toast = Toast(style: .error, lines: [Self.describe(error)]) }
        }
    }

    /// The same, for a caller that has to know how it went (the editor keeps what the person typed when saving fails): a
    /// success is reported with an undo toast, a failure is handed back and nothing is shown.
    func attempt(_ work: @MainActor () async throws -> ActionOutcome) async -> (any Error)? {
        do {
            let outcome = try await work()
            if !outcome.lines.isEmpty {
                toast = Toast(style: .success, lines: outcome.lines, undoOpID: outcome.op?.id)
            }
            return nil
        } catch {
            return error
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let problem as ItemDraft.Problem:
            switch problem {
            case .emptyTitle: tr("Enter a title for the entry.")
            case .repeatWithoutDate: tr("A repeating entry needs a start date.")
            }
        case StoreError.changedMeanwhile:
            tr("This entry was changed while you were editing it. Save again to replace that change with your version, or cancel to keep it.")
        case is StoreError:
            tr("The entry has changed: refresh the window and try again.")
        default:
            tr("Could not do that: %1$@", "\(error)")
        }
    }

    /// Opens an item in the editor, bringing the main window to the front.
    func openEditor(itemID: String) {
        Task { @MainActor in
            guard let item = try? await store.item(id: itemID) else { return }
            editorRequest = .edit(item)
            showMainWindow()
        }
    }

    func newItem(on date: LocalDate?) {
        editorRequest = .new(ItemDraft(kind: .task, date: date))
        showMainWindow()
    }

    /// Closes the menu-bar popover if it is open. SwiftUI leaves the window of a `.window`-style menu bar extra on the
    /// screen until the person clicks somewhere else, which is wrong after choosing "Open" or "Settings…".
    func closePopover() {
        guard let window = popoverWindow, window.isVisible else { return }
        MenuBarPopover.hide(window)
    }

    /// The window is a regular app window while it is open (Dock icon, menu), and the app returns to the menu bar
    /// when it closes (see `AppDelegate`).
    func showMainWindow() {
        closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = AppWindow.main.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?()
        }
    }

    /// Opens the settings window in front of everything else.
    func showSettings(tab: SettingsView.Tab? = nil) {
        closePopover()
        if let tab { settingsTab = tab }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = AppWindow.settings.window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openSettingsAction?()
        }
    }

    // MARK: - Inbox cards

    /// "Retry": recognise the kept recording again, or ask Claude again.
    func retry(memo: Memo) {
        Task { @MainActor in
            baseStatus = .thinking
            if memo.failStage == "stt" {
                await voice.retryRecognition(memoID: memo.id)
            } else if let outcome = await processor.retry(memoID: memo.id) {
                await present(outcome, announce: true)
            }
            if baseStatus == .thinking { baseStatus = .idle }
        }
    }

    /// "Edit text…" followed by "Retry with this text".
    func editAndRetry(memo: Memo, text: String) {
        Task { @MainActor in
            baseStatus = .thinking
            if let outcome = await processor.editAndRetry(memoID: memo.id, text: text) { await present(outcome, announce: true) }
            if baseStatus == .thinking { baseStatus = .idle }
        }
    }

    func keepAsNote(memo: Memo) {
        Task { @MainActor in
            if let outcome = await processor.keepAsNote(memoID: memo.id), case let .applied(result) = outcome.kind {
                toast = Toast(style: .success, lines: result.changes.map { $0.summary(today: clock.localNow().date) }, undoOpID: result.op?.id)
            }
        }
    }

    func discard(memo: Memo) {
        Task { @MainActor in await processor.discard(memoID: memo.id, reason: "discarded from the Inbox") }
    }

    // MARK: - Presenting outcomes

    func present(_ outcome: ProcessOutcome, announce: Bool, round: Int = 1) async {
        let now = clock.localNow()
        switch outcome.kind {
        case let .applied(result):
            queryResult = nil
            baseStatus = .idle
            if announce {
                let single = result.changes.count == 1 ? result.changes[0] : nil
                let editable = single.map { $0.kind == .created || $0.kind == .updated || $0.kind == .moved } ?? false
                toast = Toast(
                    style: .success, lines: result.changes.map { $0.summary(today: now.date) }, undoOpID: result.op?.id,
                    editItemID: editable ? single?.item.id : nil
                )
            }
        case let .answered(plan):
            baseStatus = .idle
            let result = try? await store.run(plan, now: now)
            queryResult = result
            toast = Toast(style: .answer, lines: [Self.digest(result, today: now.date)])
        case let .clarify(clarification):
            baseStatus = .idle
            if round > Self.maxQuestions || !announce {
                // Two questions were not enough (or nobody is there to answer a recovered one): keep what was
                // said rather than ask again.
                if let saved = await processor.keepAsNote(memoID: outcome.memo.id), case let .applied(result) = saved.kind {
                    toast = Toast(
                        style: .warning, lines: [tr("Could not clarify — saved as an undated note.")], undoOpID: result.op?.id
                    )
                } else {
                    toast = Toast(style: .warning, lines: [tr("Could not clarify. Nothing was saved.")])
                }
            } else {
                toast = Toast(style: .question, lines: [clarification.question], options: clarification.options)
                expectAnswer(to: PendingQuestion(
                    memoID: outcome.memo.id, question: clarification.question, options: clarification.options,
                    round: round, inputKind: outcome.memo.inputKind
                ))
            }
        case .unknown:
            baseStatus = .idle
            toast = Toast(style: .warning, lines: [tr("That does not sound like a calendar command. Nothing was saved.")])
        case .erased:
            baseStatus = .idle // everything was erased while this phrase was being worked on: nothing of it is left to show
        case let .failed(error, retryAt):
            baseStatus = .error
            toast = Toast(style: .error, lines: [Self.message(for: error, retryAt: retryAt, today: now.date)])
        }
    }

    /// A plain-text answer for a query (the spoken version comes with the voice path).
    static func digest(_ result: QueryResult?, today: LocalDate) -> String {
        guard let result else { return tr("Could not get an answer.") }
        if result.entries.isEmpty {
            return result.passedToday > 0 ? tr("Nothing left (%1$@).", "\(result.title)") : tr("Nothing (%1$@).", "\(result.title)")
        }
        let count = result.entries.count
        var lines = ["\(trCount("%lld entries", count)) — \(result.title):"]
        for entry in result.entries.prefix(8) {
            let when = entry.time.map { "\($0)" } ?? tr("all day")
            lines.append("\(when) — \(entry.item.title)")
        }
        return lines.joined(separator: "\n")
    }

    static func message(for error: LLMError, retryAt: Date?, today: LocalDate) -> String {
        switch error {
        case .notLoggedIn:
            return tr("Claude is not signed in. Run “claude auth login” in a terminal. Your phrase is saved.")
        case .executableNotFound:
            return tr("Could not find the claude program. Install Claude Code and try again. Your phrase is saved.")
        case .rateLimited:
            return tr("Claude’s usage limit is reached. Your phrase is saved; I will try again later.")
        case .timedOut:
            return tr("Claude did not answer in time. Your phrase is saved; I will try again later.")
        case .unsupportedCLI:
            return tr("The installed version of claude does not support the options the app needs. Your phrase is saved.")
        default:
            return retryAt == nil
                ? tr("Could not process the phrase. It is saved.")
                : tr("Could not process the phrase. It is saved; I will try again later.")
        }
    }
}
