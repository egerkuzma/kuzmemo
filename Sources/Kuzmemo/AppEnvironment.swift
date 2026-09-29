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
        /// A single item this toast is about, which the "Изменить" button opens in the editor.
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

    let paths: AppPaths
    let clock = AdjustableNow()
    let store: Store
    let processor: MemoProcessor
    let provider: ClaudeCLIProvider
    let calendar: CalendarModel

    private(set) var todayEntries: [AgendaEntry] = []
    private var baseStatus: Status = .idle
    private(set) var toast: Toast? {
        didSet { scheduleToastDismissal() }
    }
    /// Set to open the editor sheet in the main window (from a toast, a menu command or a double click).
    var editorRequest: EditorRequest?
    /// Bumped by ⌘F; the window moves keyboard focus to its search field when this changes.
    private(set) var searchFocusRequest = 0

    func focusSearch() {
        showMainWindow()
        searchFocusRequest += 1
    }
    private(set) var queryResult: QueryResult?
    private(set) var pendingQuestion: PendingQuestion?
    private(set) var version: String

    @ObservationIgnored private(set) var voice: VoiceController!
    @ObservationIgnored private var controlServer: ControlServer?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var questionExpiry: Task<Void, Never>?
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    /// Registered by a SwiftUI view that is always alive (the menu-bar label): opens the main window's scene.
    @ObservationIgnored var openWindowAction: (() -> Void)?

    /// What the menu-bar icon shows: recording and pending voice work take precedence over the last outcome.
    var status: Status {
        if voice?.isRecording == true { return .recording }
        if voice?.isBusy == true || baseStatus == .thinking { return .thinking }
        return baseStatus
    }

    init() {
        paths = AppPaths.resolve()
        version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        do {
            store = try Store(databaseAt: paths.database, clock: clock)
        } catch {
            fatalError("Cannot open the database at \(paths.database.path): \(error)")
        }
        provider = ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(workingDirectory: paths.claudeWorkingDirectory))
        processor = MemoProcessor(store: store, interpreter: Interpreter(store: store, provider: provider), clock: clock)
        calendar = CalendarModel(store: store, clock: clock)
        start()
    }

    private func start() {
        observer = Task { [weak self] in
            guard let store = self?.store else { return }
            for await _ in store.changes() { await self?.reloadToday() }
        }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await store.seedGlossaryIfNeeded()
            await processor.closeOrphanedQuestions()
            for outcome in await processor.recoverUnfinished() { await present(outcome, announce: false) }
        }
        calendar.startObserving()
        voice = VoiceController(env: self)
        voice.start()
        if AppPaths.controlEnabled {
            let server = ControlServer(socketPath: paths.controlSocket.path) { request in
                await ControlRoutes.handle(request)
            }
            do { try server.start(); controlServer = server } catch { NSLog("Kuzmemo: control server failed: \(error)") }
        }
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
                style: .warning, lines: ["Не дождался ответа — сохранил как заметку без даты."], undoOpID: result.op?.id
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
            toast = Toast(style: .success, lines: ["Отменено"])
        } catch {
            toast = Toast(style: .error, lines: ["Не удалось отменить: изменение уже затронуто новыми правками."])
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
            do {
                let outcome = try await work()
                if !outcome.lines.isEmpty {
                    toast = Toast(style: .success, lines: outcome.lines, undoOpID: outcome.op?.id)
                }
            } catch {
                toast = Toast(style: .error, lines: [Self.describe(error)])
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let problem as ItemDraft.Problem:
            switch problem {
            case .emptyTitle: "Введите название записи."
            case .repeatWithoutDate: "Для повторяющейся записи нужна дата начала."
            }
        case is StoreError:
            "Запись уже изменилась: обновите окно и повторите."
        default:
            "Не удалось выполнить действие: \(error)"
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

    /// The window is a regular app window while it is open (Dock icon, menu), and the app returns to the menu bar
    /// when it closes (see `AppDelegate`).
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Kuzmemo" && $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?()
        }
    }

    // MARK: - Inbox cards

    /// "Повторить": recognise the kept recording again, or ask Claude again.
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

    /// "Править текст и повторить".
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
                        style: .warning, lines: ["Не удалось уточнить — сохранил как заметку без даты."], undoOpID: result.op?.id
                    )
                } else {
                    toast = Toast(style: .warning, lines: ["Не удалось уточнить. Ничего не сохранено."])
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
            toast = Toast(style: .warning, lines: ["Не похоже на команду для календаря. Ничего не сохранено."])
        case let .failed(error, retryAt):
            baseStatus = .error
            toast = Toast(style: .error, lines: [Self.message(for: error, retryAt: retryAt, today: now.date)])
        }
    }

    /// A plain-text answer for a query (the spoken version comes with the voice path).
    static func digest(_ result: QueryResult?, today: LocalDate) -> String {
        guard let result else { return "Не удалось получить ответ." }
        if result.entries.isEmpty { return "Пусто (\(result.title))." }
        let count = result.entries.count
        var lines = ["\(count) \(RussianFormat.plural(count, ("запись", "записи", "записей"))) — \(result.title):"]
        for entry in result.entries.prefix(8) {
            let when = entry.time.map { "\($0)" } ?? "весь день"
            lines.append("\(when) — \(entry.item.title)")
        }
        return lines.joined(separator: "\n")
    }

    static func message(for error: LLMError, retryAt: Date?, today: LocalDate) -> String {
        switch error {
        case .notLoggedIn:
            return "Claude не выполнил вход. Запустите «claude auth login» в терминале. Запись сохранена."
        case .executableNotFound:
            return "Не нашёл программу claude. Укажите путь к ней в настройках. Запись сохранена."
        case .rateLimited:
            return "Лимит Claude исчерпан. Запись сохранена, повторю позже."
        case .timedOut:
            return "Claude не ответил вовремя. Запись сохранена, повторю позже."
        case .unsupportedCLI:
            return "Установленная версия claude не поддерживает нужные параметры. Запись сохранена."
        default:
            return retryAt == nil
                ? "Не удалось обработать запись. Она сохранена."
                : "Не удалось обработать запись. Она сохранена, повторю позже."
        }
    }
}
