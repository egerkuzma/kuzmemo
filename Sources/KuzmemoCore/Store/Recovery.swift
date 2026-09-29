import Foundation
import GRDB

/// Opens the database at launch and copes with a file that is too damaged to open, instead of failing on every launch.
///
/// A damaged file is never deleted: it is moved next to the database as `kuzmemo-damaged-<time>.sqlite` (with its log
/// files), so it can still be examined or salvaged by hand. Then the newest copy that opens and passes SQLite's check is
/// put in its place; with none, the app starts with an empty database. Only a broken file triggers this; a locked file, a
/// full disk or a missing permission is an ordinary error and is passed on.
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
        do {
            return (try KuzmemoDatabase.open(at: url), .opened)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            let damaged = try setAside(url, now: now, zone: zone)
            for copy in BackupService.list(in: directory) {
                do {
                    try FileManager.default.copyItem(at: copy.url, to: url)
                    let pool = try KuzmemoDatabase.open(at: url)
                    let verdict = try pool.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check(3)") }
                    if verdict == ["ok"] { return (pool, .restored(from: copy, damagedFile: damaged)) }
                } catch {
                    // this copy is no good either; try the next older one
                }
                removeFiles(of: url)
            }
            return (try KuzmemoDatabase.open(at: url), .startedEmpty(damagedFile: damaged))
        }
    }

    /// Moves `kuzmemo.sqlite` and its `-wal` and `-shm` files out of the way; returns the new place of the main file.
    private static func setAside(_ url: URL, now: Date, zone: TimeZone) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let stamp = BackupService.stamp(now, in: zone)
        let target = folder.appendingPathComponent("kuzmemo-damaged-\(stamp).sqlite")
        var unique = target
        var counter = 1
        while FileManager.default.fileExists(atPath: unique.path) {
            counter += 1
            unique = folder.appendingPathComponent("kuzmemo-damaged-\(stamp)-\(counter).sqlite")
        }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: unique.path + suffix))
            }
        }
        return unique
    }

    private static func removeFiles(of url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
    }
}
