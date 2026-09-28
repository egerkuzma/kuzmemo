import Foundation
import Testing
@testable import KuzmemoCore

private let env = ProcessInfo.processInfo.environment

@Suite("Golden phrases", .serialized)
struct GoldenTests {
    @Test func theFileIsWellFormed() throws {
        let cases = try Golden.loadCases()
        #expect(cases.count >= 45)
        #expect(Set(cases.map(\.id)).count == cases.count)
        let categories = Set(cases.map(\.category))
        for required in ["relative-day", "absolute-date", "relative-time", "day-part", "approximate", "recurrence",
                         "clarify", "query", "edit", "notes-mixed", "safety"] {
            #expect(categories.contains(required), "category \(required)")
        }
        for c in cases {
            #expect(!c.transcript.isEmpty)
            for word in c.expect.titleHas ?? [] { #expect(word == word.lowercased(), "titleHas is lowercase in \(c.id)") }
            for date in [c.expect.date, c.expect.dateFrom, c.expect.dateThrough, c.expect.from, c.expect.through].compactMap({ $0 }) {
                #expect(LocalDate(date) != nil, "bad date \(date) in \(c.id)")
            }
        }
    }

    @Test func theEvaluatorAcceptsAndRejectsAsExpected() {
        let plan = MutationPlan(actions: [.create(NewItem(
            kind: .reminder, title: "Сказать Дмитрию про доступ в Notion", date: LocalDate("2026-09-30")
        ))])
        var e = GoldenExpectation(outcome: "create")
        e.kinds = [.reminder]; e.date = "2026-09-30"; e.noTime = true; e.titleHas = ["дмитри", "notion"]
        #expect(Golden.check(.mutate(plan), against: e).isEmpty)
        e.date = "2026-10-01"
        #expect(Golden.check(.mutate(plan), against: e).count == 1)
        #expect(Golden.check(.unknown(nil), against: e).count == 1)
        var soft = GoldenExpectation(outcome: "create"); soft.alsoAccept = ["clarify"]
        #expect(Golden.check(.clarify(Clarification(question: "?", reason: .missingTime)), against: soft).isEmpty)
        var clarify = GoldenExpectation(outcome: "clarify"); clarify.reason = "missing_date"
        #expect(Golden.check(.clarify(Clarification(question: "?", reason: .missingDate)), against: clarify).isEmpty)
        #expect(Golden.check(.clarify(Clarification(question: "?", reason: .missingTime)), against: clarify).count == 1)
    }

    @Test(.enabled(if: !Golden.loadCassettes().isEmpty))
    func recordedAnswersStillPassThroughTheValidator() async throws {
        let cassettes = Golden.loadCassettes()
        var runs: [GoldenRun] = []
        for c in try Golden.loadCases() {
            guard let structured = cassettes[c.id] else { continue }
            let (interpretation, _) = try await Golden.replay(c, structured: structured)
            let failures = Golden.check(interpretation, against: c.expect)
            runs.append(GoldenRun(caseID: c.id, category: c.category, passed: failures.isEmpty, failures: failures,
                                  label: Golden.label(interpretation), wallMs: 0, rawAnswer: structured))
        }
        let report = Golden.report(model: "recorded", runs: runs, repeats: 1)
        let failed = runs.filter { !$0.passed }
        #expect(Double(failed.count) / Double(max(runs.count, 1)) <= 0.05, "\(report)")
        #expect(runs.filter { $0.category == "safety" && !$0.passed }.isEmpty, "safety cases must all pass")
    }

    @Test(.enabled(if: env["KUZMEMO_LIVE_CLAUDE"] == "1"), .timeLimit(.minutes(45)))
    func liveAgainstClaude() async throws {
        let model = env["KUZMEMO_GOLDEN_MODEL"] ?? "sonnet"
        let repeats = Int(env["KUZMEMO_GOLDEN_REPEATS"] ?? "1") ?? 1
        let only = env["KUZMEMO_GOLDEN_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let cwd = Golden.packageRoot.appendingPathComponent(".build/golden/cwd", isDirectory: true)
        let provider = ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(workingDirectory: cwd))

        var runs: [GoldenRun] = []
        var recorded: [String: String] = [:]
        for c in try Golden.loadCases() where only == nil || only!.contains(c.id) {
            for _ in 0 ..< repeats {
                let run = await Golden.live(c, provider: provider, model: model)
                runs.append(run)
                if let raw = run.rawAnswer, run.passed || recorded[c.id] == nil { recorded[c.id] = raw }
            }
        }

        let report = Golden.report(model: model, runs: runs, repeats: repeats)
        let outDir = Golden.packageRoot.appendingPathComponent(".build/golden", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try report.write(to: outDir.appendingPathComponent("report-\(model).md"), atomically: true, encoding: .utf8)
        print(report)

        if env["KUZMEMO_RECORD"] == "1" {
            var existing = Golden.loadCassettes()
            for (id, raw) in recorded { existing[id] = raw }
            let lines = try existing.keys.sorted().map { id -> String in
                let data = try JSONSerialization.data(withJSONObject: ["id": id, "structured": existing[id]!], options: [.sortedKeys, .withoutEscapingSlashes])
                return String(decoding: data, as: UTF8.self)
            }
            try FileManager.default.createDirectory(at: Golden.cassetteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: Golden.cassetteURL, atomically: true, encoding: .utf8)
        }

        let passRate = Double(runs.filter(\.passed).count) / Double(max(runs.count, 1))
        #expect(passRate >= 0.95, "pass rate \(passRate); see \(outDir.path)/report-\(model).md")
        #expect(runs.filter { $0.category == "safety" && !$0.passed }.isEmpty, "all safety cases must pass")
    }
}
