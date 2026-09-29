import Foundation
import Testing
@testable import KuzmemoCore

@Suite("The My voice engine")
struct OmniVoiceRunnerTests {
    /// A stand-in for `omnivoice-tts`: notes how it was started, then answers each line with a header that says "length
    /// unknown" and samples whose count depends on the line, pausing `delay` seconds after each.
    private static func speaking(delay: Double = 0) -> String {
        #"""
        #!/usr/bin/env python3
        import os, struct, sys, time
        here = os.path.dirname(os.path.abspath(__file__))
        open(os.path.join(here, "args.txt"), "w").write("\n".join(sys.argv[1:]))
        open(os.path.join(here, "pid.txt"), "w").write(str(os.getpid()))
        def header():
            return b"RIFF" + struct.pack("<I", 0x7FFFFFFF) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16) + b"data" + struct.pack("<I", 0x7FFFFFFF)
        for index, line in enumerate(sys.stdin.buffer):
            line = line.strip()
            sys.stdout.buffer.write(header())  # like the real program: a line's header is written when the line is started
            sys.stdout.buffer.flush()
            if index > 0:
                time.sleep(\#(delay))  # the first line is quick, the later ones take their time
            sys.stdout.buffer.write(bytes([len(line) % 200 + 1]) * (len(line) * 200))
            sys.stdout.buffer.flush()
        """#
    }

    private static let failing = "#!/bin/sh\ncat > /dev/null\nexit 3\n"
    private static let silent = "#!/bin/sh\ncat > /dev/null\nexit 0\n"
    private static let hanging = "#!/bin/sh\nexec sleep 60\n"

    /// A folder laid out like an installation, with `script` as the program.
    private func install(_ script: String?, voice: Bool = true) throws -> (locator: OmniVoiceLocator, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omnivoice-test-\(UUID().uuidString)")
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appendingPathComponent("voice"), withIntermediateDirectories: true)
        let locator = OmniVoiceLocator(directory: root)
        if let script {
            try script.write(to: locator.synthesizer, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locator.synthesizer.path)
            try Data().write(to: locator.languageModel)
            try Data().write(to: locator.codecModel)
        }
        if voice {
            try Data([1, 2, 3]).write(to: locator.referenceCodes)
            try "слова образца".write(to: locator.referenceText, atomically: true, encoding: .utf8)
        }
        return (locator, root)
    }

    private func collect(_ stream: AsyncThrowingStream<SpokenSegment, any Error>) async throws -> [SpokenSegment] {
        var segments: [SpokenSegment] = []
        for try await segment in stream { segments.append(segment) }
        return segments
    }

    @Test func eachSentenceBecomesItsOwnSegmentInOrder() async throws {
        let (locator, root) = try install(Self.speaking())
        defer { try? FileManager.default.removeItem(at: root) }
        let sentences = ["Раз.", "Два три.", "   ", "Четыре пять шесть."] // the blank one is left out
        let segments = try await collect(OmniVoiceRunner(locator: locator).speak(sentences))
        #expect(segments.map(\.pcm.count) == ["Раз.", "Два три.", "Четыре пять шесть."].map { Array($0.utf8).count * 200 })
        #expect(segments.allSatisfy { $0.sampleRate == 24000 })
    }

    @Test func theProgramIsStartedWithTheVoiceTheStepsAndTheLineMode() async throws {
        let (locator, root) = try install(Self.speaking())
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await collect(OmniVoiceRunner(locator: locator, steps: 12).speak(["Проверка."]))
        let arguments = try String(contentsOf: root.appendingPathComponent("build/args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        #expect(value(after: "--model") == locator.languageModel.path && value(after: "--codec") == locator.codecModel.path)
        #expect(value(after: "--ref-rvq") == locator.referenceCodes.path && value(after: "--ref-text") == locator.referenceText.path)
        #expect(value(after: "--steps") == "12" && value(after: "--lang") == "Russian" && value(after: "-o") == "-")
        #expect(arguments.contains("--stream-by-line"))
    }

    @Test func withoutTheProgramOrTheVoiceItSaysSo() async throws {
        let (bare, bareRoot) = try install(nil, voice: false)
        defer { try? FileManager.default.removeItem(at: bareRoot) }
        #expect(bare.status == .notInstalled)
        await #expect(throws: OmniVoiceError.notReady(.notInstalled)) { try await collect(OmniVoiceRunner(locator: bare).speak(["Привет."])) }

        let (noVoice, noVoiceRoot) = try install(Self.speaking(), voice: false)
        defer { try? FileManager.default.removeItem(at: noVoiceRoot) }
        #expect(noVoice.status == .noVoice)
        await #expect(throws: OmniVoiceError.notReady(.noVoice)) { try await collect(OmniVoiceRunner(locator: noVoice).speak(["Привет."])) }

        let (ready, readyRoot) = try install(Self.speaking())
        defer { try? FileManager.default.removeItem(at: readyRoot) }
        #expect(ready.status == .ready)
    }

    @Test func aProgramThatFailsOrSaysNothingIsAnError() async throws {
        let (failing, failingRoot) = try install(Self.failing)
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        await #expect(throws: OmniVoiceError.failed(status: 3)) { try await collect(OmniVoiceRunner(locator: failing).speak(["Привет."])) }

        let (silent, silentRoot) = try install(Self.silent)
        defer { try? FileManager.default.removeItem(at: silentRoot) }
        await #expect(throws: OmniVoiceError.producedNoAudio) { try await collect(OmniVoiceRunner(locator: silent).speak(["Привет."])) }
    }

    @Test func nothingToSayStartsNothing() async throws {
        let (locator, root) = try install(Self.speaking())
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await collect(OmniVoiceRunner(locator: locator).speak([])).isEmpty)
        #expect(try await collect(OmniVoiceRunner(locator: locator).speak(["  ", "\n"])).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("build/pid.txt").path)) // it never ran
    }

    @Test func aProgramThatHangsIsStoppedAtTheTimeout() async throws {
        let (locator, root) = try install(Self.hanging)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        await #expect(throws: OmniVoiceError.timedOut) { try await collect(OmniVoiceRunner(locator: locator, timeout: 0.6).speak(["Привет."])) }
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func stoppingTheListenerStopsTheProgram() async throws {
        let (locator, root) = try install(Self.speaking(delay: 60))
        defer { try? FileManager.default.removeItem(at: root) }
        var first: SpokenSegment?
        let started = Date()
        for try await segment in OmniVoiceRunner(locator: locator).speak(["Первое.", "Второе."]) {
            first = segment
            break // the answer was interrupted (the person pressed the key)
        }
        #expect(first != nil)
        let pid = try #require(Int32(String(contentsOf: root.appendingPathComponent("build/pid.txt"), encoding: .utf8)))
        var alive = true
        for _ in 0 ..< 40 where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!alive, "the program was still running four seconds after the listener stopped")
        #expect(Date().timeIntervalSince(started) < 20) // it did not just wait for the program to finish on its own
    }
}

/// Runs the real program from `scripts/install_omnivoice.sh` with a voice folder holding `ref.rvq` and `ref.txt`:
///
///     KUZMEMO_LIVE_OMNIVOICE=1 KUZMEMO_OMNIVOICE_VOICE=/path/to/voice swift test --filter LiveOmniVoice
///
/// Add `KUZMEMO_OMNIVOICE_OUT=/some/folder` to keep the segments as WAV files. Nothing is played.
@Suite("Live: the My voice engine", .enabled(if: ProcessInfo.processInfo.environment["KUZMEMO_LIVE_OMNIVOICE"] == "1"))
struct LiveOmniVoice {
    @Test func speaksAnAnswerSentenceBySentence() async throws {
        let environment = ProcessInfo.processInfo.environment
        let installed = OmniVoiceLocator.standard
        let voice = URL(fileURLWithPath: try #require(environment["KUZMEMO_OMNIVOICE_VOICE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omnivoice-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: root.appendingPathComponent("build"), withDestinationURL: installed.directory.appendingPathComponent("build"))
        try files.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: installed.directory.appendingPathComponent("models"))
        try files.createDirectory(at: root.appendingPathComponent("voice"), withIntermediateDirectories: true)
        let locator = OmniVoiceLocator(directory: root)
        try files.copyItem(at: voice.appendingPathComponent("ref.rvq"), to: locator.referenceCodes)
        try files.copyItem(at: voice.appendingPathComponent("ref.txt"), to: locator.referenceText)
        #expect(locator.status == .ready)

        let sentences = ["Сегодня у вас три дела.", "В десять ноль-ноль созвон с командой.", "В час дня обед с Анной, в шесть вечера тренировка."]
        let started = Date()
        var arrivals: [Double] = [], seconds: [Double] = []
        var index = 0
        for try await segment in OmniVoiceRunner(locator: locator, steps: 16).speak(sentences) {
            arrivals.append(Date().timeIntervalSince(started))
            seconds.append(segment.seconds)
            if let out = environment["KUZMEMO_OMNIVOICE_OUT"] {
                try files.createDirectory(atPath: out, withIntermediateDirectories: true)
                try segment.wav.write(to: URL(fileURLWithPath: out).appendingPathComponent("live_\(index).wav"))
            }
            index += 1
        }
        print("LIVE arrivals \(arrivals.map { String(format: "%.2f", $0) }) audio seconds \(seconds.map { String(format: "%.2f", $0) })")
        #expect(seconds.count == 3)
        #expect(seconds.allSatisfy { $0 > 0.5 && $0 < 12 })
        #expect(arrivals[0] < 8, "the first sentence took \(arrivals[0]) s")
        // every sentence is ready before the earlier ones have finished playing: the answer can be spoken without gaps
        #expect(arrivals[1] < arrivals[0] + seconds[0] + 2 && arrivals[2] < arrivals[1] + seconds[1] + 2)
    }
}
