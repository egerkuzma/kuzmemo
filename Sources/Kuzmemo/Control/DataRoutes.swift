import Foundation
import KuzmemoCore

/// Control-channel access to the Data page: what the app knows about its database and its copies, and the same
/// actions the page offers. The copies follow the pinned clock (`POST /clock`), which is how a script sees the daily
/// rhythm and the 14-copy limit without waiting days.
enum DataRoutes {
    static func read(_ env: AppEnvironment) async -> HTTPResponse {
        await env.data.refresh()
        return .json(await body(env))
    }

    /// Runs the check now and reports.
    static func check(_ env: AppEnvironment) async -> HTTPResponse {
        await env.data.check()
        return .json(await body(env))
    }

    /// `{"reason": "manual"}` (the default) or `{"reason": "daily"}`: makes a copy now.
    static func backup(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        let reason = (request.jsonBody?["reason"] as? String) ?? "manual"
        guard let kind = BackupReason(rawValue: reason), kind != .beforeErase else {
            return .error("reason must be manual or daily", status: 400)
        }
        do {
            let made = try await env.data.backups.run(kind)
            await env.data.refresh()
            return .json(["made": copy(made)])
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    /// The daily rule: a copy if none has been made on today's date yet. `made` is null when nothing was due.
    static func daily(_ env: AppEnvironment) async -> HTTPResponse {
        do {
            let made = try await env.data.backups.runDailyIfDue()
            await env.data.refresh()
            return .json(["made": made.map(copy) as Any? ?? NSNull()])
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    /// `{"confirm": true}`: saves a copy and erases every entry, saved phrase and undo step (dev bundle only).
    static func erase(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard env.paths.isDev else { return .error("refusing to erase data outside the dev bundle", status: 409) }
        guard request.jsonBody?["confirm"] as? Bool == true else { return .error("body must be {\"confirm\": true}", status: 400) }
        guard let summary = await env.eraseEntriesAndHistory() else {
            return .error(env.data.notice?.text ?? "not erased", status: 409)
        }
        return .json(["erased": ["entries": summary.entries, "memos": summary.memos, "undoSteps": summary.undoSteps]])
    }

    // MARK: Encoding

    private static func body(_ env: AppEnvironment) async -> [String: Any] {
        let data = env.data
        var body: [String: Any] = [
            "database": env.paths.database.path,
            "backupsFolder": env.paths.backups.path,
            "bytes": data.databaseBytes,
            "dailyDue": await data.backups.isDailyDue(),
            "hasProblem": data.hasProblem,
            "copies": data.copies.map(copy),
            "recovery": describe(data.recovery),
            "keep": ["daily": BackupService.dailyKeep, "other": BackupService.otherKeep],
        ]
        if let overview = data.overview {
            body["overview"] = [
                "entries": overview.entries, "memos": overview.memos, "undoSteps": overview.undoSteps,
                "glossaryTerms": overview.glossaryTerms,
            ]
        }
        if let report = data.integrity {
            body["integrity"] = [
                "healthy": report.isHealthy, "problems": report.problems, "searchIndexRebuilt": report.searchIndexRebuilt,
            ]
        }
        if let attention = data.attention { body["attention"] = attention }
        if let notice = data.notice { body["notice"] = ["style": "\(notice.style)", "text": notice.text] }
        return body
    }

    private static func copy(_ file: BackupFile) -> [String: Any] {
        [
            "name": file.url.lastPathComponent, "path": file.url.path, "reason": file.reason.rawValue,
            "day": "\(file.day)", "time": "\(file.time)", "bytes": file.bytes,
        ]
    }

    private static func describe(_ outcome: DatabaseRecovery.Outcome) -> String {
        switch outcome {
        case .opened: "opened"
        case .restored: "restored"
        case .startedEmpty: "startedEmpty"
        }
    }
}
