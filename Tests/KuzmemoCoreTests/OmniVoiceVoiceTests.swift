import Foundation
import Testing
@testable import KuzmemoCore

/// A folder laid out like an installation of the "My voice" engine, with stand-in programs.
private struct FakeInstall {
    let root: URL
    let locator: OmniVoiceLocator

    /// Stand-in for `omnivoice-tts`: notes its process id, then answers each line with a header and some samples.
    static let speaker = #"""
    #!/usr/bin/env python3
    import os, struct, sys
    here = os.path.dirname(os.path.abspath(__file__))
    open(os.path.join(here, "pid.txt"), "w").write(str(os.getpid()))
    def header():
        return b"RIFF" + struct.pack("<I", 0x7FFFFFFF) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 24000, 48000, 2, 16) + b"data" + struct.pack("<I", 0x7FFFFFFF)
    for line in sys.stdin.buffer:
        line = line.strip()
        sys.stdout.buffer.write(header() + bytes([len(line) % 200 + 1]) * (len(line) * 400))
        sys.stdout.buffer.flush()
    """#

    /// Stand-in for `omnivoice-codec -i ref.wav`: writes `ref.rvq` next to the input and notes its arguments.
    static let encoder = #"""
    #!/usr/bin/env python3
    import os, sys
    args = sys.argv[1:]
    src = args[args.index("-i") + 1]
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "codec-args.txt"), "w").write("\n".join(args))
    open(os.path.splitext(src)[0] + ".rvq", "wb").write(b"codes:" + open(src, "rb").read()[44:60])
    """#
    static let encoderThatFails = "#!/bin/sh\nexit 4\n"
    static let encoderThatWritesNothing = "#!/bin/sh\nexit 0\n"
    static let encoderThatHangs = "#!/bin/sh\nexec sleep 60\n"
    /// A program that only notes its process id (a shell starts far quicker than Python) and waits for text.
    static let idler = "#!/bin/sh\necho $$ > \"$(dirname \"$0\")/pid.txt\"\nexec cat > /dev/null\n"

    init(encoder: String? = FakeInstall.encoder, voice: Bool = false, speaker: String = FakeInstall.speaker) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omnivoice-voice-test-\(UUID().uuidString)")
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try files.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        locator = OmniVoiceLocator(directory: root, voiceDirectory: root.appendingPathComponent("elsewhere/voice"))
        try speaker.write(to: locator.synthesizer, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locator.synthesizer.path)
        if let encoder {
            try encoder.write(to: locator.encoder, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locator.encoder.path)
        }
        try Data().write(to: locator.languageModel)
        try Data().write(to: locator.codecModel)
        if voice {
            try files.createDirectory(at: locator.voiceDirectory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: locator.referenceCodes)
            try "слова образца".write(to: locator.referenceText, atomically: true, encoding: .utf8)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Swaps the stand-in encoder for another (a rewritten file needs its permission again).
    func useEncoder(_ script: String) throws {
        try script.write(to: locator.encoder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locator.encoder.path)
    }

    /// A mono 16-bit recording of silence with a true header.
    func recording(seconds: Double, rate: Int = 24000, named name: String = "sample.wav") throws -> URL {
        let url = root.appendingPathComponent(name)
        try SpokenSegment(sampleRate: rate, pcm: Data(count: Int(seconds * Double(rate)) * 2)).wav.write(to: url)
        return url
    }
}

@Suite("Lines for the My voice engine")
struct OmniVoiceTextTests {
    @Test func aSentenceIsALineAndShortOnesShareOne() {
        let long = ["Сегодня у тебя три дела: в десять часов, Планёрка.", "В тринадцать часов у тебя обед с Анной на Тверской.", "В восемнадцать часов тебя ждёт тренировка в зале."]
        #expect(OmniVoiceText.lines(for: long.joined(separator: " ")) == long)
        #expect(OmniVoiceText.lines(for: "Готово. Записал.") == ["Готово. Записал."]) // two short ones would each pay the fixed cost
        #expect(OmniVoiceText.lines(for: "Готово.") == ["Готово."])
    }

    @Test func aFirstShortSentenceJoinsTheNextOnlyWhileTheLineStaysShort() {
        let text = "Понял. Сегодня у тебя три дела: в десять часов, Планёрка, в час обед и в шесть вечера тренировка."
        let lines = OmniVoiceText.lines(for: text)
        #expect(lines.count == 2 && lines[0] == "Понял.")
    }

    @Test func numbersAndTimesAreSpelledOutFirst() {
        let lines = OmniVoiceText.lines(for: "Созвон в 10:00.")
        #expect(lines == ["Созвон в десять часов."])
    }

    @Test func aVeryLongSentenceIsCutAtItsCommas() {
        let clause = "потом нужно позвонить в банк и уточнить детали по договору"
        let sentence = Array(repeating: clause, count: 6).joined(separator: ", ") + "."
        #expect(sentence.count > OmniVoiceText.cutAbove * 2)
        let lines = OmniVoiceText.lines(for: sentence)
        #expect(lines.count >= 3)
        #expect(lines.allSatisfy { $0.count <= OmniVoiceText.cutAbove })
        #expect(lines.joined(separator: " ").split(separator: " ").count == sentence.split(separator: " ").count) // no word lost
    }

    @Test func aVeryLongSentenceWithoutCommasIsCutAtSpaces() {
        let sentence = Array(repeating: "слово", count: 80).joined(separator: " ") + "."
        let lines = OmniVoiceText.lines(for: sentence)
        #expect(lines.count >= 3 && lines.allSatisfy { $0.count <= OmniVoiceText.cutAbove })
    }

    @Test func nothingToSayGivesNoLines() {
        #expect(OmniVoiceText.lines(for: "").isEmpty)
        #expect(OmniVoiceText.lines(for: "  🙂 ** \n").isEmpty)
    }

    @Test func lineBreaksSeparateSentences() {
        let a = "Первая строка ответа достаточно длинная для отдельной строки."
        let b = "Вторая строка ответа тоже достаточно длинная."
        #expect(OmniVoiceText.lines(for: a + "\n" + b) == [a, b])
    }
}

@Suite("Lines of speech kept on disk")
struct OmniVoiceCacheTests {
    private func makeCache(maxBytes: Int = 1 << 20) -> (OmniVoiceCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omnivoice-cache-\(UUID().uuidString)")
        return (OmniVoiceCache(directory: directory, maxBytes: maxBytes), directory)
    }

    private let voice = OmniVoiceCache.Voice(fingerprint: "abc", steps: 16, language: "Russian")
    private func segment(_ seconds: Double = 1, fill: UInt8 = 7) -> SpokenSegment {
        SpokenSegment(sampleRate: 24000, pcm: Data(repeating: fill, count: Int(seconds * 24000) * 2))
    }

    @Test func aStoredLineComesBackExactly() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(cache.segment(for: "Готово.", voice: voice) == nil)
        cache.store(segment(fill: 9), for: "Готово.", voice: voice)
        #expect(cache.segment(for: "Готово.", voice: voice) == segment(fill: 9))
    }

    @Test func aLineIsOnlyFoundForTheSameWordsSampleStepsAndLanguage() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.store(segment(), for: "Готово.", voice: voice)
        #expect(cache.segment(for: "Готово!", voice: voice) == nil)
        #expect(cache.segment(for: "Готово.", voice: .init(fingerprint: "abd", steps: 16, language: "Russian")) == nil)
        #expect(cache.segment(for: "Готово.", voice: .init(fingerprint: "abc", steps: 12, language: "Russian")) == nil)
        #expect(cache.segment(for: "Готово.", voice: .init(fingerprint: "abc", steps: 16, language: "English")) == nil)
        #expect(cache.segment(for: "Готово.", voice: voice) != nil)
    }

    @Test func aDamagedOrTinyFileIsNotAnAnswerAndIsRemoved() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.store(segment(), for: "Готово.", voice: voice)
        let file = cache.file(for: "Готово.", voice: voice)
        try Data("not a wav".utf8).write(to: file)
        #expect(cache.segment(for: "Готово.", voice: voice) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        cache.store(segment(0.05), for: "Ой.", voice: voice) // too short to be speech: not kept
        #expect(cache.segment(for: "Ой.", voice: voice) == nil)
    }

    @Test func theOldestLinesGoFirstWhenTheFolderIsTooBig() throws {
        let (cache, directory) = makeCache(maxBytes: 250_000) // a second of speech is 48 KB
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines: [String] = []
        for index in 0 ..< 8 {
            let line = "строка \(index)"
            lines.append(line)
            cache.store(segment(fill: UInt8(index + 1)), for: line, voice: voice)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))], ofItemAtPath: cache.file(for: line, voice: voice).path)
        }
        // "строка 0" is played again, so it is the newest now
        _ = cache.segment(for: lines[0], voice: voice)
        cache.prune()
        let kept = lines.filter { FileManager.default.fileExists(atPath: cache.file(for: $0, voice: voice).path) }
        #expect(kept.contains(lines[0]) && kept.contains(lines[7]))
        #expect(!kept.contains(lines[1]) && !kept.contains(lines[2]))
        let total = try FileManager.default.contentsOfDirectory(atPath: directory.path).reduce(0) {
            $0 + ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($1).path)[.size] as? Int) ?? 0)
        }
        #expect(total <= 250_000)
    }

    @Test func clearingForgetsEverything() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.store(segment(), for: "Готово.", voice: voice)
        cache.clear()
        #expect(cache.segment(for: "Готово.", voice: voice) == nil)
    }

    @Test func theFingerprintFollowsTheSample() throws {
        let install = try FakeInstall(voice: true)
        defer { install.remove() }
        let first = try #require(OmniVoiceCache.fingerprint(of: install.locator))
        #expect(first == OmniVoiceCache.fingerprint(of: install.locator))
        try Data([1, 2, 4]).write(to: install.locator.referenceCodes)
        let second = try #require(OmniVoiceCache.fingerprint(of: install.locator))
        #expect(second != first)
        try "другие слова".write(to: install.locator.referenceText, atomically: true, encoding: .utf8)
        #expect(OmniVoiceCache.fingerprint(of: install.locator) != second)
        try FileManager.default.removeItem(at: install.locator.voiceDirectory)
        #expect(OmniVoiceCache.fingerprint(of: install.locator) == nil)
    }
}

@Suite("WAV headers")
struct WAVInfoTests {
    @Test func aFileWrittenHereIsReadBack() throws {
        let segment = SpokenSegment(sampleRate: 24000, pcm: Data(count: 24000 * 2 * 3))
        let info = try WAVInfo(data: segment.wav)
        #expect(info.channels == 1 && info.sampleRate == 24000 && info.bitsPerSample == 16 && info.dataOffset == 44)
        #expect(abs(info.seconds - 3) < 0.001)
        #expect(SpokenSegment(wav: segment.wav) == segment)
    }

    @Test func aStreamedHeaderWithUnknownLengthTakesTheLengthFromTheFile() throws {
        var wav = SpokenSegment(sampleRate: 24000, pcm: Data(count: 24000 * 2)).wav
        for offset in [4, 40] { wav.replaceSubrange(offset ..< offset + 4, with: [0xFF, 0xFF, 0xFF, 0x7F]) }
        let info = try WAVInfo(data: wav)
        #expect(info.dataBytes == 48000 && abs(info.seconds - 1) < 0.001)
    }

    @Test func extraChunksBeforeTheSamplesAreSkipped() throws {
        let plain = SpokenSegment(sampleRate: 16000, pcm: Data(count: 32000)).wav
        var wav = plain.prefix(36)
        wav.append(contentsOf: Array("LIST".utf8) + [3, 0, 0, 0] + [65, 66, 67, 0]) // an odd-sized chunk plus its pad byte
        wav.append(plain.suffix(from: 36))
        let info = try WAVInfo(data: wav)
        #expect(info.dataOffset == 36 + 12 + 8 && info.sampleRate == 16000 && abs(info.seconds - 1) < 0.001)
    }

    @Test func anythingElseIsNotAWAVFile() {
        #expect(throws: WAVInfo.Problem.notAWAVFile) { try WAVInfo(data: Data("hello".utf8)) }
        #expect(throws: WAVInfo.Problem.notAWAVFile) { try WAVInfo(data: Data(repeating: 0, count: 100)) }
        var float = SpokenSegment(sampleRate: 24000, pcm: Data(count: 480)).wav
        float[20] = 3 // IEEE float, not PCM
        #expect(throws: WAVInfo.Problem.notAWAVFile) { try WAVInfo(data: float) }
        #expect(SpokenSegment(wav: Data("hello".utf8)) == nil)
    }
}

@Suite("Putting the voice in place")
struct OmniVoiceEnrollmentTests {
    @Test func aRecordingAndItsWordsBecomeAVoice() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        #expect(install.locator.status == .noVoice)
        let sample = try install.recording(seconds: 9)
        try await OmniVoiceEnrollment(locator: install.locator).enroll(recording: sample, transcript: "  Причина первой\nстроки лога.  ")
        #expect(install.locator.status == .ready)
        #expect(try String(contentsOf: install.locator.referenceText, encoding: .utf8) == "Причина первой строки лога.")
        #expect(FileManager.default.fileExists(atPath: install.locator.referenceRecording.path))
        #expect(try Data(contentsOf: install.locator.referenceCodes).starts(with: Data("codes:".utf8)))
        let arguments = try String(contentsOf: install.root.appendingPathComponent("build/codec-args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.first == "--model" && arguments[1] == install.locator.codecModel.path && arguments.contains("-i"))
        // nothing is left next to the voice folder
        let siblings = try FileManager.default.contentsOfDirectory(atPath: install.locator.voiceDirectory.deletingLastPathComponent().path)
        #expect(siblings == ["voice"])
    }

    @Test func aNewVoiceReplacesTheOldOneOnlyWhenItIsComplete() async throws {
        let install = try FakeInstall(voice: true)
        defer { install.remove() }
        let before = try Data(contentsOf: install.locator.referenceCodes)
        // an encoder that fails: the old voice stays
        try install.useEncoder(FakeInstall.encoderThatFails)
        await #expect(throws: OmniVoiceError.encoderFailed(status: 4)) {
            try await OmniVoiceEnrollment(locator: install.locator).enroll(recording: try install.recording(seconds: 8), transcript: "новые слова образца")
        }
        #expect(try Data(contentsOf: install.locator.referenceCodes) == before)
        #expect(try String(contentsOf: install.locator.referenceText, encoding: .utf8) == "слова образца")
        #expect(try FileManager.default.contentsOfDirectory(atPath: install.locator.voiceDirectory.deletingLastPathComponent().path) == ["voice"])
        // an encoder that writes nothing
        try install.useEncoder(FakeInstall.encoderThatWritesNothing)
        await #expect(throws: OmniVoiceError.encoderWroteNothing) {
            try await OmniVoiceEnrollment(locator: install.locator).enroll(recording: try install.recording(seconds: 8), transcript: "новые слова образца")
        }
        #expect(try Data(contentsOf: install.locator.referenceCodes) == before)
        // a working encoder: replaced
        try install.useEncoder(FakeInstall.encoder)
        try await OmniVoiceEnrollment(locator: install.locator).enroll(recording: try install.recording(seconds: 8), transcript: "новые слова образца")
        #expect(try String(contentsOf: install.locator.referenceText, encoding: .utf8) == "новые слова образца")
        #expect(try Data(contentsOf: install.locator.referenceCodes) != before)
    }

    @Test func aRecordingThatCannotBeAVoiceIsRefusedBeforeAnythingRuns() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        let enrollment = OmniVoiceEnrollment(locator: install.locator)
        await #expect(throws: OmniVoiceError.self) { try await enrollment.enroll(recording: try install.recording(seconds: 1), transcript: "слишком коротко") }
        do {
            try await enrollment.enroll(recording: try install.recording(seconds: 40), transcript: "слишком длинно")
            Issue.record("a 40 s recording must be refused")
        } catch let OmniVoiceError.sampleLength(seconds) {
            #expect(abs(seconds - 40) < 0.01)
        }
        await #expect(throws: OmniVoiceError.sampleWithoutWords) { try await enrollment.enroll(recording: try install.recording(seconds: 8), transcript: "   ") }
        await #expect(throws: OmniVoiceError.sampleWithoutWords) { try await enrollment.enroll(recording: try install.recording(seconds: 8), transcript: "слово") } // one word is not a sample
        let notAudio = install.root.appendingPathComponent("notes.wav")
        try Data("plain text".utf8).write(to: notAudio)
        await #expect(throws: OmniVoiceError.sampleUnreadable) { try await enrollment.enroll(recording: notAudio, transcript: "два слова") }
        #expect(!FileManager.default.fileExists(atPath: install.root.appendingPathComponent("build/codec-args.txt").path), "the encoder must not run for these")
        #expect(install.locator.status == .noVoice)
    }

    @Test func withoutTheProgramThereIsNothingToEnrollInto() async throws {
        let install = try FakeInstall()
        defer { install.remove() }
        try FileManager.default.removeItem(at: install.locator.languageModel)
        await #expect(throws: OmniVoiceError.notReady(.notInstalled)) {
            try await OmniVoiceEnrollment(locator: install.locator).enroll(recording: try install.recording(seconds: 8), transcript: "два слова")
        }
    }

    @Test func anEncoderThatHangsIsStopped() async throws {
        let install = try FakeInstall(encoder: FakeInstall.encoderThatHangs)
        defer { install.remove() }
        let started = Date()
        await #expect(throws: OmniVoiceError.timedOut) {
            try await OmniVoiceEnrollment(locator: install.locator, timeout: 0.5).enroll(recording: try install.recording(seconds: 8), transcript: "два слова")
        }
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(install.locator.status == .noVoice)
    }

    @Test func forgettingTheVoiceRemovesItsFiles() async throws {
        let install = try FakeInstall(voice: true)
        defer { install.remove() }
        try OmniVoiceEnrollment(locator: install.locator).remove()
        #expect(install.locator.status == .noVoice)
        #expect(!FileManager.default.fileExists(atPath: install.locator.voiceDirectory.path))
        try OmniVoiceEnrollment(locator: install.locator).remove() // nothing left: not an error
    }

    @Test func theVoiceLivesInItsOwnFolderApartFromTheProgram() throws {
        let install = try FakeInstall(voice: true)
        defer { install.remove() }
        #expect(install.locator.referenceCodes.path.hasPrefix(install.root.appendingPathComponent("elsewhere/voice").path))
        #expect(OmniVoiceLocator(directory: install.root).voiceDirectory.path == install.root.appendingPathComponent("voice").path)
    }
}

@Suite("A program started ahead of the text")
struct OmniVoiceSessionTests {
    private func collect(_ stream: AsyncThrowingStream<SpokenSegment, any Error>) async throws -> [SpokenSegment] {
        var segments: [SpokenSegment] = []
        for try await segment in stream { segments.append(segment) }
        return segments
    }

    private func pid(_ install: FakeInstall) async throws -> Int32 {
        for _ in 0 ..< 120 { // the stand-in writes its id a moment after it starts
            if let text = try? String(contentsOf: install.root.appendingPathComponent("build/pid.txt"), encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw OmniVoiceError.launchFailed("no pid")
    }

    private func isGone(_ pid: Int32, within seconds: Double = 6) async throws -> Bool {
        var alive = true
        for _ in 0 ..< Int(seconds * 10) where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        return !alive
    }

    @Test func theTextCanArriveAfterTheProgramHasStarted() async throws {
        let install = try FakeInstall(voice: true)
        defer { install.remove() }
        let session = try OmniVoiceRunner(locator: install.locator).begin()
        #expect(session.isUsable)
        _ = try await pid(install) // it is up, and nobody has said anything yet
        try await Task.sleep(for: .milliseconds(300))
        let segments = try await collect(session.speak(["Раз.", "Два три."]))
        #expect(segments.count == 2)
        #expect(!session.isUsable)
    }

    @Test func aSessionThatIsNeverUsedStopsItself() async throws {
        let install = try FakeInstall(voice: true, speaker: FakeInstall.idler)
        defer { install.remove() }
        let session = try OmniVoiceRunner(locator: install.locator).begin(idleLimit: 3.0) // long enough for a busy machine to start the stand-in
        let program = try await pid(install)
        #expect(try await isGone(program), "the program was still running four seconds after its idle limit")
        #expect(!session.isUsable)
        await #expect(throws: OmniVoiceError.expired) { try await collect(session.speak(["Поздно."])) }
    }

    @Test func aSessionSpeaksOnce() async throws {
        let install = try FakeInstall(voice: true)
        defer { install.remove() }
        let session = try OmniVoiceRunner(locator: install.locator).begin()
        _ = try await collect(session.speak(["Раз."]))
        await #expect(throws: OmniVoiceError.expired) { try await collect(session.speak(["Ещё."])) }
    }

    @Test func givingUpStopsTheProgram() async throws {
        let install = try FakeInstall(voice: true, speaker: FakeInstall.idler)
        defer { install.remove() }
        let session = try OmniVoiceRunner(locator: install.locator).begin()
        let program = try await pid(install)
        session.cancel()
        #expect(try await isGone(program))
        #expect(!session.isUsable)
    }

    @Test func sayingNothingEndsTheProgram() async throws {
        let install = try FakeInstall(voice: true, speaker: FakeInstall.idler)
        defer { install.remove() }
        let session = try OmniVoiceRunner(locator: install.locator).begin()
        let program = try await pid(install)
        #expect(try await collect(session.speak(["  ", ""])).isEmpty)
        #expect(try await isGone(program))
    }

    @Test func aMissingVoiceCannotBeginAtAll() throws {
        let install = try FakeInstall(voice: false)
        defer { install.remove() }
        #expect(throws: OmniVoiceError.notReady(.noVoice)) { try OmniVoiceRunner(locator: install.locator).begin() }
    }
}
