import Foundation
import GRDB

/// Opens the SQLite database (WAL, single writer) and runs migrations.
public enum KuzmemoDatabase {
    /// Volatile database for tests and previews.
    public static func inMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        return queue
    }

    /// Persistent database at `url`. Creates parent folders, enables WAL and foreign keys.
    public static func open(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try Schema.migrator().migrate(pool)
        return pool
    }
}
