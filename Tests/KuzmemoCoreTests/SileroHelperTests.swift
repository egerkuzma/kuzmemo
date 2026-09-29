import Foundation
import Testing
@testable import KuzmemoCore

private let python = URL(fileURLWithPath: "/usr/bin/python3")

/// A stand-in for `silero_helper.py` that speaks the same protocol with the standard library only. Its "model" file
/// holds JSON with instructions (a mode, a start delay and a log path), and the texts "crash", "hang", "slow" and
/// "fail" make it misbehave.
private let fakeHelper = #"""
import json, math, os, struct, sys, time, wave

config = json.load(open(sys.argv[1]))
log = config.get("log")

def note(text):
    if log:
        with open(log, "a") as f:
            f.write(text + "\n")

proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
os.dup2(2, 1)

def send(message):
    proto.write(json.dumps(message, ensure_ascii=False) + "\n")
    proto.flush()

note("start")
if config.get("mode") == "bad-model":
    send({"event": "error", "error": "the model cannot be loaded: boom"})
    sys.exit(2)
time.sleep(config.get("startDelay", 0))
send({"event": "ready", "speakers": ["eugene", "xenia"], "torch": "fake", "load_ms": 5})
for line in sys.stdin:
    request = json.loads(line)
    if request.get("op") == "quit":
        break
    if request.get("op") != "say":
        continue
    text = request["text"]
    note("say " + text + " " + request["speaker"] + " " + request["rate"])
    if text == "crash":
        os._exit(9)
    if text == "hang":
        time.sleep(60)
    if text == "slow":
        time.sleep(0.6)
    if text == "fail":
        send({"id": request["id"], "ok": False, "error": "boom"})
        continue
    seconds = round(len(text) / 20, 2)
    rate = 24000
    with wave.open(request["out"], "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(int(rate * seconds))))
    send({"id": request["id"], "ok": True, "path": request["out"], "seconds": seconds, "ms": 1})
note("quit")
"""#

private struct Fixture {
    let directory: URL
    let launch: SileroHelper.Launch
    let output: URL
    let log: URL

    init(config: [String: Any] = [:]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("silero-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        output = directory.appendingPathComponent("out")
        log = directory.appendingPathComponent("log.txt")
        let script = directory.appendingPathComponent("fake_helper.py")
        try fakeHelper.write(to: script, atomically: true, encoding: .utf8)
        var settings = config
        settings["log"] = log.path
        let model = directory.appendingPathComponent("model.json")
        try JSONSerialization.data(withJSONObject: settings).write(to: model)
        launch = SileroHelper.Launch(python: python, script: script, model: model)
    }

    func helper(idle: TimeInterval = 600, start: TimeInterval = 20, request: TimeInterval = 20) -> SileroHelper {
        SileroHelper(launch: launch, outputDirectory: output, idleSeconds: idle, startTimeout: start, requestTimeout: request)
    }

    var logLines: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    var starts: Int { logLines.filter { $0 == "start" }.count }
    var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("SileroHelper", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
struct SileroHelperTests {
    @Test func speaksAPhraseIntoAWavFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        let phrase = try await helper.synthesize(text: "Здравствуйте, это проверка", speaker: "xenia", rate: .fast)
        defer { try? FileManager.default.removeItem(at: phrase.url) }
        let speakers = await helper.speakers
        let ready = await helper.isReady
        #expect(speakers == ["eugene", "xenia"] && ready)
        #expect(phrase.seconds == 1.3)
        let data = try Data(contentsOf: phrase.url)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: data[8 ..< 12], as: UTF8.self) == "WAVE")
        #expect(fixture.logLines.contains("say Здравствуйте, это проверка xenia fast"))
        await helper.stop()
    }

    @Test func oneProcessServesManyPhrases() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        for text in ["раз", "два", "три"] {
            let phrase = try await helper.synthesize(text: text, speaker: "eugene")
            try? FileManager.default.removeItem(at: phrase.url)
        }
        #expect(fixture.starts == 1)
        await helper.stop()
        #expect(fixture.logLines.last == "quit")
        #expect(await !helper.isRunning)
    }

    @Test func requestsThatOverlapAreAllAnswered() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        try await helper.prepare()
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for text in ["первая фраза", "вторая фраза", "третья фраза"] {
                group.addTask { try await helper.synthesize(text: text, speaker: "eugene").url }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(urls).count == 3 && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await helper.stop()
    }

    @Test func aFailedPhraseIsReportedAndTheHelperKeepsWorking() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        await #expect(throws: SileroError.failed("boom")) { try await helper.synthesize(text: "fail", speaker: "eugene") }
        let phrase = try await helper.synthesize(text: "снова работает", speaker: "eugene")
        #expect(fixture.starts == 1 && FileManager.default.fileExists(atPath: phrase.url.path))
        await helper.stop()
    }

    @Test func aCrashedHelperIsReplacedOnTheNextRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        do {
            _ = try await helper.synthesize(text: "crash", speaker: "eugene")
            Issue.record("the crash should have been reported")
        } catch let error as SileroError {
            guard case .exited = error else { Issue.record("wrong error: \(error)"); return }
        }
        let phrase = try await helper.synthesize(text: "после сбоя", speaker: "eugene")
        #expect(fixture.starts == 2 && FileManager.default.fileExists(atPath: phrase.url.path))
        await helper.stop()
    }

    @Test func aBrokenModelIsReportedAtStart() async throws {
        let fixture = try Fixture(config: ["mode": "bad-model"])
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        do {
            try await helper.prepare()
            Issue.record("the start should have failed")
        } catch let error as SileroError {
            guard case let .startFailed(text) = error else { Issue.record("wrong error: \(error)"); return }
            #expect(text.contains("boom"))
        }
        #expect(await !helper.isRunning)
    }

    @Test func aMissingInterpreterIsReportedAtStart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let broken = SileroHelper.Launch(python: URL(fileURLWithPath: "/nonexistent/python"), script: fixture.launch.script, model: fixture.launch.model)
        let helper = SileroHelper(launch: broken, outputDirectory: fixture.output)
        do {
            try await helper.prepare()
            Issue.record("the start should have failed")
        } catch let error as SileroError {
            guard case .startFailed = error else { Issue.record("wrong error: \(error)"); return }
        }
    }

    @Test func aSlowStartTimesOut() async throws {
        let fixture = try Fixture(config: ["startDelay": 5])
        defer { fixture.cleanUp() }
        let helper = fixture.helper(start: 0.5)
        do {
            try await helper.prepare()
            Issue.record("the start should have timed out")
        } catch let error as SileroError {
            guard case .startFailed = error else { Issue.record("wrong error: \(error)"); return }
        }
        #expect(await !helper.isRunning)
    }

    @Test func aHungPhraseTimesOutAndTheHelperIsReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper(request: 0.6)
        await #expect(throws: SileroError.timedOut) { try await helper.synthesize(text: "hang", speaker: "eugene") }
        let phrase = try await helper.synthesize(text: "ещё раз", speaker: "eugene")
        #expect(fixture.starts == 2 && FileManager.default.fileExists(atPath: phrase.url.path))
        await helper.stop()
    }

    @Test func aCancelledPhraseReturnsAtOnceAndLeavesNoFileBehind() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper()
        try await helper.prepare()
        let started = Date()
        let task = Task { try await helper.synthesize(text: "slow", speaker: "eugene") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("the phrase should have been cancelled")
        } catch is CancellationError {}
        #expect(Date().timeIntervalSince(started) < 0.5)
        let next = try await helper.synthesize(text: "следующая", speaker: "eugene")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(fixture.files == [next.url.lastPathComponent], "the abandoned phrase's file was deleted: \(fixture.files)")
        await helper.stop()
    }

    @Test func anIdleHelperIsStoppedAndStartedAgainWhenNeeded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let helper = fixture.helper(idle: 0.4)
        let first = try await helper.synthesize(text: "раз", speaker: "eugene")
        try? FileManager.default.removeItem(at: first.url)
        #expect(await helper.isRunning)
        try await Task.sleep(for: .seconds(1.5))
        #expect(await !helper.isRunning)
        let second = try await helper.synthesize(text: "два", speaker: "eugene")
        try? FileManager.default.removeItem(at: second.url)
        #expect(fixture.starts == 2)
        await helper.stop()
    }
}

@Suite("SileroLocator")
struct SileroLocatorTests {
    /// A home directory with the pieces the test asks for.
    private func home(_ build: (URL) throws -> Void) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("silero-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try build(home)
        return home
    }

    private func venv(at root: URL, torch: Bool) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("bin/python").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: root.appendingPathComponent("pyvenv.cfg").path, contents: Data("home = /usr/bin\n".utf8))
        let site = root.appendingPathComponent("lib/python3.13/site-packages")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        if torch { try FileManager.default.createDirectory(at: site.appendingPathComponent("torch"), withIntermediateDirectories: true) }
    }

    private func model(at url: URL, megabytes: Double = 40) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: Int(megabytes * 1_000_000)))
    }

    @Test func theAppsOwnEnvironmentAndModelAreFound() throws {
        let home = try home { home in
            try venv(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("venv"), torch: true)
            try model(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("v4_ru.pt"))
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let found = try SileroLocator.find(override: nil, home: home).get()
        #expect(found.python.path.contains("Application Support/Kuzmemo/silero/venv/bin/python") && found.source == "окружение Kuzmemo")
        #expect(found.model.path.hasSuffix("Application Support/Kuzmemo/silero/v4_ru.pt"))
    }

    @Test func nothingOutsideTheAppsFolderIsLookedAt() throws {
        // Environments and models lying elsewhere (another project's venv, the torch hub cache) are not used.
        let home = try home { home in
            try venv(at: home.appendingPathComponent("Projects/other/venv"), torch: true)
            try model(at: home.appendingPathComponent(".cache/torch/hub/snakers4_silero-models_master/src/silero/model/v4_ru.pt"))
        }
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(SileroLocator.find(override: nil, home: home) == .failure(.noPython))
    }

    @Test func anEnvironmentWithoutTorchIsNotUsed() throws {
        let home = try home { home in
            try venv(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("venv"), torch: false)
            try model(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("v4_ru.pt"))
        }
        defer { try? FileManager.default.removeItem(at: home) }
        guard case .failure(.noTorch) = SileroLocator.find(override: nil, home: home) else { Issue.record("expected noTorch"); return }
    }

    @Test func problemsAreNamed() throws {
        let empty = try home { _ in }
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(SileroLocator.find(override: nil, home: empty) == .failure(.noPython))

        let noModel = try home { try venv(at: SileroLocator.ownDirectory(home: $0).appendingPathComponent("venv"), torch: true) }
        defer { try? FileManager.default.removeItem(at: noModel) }
        guard case .failure(.noModel) = SileroLocator.find(override: nil, home: noModel) else { Issue.record("expected noModel"); return }

        #expect(SileroLocator.find(override: "/nowhere/python", home: empty) == .failure(.pythonMissing("/nowhere/python")))
        #expect(SileroLocator.Problem.noPython.message.contains("torch"))
    }

    @Test func aTruncatedModelFileDoesNotCount() throws {
        let home = try home { home in
            try venv(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("venv"), torch: true)
            try model(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("v4_ru.pt"), megabytes: 0.2)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        guard case .failure(.noModel) = SileroLocator.find(override: nil, home: home) else { Issue.record("expected noModel"); return }
    }

    @Test func aHandPickedInterpreterWins() throws {
        let home = try home { home in
            try venv(at: home.appendingPathComponent("mine"), torch: true)
            try model(at: SileroLocator.ownDirectory(home: home).appendingPathComponent("v4_ru.pt"))
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let found = try SileroLocator.find(override: home.appendingPathComponent("mine/bin/python").path, home: home).get()
        #expect(found.source == "указан вручную" && found.python.path.hasSuffix("mine/bin/python"))
    }
}

/// Against the real thing: the helper script, the person's Python with torch and the Silero model. Slow (torch alone
/// takes seconds to import), so it only runs on request: `KUZMEMO_LIVE_SILERO=1 swift test --filter LiveSilero`.
@Suite("LiveSilero", .enabled(if: ProcessInfo.processInfo.environment["KUZMEMO_LIVE_SILERO"] == "1"))
struct LiveSileroTests {
    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Silero/silero_helper.py")
    }

    /// Duration in seconds and the loudest sample (0...1) of a 16-bit mono WAV.
    private func measure(_ url: URL) throws -> (seconds: Double, peak: Double) {
        let data = try Data(contentsOf: url)
        let rate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
        let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return (Double(samples.count) / Double(rate), Double(samples.map { abs(Int($0)) }.max() ?? 0) / 32767)
    }

    @Test func theRealVoiceSpeaksAndNormalizedTextIsLonger() async throws {
        let installation = try SileroLocator.find(override: nil).get()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("silero-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = SileroHelper(
            launch: .init(python: installation.python, script: script, model: installation.model), outputDirectory: directory, idleSeconds: 0
        )
        let started = Date()
        try await helper.prepare()
        print("live: helper ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(installation.source))")
        let speakers = await helper.speakers
        #expect(Set(speakers).isSuperset(of: ["aidar", "baya", "kseniya", "xenia", "eugene"]), "\(speakers)")

        let phrase = try await helper.synthesize(text: "Сегодня у тебя три дела: планёрка, созвон и статистика.", speaker: "eugene")
        let plain = try measure(phrase.url)
        #expect(plain.seconds > 2.5 && plain.seconds < 12 && plain.peak > 0.2, "\(plain)")
        print("live: 6 s of speech took \(phrase.milliseconds) ms")

        // Silero skips digits and Latin letters, which is why the app spells them out first.
        let raw = "Встреча с Notion в 15:00, оплатить 340 долларов."
        let skipped = try await helper.synthesize(text: raw, speaker: "eugene")
        let spelled = try await helper.synthesize(text: SpeechText.forNeuralVoice(raw), speaker: "eugene")
        let rawSeconds = try measure(skipped.url).seconds, spelledSeconds = try measure(spelled.url).seconds
        print("live: raw \(rawSeconds) s, normalized \(spelledSeconds) s")
        #expect(spelledSeconds > rawSeconds + 1.5, "raw \(rawSeconds) s, normalized \(spelledSeconds) s")

        let slow = try await helper.synthesize(text: "Сегодня у тебя три дела: планёрка, созвон и статистика.", speaker: "eugene", rate: .slow)
        let fast = try await helper.synthesize(text: "Сегодня у тебя три дела: планёрка, созвон и статистика.", speaker: "eugene", rate: .fast)
        #expect(try measure(slow.url).seconds > measure(fast.url).seconds)

        do {
            _ = try await helper.synthesize(text: "Проверка", speaker: "no-such-speaker")
            Issue.record("an unknown speaker should fail")
        } catch let error as SileroError {
            guard case .failed = error else { Issue.record("wrong error \(error)"); return }
        }
        await helper.stop()
    }
}
