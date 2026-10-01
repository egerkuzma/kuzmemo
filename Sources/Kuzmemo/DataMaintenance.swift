import AppKit
import Foundation
import KuzmemoCore
import Observation
import os

/// What the Data page of the settings shows and does: how big the database is and whether it is sound, the copies kept
/// of it, and the erase. It also runs the automatic part: a check shortly after launch and one copy a day.
@Observable
final class DataMaintenance {
    struct Notice: Equatable {
        enum Style { case success, failure }
        var style: Style
        var text: String
    }

    private static let log = Logger(subsystem: "app.kuzmemo", category: "data")

    private let store: Store
    private let paths: AppPaths
    private let clock: any NowProvider
    let backups: BackupService
    /// How the database was opened at launch; anything but `.opened` means the file was damaged and was dealt with.
    let recovery: DatabaseRecovery.Outcome

    private(set) var overview: DataOverview?
    private(set) var databaseBytes: Int64 = 0
    private(set) var integrity: IntegrityReport?
    private(set) var copies: [BackupFile] = []
    private(set) var isChecking = false
    private(set) var isBackingUp = false
    private(set) var isErasing = false
    /// The outcome of the last thing the person asked for on the page.
    private(set) var notice: Notice?
    /// The person has opened the page that explains what happened at launch.
    private(set) var recoverySeen = false

    /// Called once when the check finds a problem (the app shows a toast).
    @ObservationIgnored var onProblem: (() -> Void)?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var lastCheckDay: LocalDate?
    @ObservationIgnored private var reportedProblem = false

    init(store: Store, paths: AppPaths, clock: any NowProvider, recovery: DatabaseRecovery.Outcome) {
        self.store = store
        self.paths = paths
        self.clock = clock
        self.recovery = recovery
        backups = BackupService(store: store, directory: paths.backups)
    }

    var isWorking: Bool { isChecking || isBackingUp || isErasing }

    /// Something the person should know about: a failed check, or a database that had to be dealt with at launch.
    var attention: String? {
        if let integrity, !integrity.isHealthy {
            return tr(
                "The database check found problems: %1$@. The copies in the backups folder are untouched.",
                integrity.problems.prefix(3).joined(separator: "; ")
            )
        }
        switch recovery {
        case .opened:
            return nil
        case let .restored(copy, damaged):
            return tr(
                "The database could not be opened at launch. The copy from %1$@ was put in its place, so entries made after that are missing. The damaged file was kept as %2$@.",
                Self.describe(copy), damaged.lastPathComponent
            )
        case let .startedEmpty(damaged):
            return tr(
                "The database could not be opened at launch and there was no copy, so Kuzmemo started empty. The damaged file was kept as %1$@.",
                damaged.lastPathComponent
            )
        }
    }

    /// Whether the menu-bar icon should warn: a failed check, or a recovery at launch that nobody has looked at yet. The
    /// explanation itself (`attention`) stays on the page for the whole session.
    var hasProblem: Bool {
        if integrity?.isHealthy == false { return true }
        if case .opened = recovery { return false }
        return !recoverySeen
    }

    func markRecoverySeen() { recoverySeen = true }

    // MARK: - The automatic part

    /// A check a few seconds after launch (and once a day after that) and the daily copy, tried every half hour so that a
    /// Mac that stays on for weeks still gets one per day.
    func start() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8)) // let the launch settle first
            while !Task.isCancelled {
                await self?.runScheduled()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
        Task { await refresh() }
    }

    func runScheduled() async {
        let today = clock.localNow().date
        if lastCheckDay != today {
            lastCheckDay = today
            await check()
        }
        // A copy of a damaged file would, in time, push the good copies out of the folder: make none while it is damaged.
        if integrity?.isHealthy == false { return }
        do {
            if let made = try await backups.runDailyIfDue() {
                Self.log.notice("daily copy \(made.url.lastPathComponent, privacy: .public)")
            }
        } catch {
            Self.log.error("daily copy failed: \(String(describing: error), privacy: .public)")
            notice = Notice(style: .failure, text: tr("Could not save the daily copy: %1$@", "\(error)"))
        }
        await refresh()
    }

    // MARK: - What the person asks for

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let report: IntegrityReport
        do {
            report = try await store.integrityCheck()
        } catch {
            report = IntegrityReport(checkedAt: clock.now(), problems: ["\(error)"])
        }
        integrity = report
        if !report.isHealthy {
            Self.log.fault("integrity check failed: \(report.problems.joined(separator: " | "), privacy: .public)")
            if !reportedProblem {
                reportedProblem = true
                onProblem?()
            }
        } else if report.searchIndexRebuilt {
            Self.log.notice("the search index did not match the entries and was rebuilt")
        }
    }

    func backUpNow() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let file = try await backups.run(.manual)
            notice = Notice(style: .success, text: tr("Copy saved: %1$@.", Self.describe(file)))
        } catch {
            notice = Notice(style: .failure, text: tr("Could not save a copy: %1$@", "\(error)"))
        }
        await refresh()
    }

    /// Saves a copy, then erases. Nothing is erased when the copy cannot be made. Returns what was removed.
    func erase() async -> EraseSummary? {
        guard !isErasing else { return nil }
        isErasing = true
        defer { isErasing = false }
        do {
            try await backups.run(.beforeErase)
            let summary = try await store.eraseEntriesAndHistory()
            let spool = AudioSpool(directory: paths.audioSpool) // recordings still waiting for recognition belong to the erased phrases
            for file in spool.files() { spool.remove(path: file) }
            // What the voices keep of the phrases they have said: the lines "My voice" made (agenda lines hold the titles of
            // entries, in the person's own voice, and have no age limit) and any phrase the neural voice has not played yet.
            OmniVoiceCache(directory: paths.voiceCache).clear()
            for url in (try? FileManager.default.contentsOfDirectory(at: paths.speechCache, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
            notice = Notice(
                style: .success,
                text: tr(
                    "Erased %1$@ and %2$@. The copy from just before is in the backups folder.",
                    trCount("%lld entries", summary.entries), trCount("%lld saved phrases", summary.memos)
                )
            )
            await refresh()
            return summary
        } catch {
            notice = Notice(style: .failure, text: tr("Nothing was erased: %1$@", "\(error)"))
            await refresh()
            return nil
        }
    }

    func refresh() async {
        if let fresh = try? await store.overview() { overview = fresh } // a cancelled read must not blank what is known
        databaseBytes = Self.size(of: paths.database) + Self.size(of: URL(fileURLWithPath: paths.database.path + "-wal"))
        copies = backups.list()
    }

    /// The result line under the buttons belongs to the moment it was made: it goes when the page is left.
    func clearNotice() { notice = nil }

    func showBackups() {
        try? FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        if let latest = copies.first {
            NSWorkspace.shared.activateFileViewerSelecting([latest.url])
        } else {
            NSWorkspace.shared.open(paths.backups)
        }
    }

    // MARK: - Wording

    /// "29 September, 18:30" in the interface language.
    static func describe(_ copy: BackupFile) -> String { "\(Wording.date(copy.day)), \(Wording.time(copy.time))" }

    static func title(of reason: BackupReason) -> String {
        switch reason {
        case .daily: tr("daily")
        case .manual: tr("by hand")
        case .beforeErase: tr("before an erase")
        }
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
