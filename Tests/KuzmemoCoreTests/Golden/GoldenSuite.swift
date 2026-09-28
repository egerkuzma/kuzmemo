import Foundation
@testable import KuzmemoCore

// The golden phrase set: real Russian commands with expected outcomes relative to a fixed "now"
// (Monday 2026-09-28 14:30 Europe/Moscow unless a case says otherwise). It runs in two modes:
//   - replay: recorded model answers go through the validator offline (default, part of `swift test`);
//   - live:   `KUZMEMO_LIVE_CLAUDE=1 swift test --filter liveAgainstClaude` asks the real `claude -p`
//             (KUZMEMO_GOLDEN_REPEATS=3 for the report used to pick the model, KUZMEMO_RECORD=1 to refresh
//             the recorded answers).

struct GoldenFixtureItem: Codable, Sendable {
    var id: String
    var kind: ItemKind
    var title: String
    var date: String?
    var time: String?
    var recurrence: Recurrence?
}

struct GoldenExpectedRecurrence: Codable, Sendable {
    var freq: Recurrence.Frequency
    var interval: Int?
    var byWeekday: [Weekday]?
    var byMonthday: Int?
}

struct GoldenExpectation: Codable, Sendable {
    var outcome: String
    var alsoAccept: [String]?
    var reason: String?
    var kinds: [ItemKind]?
    var date: String?
    var dateFrom: String?
    var dateThrough: String?
    var time: String?
    var noTime: Bool?
    var noDate: Bool?
    var titleHas: [String]?
    var textHas: [String]?
    var approximate: Bool?
    var recurrence: GoldenExpectedRecurrence?
    var count: Int?
    var maxCount: Int?
    var ref: String?
    var target: String?
    var from: String?
    var through: String?
}

struct GoldenCase: Codable, Sendable {
    var id: String
    var category: String
    var anchor: String?
    var transcript: String
    var items: [GoldenFixtureItem]?
    var expect: GoldenExpectation
}

struct GoldenRun: Sendable {
    var caseID: String
    var category: String
    var passed: Bool
    var failures: [String]
    var label: String
    var wallMs: Int
    var reportedMs: Int?
    var costUSD: Double?
    var rawAnswer: String?
    var error: String?
}

enum Golden {
    static let defaultAnchor = "2026-09-28 14:30"
    static let moscow = TimeZone(identifier: "Europe/Moscow")!

    static var directory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    static var packageRoot: URL { directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    static func loadCases() throws -> [GoldenCase] {
        let text = try String(contentsOf: directory.appendingPathComponent("phrases.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(GoldenCase.self, from: Data($0.utf8)) }
    }

    static var cassetteURL: URL { directory.appendingPathComponent("cassettes/cassettes.jsonl") }

    /// Recorded model answers by case id.
    static func loadCassettes() -> [String: String] {
        guard let text = try? String(contentsOf: cassetteURL, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  let id = object["id"], let structured = object["structured"] else { continue }
            result[id] = structured
        }
        return result
    }

    static let glossary: [GlossaryTerm] = [
        GlossaryTerm(canonical: "Notion", aliases: ["нотион", "ношн", "нотиона"]),
        GlossaryTerm(canonical: "GitHub", aliases: ["гитхаб", "гит"]),
        GlossaryTerm(canonical: "Figma", aliases: ["фигма", "фигмы", "Фигма"]),
        GlossaryTerm(canonical: "Slack", aliases: ["слак"]),
        GlossaryTerm(canonical: "Zoom", aliases: ["зум", "клик аду"]),
        GlossaryTerm(canonical: "Дмитрий", aliases: []),
    ]

    static func anchor(for c: GoldenCase) -> LocalDateTime {
        let parts = (c.anchor ?? defaultAnchor).split(separator: " ")
        return LocalDateTime(date: LocalDate(String(parts[0]))!, time: LocalTime(String(parts[1]))!)
    }

    /// A fresh in-memory store holding the case's existing entries and the standard glossary.
    static func store(for c: GoldenCase) async throws -> Store {
        let text = c.anchor ?? defaultAnchor
        let clock = FixedNow(local: text, in: moscow)!
        let store = Store(writer: try KuzmemoDatabase.inMemory(), clock: clock)
        for term in glossary { try await store.save(term: term) }
        let fixtures = c.items ?? []
        if !fixtures.isEmpty {
            try await store.perform(label: "fixtures") { m in
                for f in fixtures {
                    try m.insert(Item(
                        id: f.id, kind: f.kind, title: f.title, date: f.date.flatMap(LocalDate.init),
                        time: f.time.flatMap(LocalTime.init), recurrence: f.recurrence, source: .manual
                    ))
                }
            }
        }
        return store
    }

    // MARK: Replay

    static func replay(_ c: GoldenCase, structured: String) async throws -> (Interpretation, ParserResponse) {
        let store = try await store(for: c)
        let anchor = anchor(for: c)
        let transcript = Glossary.applyAliases(to: c.transcript, terms: glossary)
        let context = try await ContextPlanner().plan(transcript: transcript, anchor: anchor, store: store)
        let response = try Interpreter.decode(structured)
        let interpretation = await ActionValidator.validate(response, in: ValidationContext(
            context: context, resolver: RelativeDateResolver(anchor: anchor), store: store
        ))
        return (interpretation, response)
    }

    // MARK: Live

    static func live(_ c: GoldenCase, provider: any LLMProvider, model: String) async -> GoldenRun {
        do {
            let store = try await store(for: c)
            let interpreter = Interpreter(store: store, provider: provider, model: model)
            let started = Date()
            let result = try await interpreter.interpret(InterpretRequest(transcript: c.transcript, anchor: anchor(for: c), timeZone: moscow))
            let failures = check(result.interpretation, against: c.expect)
            return GoldenRun(
                caseID: c.id, category: c.category, passed: failures.isEmpty, failures: failures,
                label: label(result.interpretation), wallMs: Int(Date().timeIntervalSince(started) * 1000),
                reportedMs: result.llm.reportedMs, costUSD: result.llm.costUSD, rawAnswer: result.llm.structuredJSON, error: nil
            )
        } catch {
            return GoldenRun(caseID: c.id, category: c.category, passed: false, failures: ["error: \(error)"], label: "error",
                             wallMs: 0, reportedMs: nil, costUSD: nil, rawAnswer: nil, error: "\(error)")
        }
    }

    // MARK: Checking

    static func label(_ interpretation: Interpretation) -> String {
        switch interpretation {
        case let .mutate(plan):
            switch plan.actions.first {
            case .create: return "create"
            case .update, .moveOccurrence: return "update"
            case .complete, .reopen: return "complete"
            case .delete: return "delete"
            case .skipOccurrence: return "skip"
            case nil: return "empty"
            }
        case .query: return "query"
        case .clarify: return "clarify"
        case .unknown: return "unknown"
        }
    }

    private static func fold(_ text: String) -> String { SearchText.normalize(text) }

    static func check(_ interpretation: Interpretation, against e: GoldenExpectation) -> [String] {
        let got = label(interpretation)
        let acceptable = [e.outcome] + (e.alsoAccept ?? [])
        guard acceptable.contains(got) else { return ["expected outcome \(acceptable.joined(separator: "/")), got \(got): \(interpretation)"] }
        guard got == e.outcome else { return [] } // an accepted alternative: no detail checks

        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }

        switch interpretation {
        case let .mutate(plan):
            switch e.outcome {
            case "create":
                let creates = plan.actions.compactMap { action -> NewItem? in if case let .create(new) = action { new } else { nil } }
                if let count = e.count { expect(creates.count == count, "expected \(count) items, got \(creates.count)") }
                if let max = e.maxCount { expect(creates.count <= max, "expected at most \(max) items, got \(creates.count)") }
                guard let first = creates.first else { break }
                if let kinds = e.kinds { expect(kinds.contains(first.kind), "kind \(first.kind), expected one of \(kinds)") }
                if let date = e.date { expect(first.date == LocalDate(date), "date \(first.date.map(\.description) ?? "nil"), expected \(date)") }
                if let from = e.dateFrom, let through = e.dateThrough, let d = first.date {
                    expect(d >= LocalDate(from)! && d <= LocalDate(through)!, "date \(d), expected \(from)...\(through)")
                } else if e.dateFrom != nil {
                    failures.append("no date, expected \(e.dateFrom!)...\(e.dateThrough ?? "")")
                }
                if let time = e.time { expect(first.time == LocalTime(time), "time \(first.time.map(\.description) ?? "nil"), expected \(time)") }
                if e.noTime == true { expect(first.time == nil, "expected no time, got \(first.time.map(\.description) ?? "")") }
                if e.noDate == true { expect(first.date == nil, "expected no date, got \(first.date.map(\.description) ?? "")") }
                if let approximate = e.approximate { expect(first.approximate == approximate, "approximate \(first.approximate)") }
                for word in e.titleHas ?? [] { expect(fold(first.title).contains(fold(word)), "title «\(first.title)» lacks «\(word)»") }
                let text = fold([first.title, first.details ?? "", first.keywords].joined(separator: " "))
                for word in e.textHas ?? [] { expect(text.contains(fold(word)), "text «\(text)» lacks «\(word)»") }
                if let r = e.recurrence {
                    if let got = first.recurrence {
                        expect(got.freq == r.freq, "recurrence \(got.freq), expected \(r.freq)")
                        expect(got.interval == (r.interval ?? 1), "interval \(got.interval), expected \(r.interval ?? 1)")
                        if let days = r.byWeekday { expect(Set(got.byWeekday ?? []) == Set(days), "weekdays \(got.byWeekday ?? []), expected \(days)") }
                        if let day = r.byMonthday { expect(got.byMonthday == day, "month day \(got.byMonthday.map(String.init) ?? "nil"), expected \(day)") }
                    } else {
                        failures.append("expected a recurrence \(r.freq)")
                    }
                }
            case "update":
                switch plan.actions.first {
                case let .update(id, changes)?:
                    if let ref = e.ref { expect(id == ref, "target \(id), expected \(ref)") }
                    if let date = e.date { expect(changes.date == LocalDate(date), "date \(changes.date.map(\.description) ?? "nil"), expected \(date)") }
                    if let time = e.time { expect(changes.time == LocalTime(time), "time \(changes.time.map(\.description) ?? "nil"), expected \(time)") }
                case let .moveOccurrence(id, _, newDate, newTime)?:
                    if let ref = e.ref { expect(id == ref, "target \(id), expected \(ref)") }
                    if let date = e.date { expect(newDate == LocalDate(date), "date \(newDate), expected \(date)") }
                    if let time = e.time { expect(newTime == LocalTime(time), "time \(newTime.map(\.description) ?? "nil"), expected \(time)") }
                default:
                    failures.append("unexpected first action")
                }
            case "complete", "delete", "skip":
                let id: String? = switch plan.actions.first {
                case let .complete(id, _)?, let .reopen(id, _)?, let .delete(id)?, let .skipOccurrence(id, _)?: id
                default: nil
                }
                if let ref = e.ref { expect(id == ref, "target \(id ?? "nil"), expected \(ref)") }
            default:
                break
            }
        case let .query(plan):
            switch (e.target, plan.target) {
            case ("days", let .days(range)):
                if let from = e.from { expect(range.lowerBound == LocalDate(from), "from \(range.lowerBound), expected \(from)") }
                if let through = e.through { expect(range.upperBound == LocalDate(through), "through \(range.upperBound), expected \(through)") }
            case ("upcoming", .upcoming), ("overdue", .overdue), ("inbox", .inbox), ("recurring", .recurring):
                break
            case ("search", let .search(text)):
                for word in e.textHas ?? [] { expect(fold(text).contains(fold(word)), "search text «\(text)» lacks «\(word)»") }
            case (nil, _):
                break
            default:
                failures.append("query target \(plan.target), expected \(e.target ?? "?")")
            }
        case let .clarify(c):
            if let reason = e.reason { expect(c.reason.rawValue == reason, "reason \(c.reason.rawValue), expected \(reason)") }
        case .unknown:
            break
        }
        return failures
    }

    // MARK: Report

    static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.down)))]
    }

    static func report(model: String, runs: [GoldenRun], repeats: Int) -> String {
        let passed = runs.filter(\.passed).count
        var lines = ["# Golden run: \(model), \(repeats) repeat(s)", ""]
        lines.append("Overall: \(passed)/\(runs.count) = \(String(format: "%.1f", 100 * Double(passed) / Double(max(runs.count, 1)))) %")
        let walls = runs.map(\.wallMs).filter { $0 > 0 }
        lines.append("Wall time per phrase: p50 \(percentile(walls, 0.5)) ms, p95 \(percentile(walls, 0.95)) ms")
        let costs = runs.compactMap(\.costUSD)
        if !costs.isEmpty { lines.append("Mean cost per phrase: $\(String(format: "%.4f", costs.reduce(0, +) / Double(costs.count)))") }
        lines.append("")
        lines.append("| Category | Passed |")
        lines.append("|---|---|")
        for category in Set(runs.map(\.category)).sorted() {
            let group = runs.filter { $0.category == category }
            lines.append("| \(category) | \(group.filter(\.passed).count)/\(group.count) |")
        }
        let failed = runs.filter { !$0.passed }
        if !failed.isEmpty {
            lines.append("")
            lines.append("## Failures")
            for run in failed {
                lines.append("")
                lines.append("- **\(run.caseID)** (\(run.category)), got \(run.label)")
                for failure in run.failures { lines.append("  - \(failure)") }
                if let raw = run.rawAnswer { lines.append("  - model answer: `\(raw.prefix(600))`") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
