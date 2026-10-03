import Foundation
import GRDB

/// Why a copy of the database was made. It decides how many copies of that kind are kept.
public enum BackupReason: String, Codable, Sendable, CaseIterable {
    /// The automatic copy: one per day.
    case daily
    /// The person asked for it.
    case manual
    /// Made just before everything was erased, so that the erase can be taken back.
    case beforeErase

    /// What the file name carries after the time stamp.
    fileprivate var suffix: String {
        switch self {
        case .daily: ""
        case .manual: "manual"
        case .beforeErase: "before-erase"
        }
    }

    fileprivate var keep: Int { self == .daily ? BackupService.dailyKeep : BackupService.otherKeep }
}

/// One copy of the database in the backups folder.
public struct BackupFile: Equatable, Codable, Sendable, Identifiable {
    public var url: URL
    public var reason: BackupReason
    /// When it was made, by the wall clock of the Mac at that time.
    public var day: LocalDate
    public var time: LocalTime
    public var bytes: Int64
    /// Orders copies made within the same minute.
    fileprivate var sortKey: Int64

    public var id: String { url.lastPathComponent }
}

public enum BackupError: Error, Equatable {
    /// The copy was written but could not be read back, so it was thrown away.
    case unreadableCopy(String)
}

/// Keeps copies of the database: one a day (the last 14 are kept), plus the ones the person asks for and the one made
/// before an erase (the last 5 of each). A copy is a single ordinary SQLite file made with `VACUUM INTO`, read back
/// before it is accepted. Anything in the folder that does not look like one of our copies is left alone.
public actor BackupService {
    public static let dailyKeep = 14
    public static let otherKeep = 5

    private let store: Store
    public nonisolated let directory: URL
    /// Copies are made one at a time. The actor alone does not see to that: a copy waits for the database and the file system
    /// part-way, and another would start right there, sweep away the first one's unfinished file and pick the same name.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(store: Store, directory: URL) {
        self.store = store
        self.directory = directory
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) } // the turn is handed over by `release`; `busy` stays set
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    // MARK: Reading

    /// The copies in the folder, newest first.
    public nonisolated func list() -> [BackupFile] { Self.list(in: directory) }

    /// The copies in `directory`, newest first (also used at launch, before any service exists).
    public static func list(in directory: URL) -> [BackupFile] {
        (try? listing(in: directory)) ?? []
    }

    /// The copies, newest first; a folder that cannot be read is an error (a missing one holds no copies). Recovery needs the
    /// difference: "no copies" starts an empty database, "cannot read the copies" must not.
    public static func listing(in directory: URL) throws -> [BackupFile] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return names.compactMap { name -> BackupFile? in
            guard let parsed = Self.parse(name) else { return nil }
            let url = directory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return BackupFile(url: url, reason: parsed.reason, day: parsed.day, time: parsed.time, bytes: size, sortKey: parsed.sortKey)
        }
        .sorted { $0.sortKey > $1.sortKey }
    }

    /// No automatic copy has been made yet on today's date.
    public func isDailyDue() -> Bool {
        let today = store.clock.localNow().date
        return !list().contains { $0.reason == .daily && $0.day == today }
    }

    // MARK: Making

    /// Makes a copy now, checks that it can be read, and removes copies beyond what is kept.
    @discardableResult
    public func run(_ reason: BackupReason) async throws -> BackupFile {
        await acquire()
        defer { release() }
        return try await makeCopy(reason)
    }

    private func makeCopy(_ reason: BackupReason) async throws -> BackupFile {
        let fileManager = FileManager.default
        try PrivateFiles.directory(directory)
        // Leftovers of a copy that was interrupted (a crash, a power cut). Copies are made one at a time, so none is in progress.
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        let stamp = Self.stamp(store.clock.now(), in: store.clock.timeZone)
        var counter = 1
        var name = Self.fileName(stamp: stamp, counter: counter, reason: reason)
        while fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            counter += 1
            name = Self.fileName(stamp: stamp, counter: counter, reason: reason)
        }
        let final = directory.appendingPathComponent(name)
        let partial = directory.appendingPathComponent(name + ".partial")
        do {
            try await store.writer.vacuum(into: partial.path)
            try PrivateFiles.file(partial)
            try Self.verify(partial)
            try fileManager.moveItem(at: partial, to: final)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        prune()
        guard let made = list().first(where: { $0.url == final }) else { throw BackupError.unreadableCopy(name) }
        return made
    }

    /// The automatic copy: made if today's has not been made yet (asked again once it is this one's turn: the copy that was
    /// ahead may have been today's).
    @discardableResult
    public func runDailyIfDue() async throws -> BackupFile? {
        await acquire()
        defer { release() }
        guard isDailyDue() else { return nil }
        return try await makeCopy(.daily)
    }

    private func prune() {
        let files = list()
        for reason in BackupReason.allCases {
            for stale in files.filter({ $0.reason == reason }).dropFirst(reason.keep) {
                try? FileManager.default.removeItem(at: stale.url)
            }
        }
    }

    /// Opens the finished copy read-only and asks SQLite whether it is sound and holds the calendar tables.
    private static func verify(_ url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        let (verdict, entries) = try queue.read { db in
            (try String.fetchAll(db, sql: "PRAGMA integrity_check(5)"), try Int.fetchOne(db, sql: "SELECT count(*) FROM items"))
        }
        guard verdict == ["ok"], entries != nil else {
            throw BackupError.unreadableCopy(verdict.joined(separator: "; "))
        }
    }

    // MARK: Names

    /// `2026-09-29-183012` (year, month, day, then hour, minute, second) by the wall clock of `zone`.
    static func stamp(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04ld-%02ld-%02ld-%02ld%02ld%02ld", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `kuzmemo-2026-09-29-183012.sqlite`, or with `-2` when a second copy is made within the same second, and with
    /// `-manual` or `-before-erase` for the other kinds.
    static func fileName(stamp: String, counter: Int, reason: BackupReason) -> String {
        var name = "kuzmemo-\(stamp)"
        if counter > 1 { name += "-\(counter)" }
        if !reason.suffix.isEmpty { name += "-\(reason.suffix)" }
        return name + ".sqlite"
    }

    static func parse(_ name: String) -> (reason: BackupReason, day: LocalDate, time: LocalTime, sortKey: Int64)? {
        guard name.hasPrefix("kuzmemo-"), name.hasSuffix(".sqlite") else { return nil }
        let body = name.dropFirst("kuzmemo-".count).dropLast(".sqlite".count)
        var parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2, parts[3].count == 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]), let clock = Int(parts[3]),
              let day = LocalDate(year: year, month: month, day: dayOfMonth),
              let time = LocalTime(hour: clock / 10_000, minute: clock / 100 % 100)
        else { return nil }
        parts.removeFirst(4)
        var counter = 1
        if let first = parts.first, let number = Int(first) {
            counter = number
            parts.removeFirst()
        }
        let tail = parts.joined(separator: "-")
        guard let reason = BackupReason.allCases.first(where: { $0.suffix == tail }) else { return nil }
        let secondOfDay = (clock / 10_000) * 3600 + (clock / 100 % 100) * 60 + clock % 100
        let key = Int64(day.epochDay) * 86_400_000 + Int64(secondOfDay) * 1000 + Int64(counter)
        return (reason, day, time, key)
    }
}
