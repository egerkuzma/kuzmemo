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

    private(set) var todayEntries: [AgendaEntry] = []
    private var baseStatus: Status = .idle
    private(set) var toast: Toast?
    private(set) var queryResult: QueryResult?
    private(set) var pendingQuestion: PendingQuestion?
    private(set) var version: String

    @ObservationIgnored private(set) var voice: VoiceController!
    @ObservationIgnored private var controlServer: ControlServer?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var questionExpiry: Task<Void, Never>?

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

    // MARK: - Presenting outcomes

    func present(_ outcome: ProcessOutcome, announce: Bool, round: Int = 1) async {
        let now = clock.localNow()
        switch outcome.kind {
        case let .applied(result):
            queryResult = nil
            baseStatus = .idle
            if announce {
                toast = Toast(style: .success, lines: result.changes.map { $0.summary(today: now.date) }, undoOpID: result.op?.id)
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
