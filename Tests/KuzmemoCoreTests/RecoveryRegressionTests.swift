import Darwin
import Foundation
import GRDB
import Testing
@testable import KuzmemoCore

@Suite("Review regressions: interrupted recovery and permissions")
struct RecoveryRegressionTests {
    @Test(arguments: [false, true]) func emptyRecoveryCanResumeOnEitherSideOfPublication(published: Bool) throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("kuzmemo-recovery-journal-\(UUID())")
        try PrivateFiles.directory(root)
        defer { try? files.removeItem(at: root) }
        let main = root.appendingPathComponent("kuzmemo.sqlite")
        let staging = DatabaseRecovery.stagingURL(for: main)
        let damaged = root.appendingPathComponent("original-damaged.sqlite")
        let original = Data(repeating: 0xFF, count: 12288)
        try original.write(to: main)
        let empty = try KuzmemoDatabase.open(at: staging)
        try empty.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        try empty.close()
        let number = try #require(try files.attributesOfItem(atPath: staging.path)[.systemFileNumber] as? NSNumber)
        let journal = DatabaseRecovery.Replacement(fileNumber: number.uint64Value, backup: nil, damagedFile: damaged)
        try JSONEncoder().encode(journal).write(to: DatabaseRecovery.journalURL(for: main), options: .atomic)
        if published { #expect(renamex_np(staging.path, main.path, UInt32(RENAME_SWAP)) == 0) }
        let (pool, outcome) = try DatabaseRecovery.open(at: main, backups: root.appendingPathComponent("missing-backups"))
        defer { try? pool.close() }
        guard case let .startedEmpty(aside) = outcome else { Issue.record("recovery warning lost: \(outcome)"); return }
        #expect(try Data(contentsOf: aside) == original)
        #expect(try pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") } == 0)
        #expect(files.fileExists(atPath: main.path))
        #expect(!files.fileExists(atPath: DatabaseRecovery.journalURL(for: main).path))
    }

    @Test func anInaccessibleSymlinkToBackupsIsAnError() throws {
        guard geteuid() != 0 else { return } // root can read mode-000 directories
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("kuzmemo-backup-permissions-\(UUID())")
        let parent = root.appendingPathComponent("denied")
        let backups = parent.appendingPathComponent("backups")
        try PrivateFiles.directory(backups)
        let link = root.appendingPathComponent("link")
        try files.createSymbolicLink(at: link, withDestinationURL: backups)
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? files.removeItem(at: root)
        }
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        #expect(throws: (any Error).self) { try BackupService.listing(in: link) }
    }

    @Test func databaseAndSpoolHavePrivatePermissions() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("kuzmemo-private-\(UUID())")
        try PrivateFiles.directory(root)
        defer { try? files.removeItem(at: root) }
        let database = root.appendingPathComponent("kuzmemo.sqlite")
        let pool = try KuzmemoDatabase.open(at: database)
        defer { try? pool.close() }
        let audio = try AudioSpool(directory: root.appendingPathComponent("spool")).write([0, 1, 0], name: "test")
        func permissions(_ path: String) throws -> Int {
            try #require(try files.attributesOfItem(atPath: path)[.posixPermissions] as? Int) & 0o777
        }
        #expect(try permissions(root.path) == 0o700)
        #expect(try permissions(database.path) == 0o600)
        #expect(try permissions(audio) == 0o600)
    }
}
