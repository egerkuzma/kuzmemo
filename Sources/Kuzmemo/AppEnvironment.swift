import Foundation
import KuzmemoCore
import Observation

/// The composition root: owns the store, the Claude pipeline and everything the views observe.
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    enum Status: Equatable {
        case idle, thinking, error
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

    let paths: AppPaths
    let clock = AdjustableNow()
    let store: Store
    let processor: MemoProcessor
    let provider: ClaudeCLIProvider

    private(set) var todayEntries: [AgendaEntry] = []
    private(set) var status: Status = .idle
    private(set) var toast: Toast?
    private(set) var queryResult: QueryResult?
    private(set) var version: String

    private var controlServer: ControlServer?
    private var observer: Task<Void, Never>?

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
            for outcome in await processor.recoverUnfinished() { await present(outcome, announce: false) }
        }
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
        status = .thinking
        toast = nil
        let outcome = await processor.submit(text: trimmed, inputKind: inputKind)
        await present(outcome, announce: true)
        return outcome
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

    func present(_ outcome: ProcessOutcome, announce: Bool) async {
        let now = clock.localNow()
        switch outcome.kind {
        case let .applied(result):
            queryResult = nil
            status = .idle
            if announce {
                toast = Toast(style: .success, lines: result.changes.map { $0.summary(today: now.date) }, undoOpID: result.op?.id)
            }
        case let .answered(plan):
            status = .idle
            let result = try? await store.run(plan, now: now)
            queryResult = result
            toast = Toast(style: .answer, lines: [Self.digest(result, today: now.date)])
        case let .clarify(clarification):
            status = .idle
            toast = Toast(style: .question, lines: [clarification.question], options: clarification.options)
        case .unknown:
            status = .idle
            toast = Toast(style: .warning, lines: ["Не похоже на команду для календаря. Ничего не сохранено."])
        case let .failed(error, retryAt):
            status = .error
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
