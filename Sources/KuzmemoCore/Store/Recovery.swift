import Darwin
import Foundation
import GRDB

/// Opens the database at launch and copes with a file that is too damaged to open, instead of failing on every launch.
///
/// A damaged file is never deleted: it is moved next to the database as `kuzmemo-damaged-<time>.sqlite` (with its log
/// files), so it can still be examined or salvaged by hand. Then the newest copy that opens and passes SQLite's check is
/// put in its place; with none, the app starts with an empty database. Only a broken file triggers this; a locked file, a
/// full disk or a missing permission is an ordinary error and is passed on.
///
/// The database is never left missing while this runs: a copy is made whole and checked beside it (`<name>.restoring`),
/// and the two files then change places in a single step. A launch that is cut short in the middle finds either the damaged
/// file still in place (and starts over) or the restored one in place with the damaged one at the staging path (and sets
/// that aside). It used to move the damaged file away first, and a launch killed before the copy arrived made a new, empty
/// database on the next start, without a word about the copies that were there.
public enum DatabaseRecovery {
    public enum Outcome: Equatable, Sendable {
        /// Nothing was wrong.
        case opened
        /// The file was damaged; `from` was put in its place (entries made after that copy are gone).
        case restored(from: BackupFile, damagedFile: URL)
        /// The file was damaged and there was no usable copy.
        case startedEmpty(damagedFile: URL)
    }

    public static func open(
        at url: URL, backups directory: URL, now: Date = Date(), zone: TimeZone = .current
    ) throws -> (pool: DatabasePool, outcome: Outcome) {
        if let resumed = try resumeReplacement(of: url) { return resumed }
        try setAsideLeftover(of: url, now: now, zone: zone)
        do {
            return (try KuzmemoDatabase.open(at: url), .opened)
        } catch let error as DatabaseError where isDamage(error) {
            return try restore(url, backups: directory, now: now, zone: zone)
        }
    }

    /// SQLite's verdict that the file itself is broken; anything else is trouble of another kind.
    static func isDamage(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Where a copy is made whole and checked before it takes the database's place.
    static func stagingURL(for url: URL) -> URL { URL(fileURLWithPath: url.path + ".restoring") }

    static func journalURL(for url: URL) -> URL { URL(fileURLWithPath: url.path + ".recovery.json") }

    /// Written before the swap. The replacement's inode identifies which side of the atomic swap survived a crash,
    /// including the gap between swapping the files and archiving the damaged one.
    struct Replacement: Codable {
        var fileNumber: UInt64
        var backup: BackupFile?
        var damagedFile: URL
    }

    private static func fileNumber(of url: URL) throws -> UInt64 {
        guard let number = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return number.uint64Value
    }

    private static func resumeReplacement(of url: URL) throws -> (DatabasePool, Outcome)? {
        let data: Data
        do { data = try Data(contentsOf: journalURL(for: url)) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let replacement = try JSONDecoder().decode(Replacement.self, from: data)
        guard try fileNumber(of: url) == replacement.fileNumber else {
            // Publication never happened. The original damaged file is still in place; the regular recovery can start over.
            try FileManager.default.removeItem(at: journalURL(for: url))
            return nil
        }
        return try finishReplacement(of: url, replacement: replacement)
    }

    private static func finishReplacement(of url: URL, replacement: Replacement) throws -> (DatabasePool, Outcome) {
        let staging = stagingURL(for: url)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.moveItem(at: staging, to: replacement.damagedFile)
        }
        let pool = try KuzmemoDatabase.open(at: url)
        try FileManager.default.removeItem(at: journalURL(for: url))
        let outcome: Outcome = replacement.backup.map { .restored(from: $0, damagedFile: replacement.damagedFile) }
            ?? .startedEmpty(damagedFile: replacement.damagedFile)
        return (pool, outcome)
    }

    private static func publish(_ staging: URL, at url: URL, backup: BackupFile?, now: Date, zone: TimeZone) throws -> (DatabasePool, Outcome) {
        let damaged = try damagedName(for: url, now: now, zone: zone)
        let replacement = Replacement(fileNumber: try fileNumber(of: staging), backup: backup, damagedFile: damaged)
        try JSONEncoder().encode(replacement).write(to: journalURL(for: url), options: .atomic)
        try PrivateFiles.file(journalURL(for: url))
        try moveLogFiles(of: url, to: damaged)
        guard renamex_np(staging.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "could not put the replacement in place: \(String(cString: strerror(errno)))"])
        }
        return try finishReplacement(of: url, replacement: replacement)
    }

    private static func restore(_ url: URL, backups directory: URL, now: Date, zone: TimeZone) throws -> (DatabasePool, Outcome) {
        let staging = stagingURL(for: url)
        removeFiles(of: staging) // an older attempt's leftover, unchecked
        // "No copies" and "the copies cannot be listed" are different things: the second is an error, not an empty database.
        for copy in try BackupService.listing(in: directory) {
            do {
                try FileManager.default.copyItem(at: copy.url, to: staging)
                let pool = try KuzmemoDatabase.open(at: staging)
                let verdict = try pool.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check(3)") }
                // Everything (the migrations too) goes into the one file: the log files stay behind when it changes places.
                try pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
                try pool.close()
                guard verdict == ["ok"] else { throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "quick_check: \(verdict)") }
                let log = URL(fileURLWithPath: staging.path + "-wal")
                if let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int, size > 0 {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "the copy's log was not folded into it"])
                }
                removeLogFiles(of: staging)
            } catch let error as DatabaseError where isDamage(error) {
                removeFiles(of: staging) // this copy is no good either; try the next older one
                continue
            } catch {
                removeFiles(of: staging) // no room, no permission, a lock: no copy would do better, and the person has to know
                throw error
            }
            // The damaged file's log files go first (they are its, and SQLite would apply them to the restored file), the two
            // database files change places in one step, and the damaged one is set aside under its own name.
            return try publish(staging, at: url, backup: copy, now: now, zone: zone)
        }
        // Even with no usable backup, build the empty database BEFORE replacing the damaged file. There is never a missing
        // main file that the next launch could mistake for a first launch.
        let empty = try KuzmemoDatabase.open(at: staging)
        try empty.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        try empty.close()
        removeLogFiles(of: staging)
        return try publish(staging, at: url, backup: nil, now: now, zone: zone)
    }

    /// A launch that was killed right after the files changed places left the damaged file at the staging path: it is set
    /// aside now, like any damaged file. A staging file beside a database that is missing cannot happen (the swap needs both),
    /// and one beside a database that is there is either that or an unchecked leftover: both are kept, under a damaged name.
    private static func setAsideLeftover(of url: URL, now: Date, zone: TimeZone) throws {
        let staging = stagingURL(for: url)
        guard FileManager.default.fileExists(atPath: staging.path) else { return }
        let damaged = try damagedName(for: url, now: now, zone: zone)
        try moveLogFiles(of: staging, to: damaged)
        try FileManager.default.moveItem(at: staging, to: damaged)
    }

    /// A name that is free for setting a damaged file aside: `kuzmemo-damaged-<time>.sqlite`, numbered when taken.
    private static func damagedName(for url: URL, now: Date, zone: TimeZone) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let stamp = BackupService.stamp(now, in: zone)
        var unique = folder.appendingPathComponent("kuzmemo-damaged-\(stamp).sqlite")
        var counter = 1
        while ["", "-wal", "-shm"].contains(where: { FileManager.default.fileExists(atPath: unique.path + $0) }) {
            counter += 1
            unique = folder.appendingPathComponent("kuzmemo-damaged-\(stamp)-\(counter).sqlite")
        }
        return unique
    }

    /// Moves the `-wal` and `-shm` files of `url`, when there are any, to the matching names of `target`.
    private static func moveLogFiles(of url: URL, to target: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
    }

    private static func removeFiles(of url: URL) {
        try? FileManager.default.removeItem(at: url)
        removeLogFiles(of: url)
    }

    private static func removeLogFiles(of url: URL) {
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
    }
}

extension Store {
    /// Opens the database at launch, coping with a file too damaged to open (see `DatabaseRecovery`).
    public static func openRecovering(
        at url: URL, backups: URL, clock: any NowProvider
    ) throws -> (store: Store, outcome: DatabaseRecovery.Outcome) {
        let (pool, outcome) = try DatabaseRecovery.open(at: url, backups: backups, now: clock.now(), zone: clock.timeZone)
        return (Store(writer: pool, clock: clock), outcome)
    }
}
