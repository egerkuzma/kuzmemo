import Foundation
import Synchronization
import Testing
@testable import KuzmemoCore

final class FakeTranscriber: Transcriber, Sendable {
    let modelName = "fake"
    private let reply: String
    private let calls = Mutex<[Int]>([])

    init(reply: String) { self.reply = reply }

    var callSizes: [Int] { calls.withLock { $0 } }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        calls.withLock { $0.append(samples.count) }
        return TranscriptionOutput(text: reply, language: "ru", audioSeconds: Double(samples.count) / 16000, processingSeconds: 0.1, model: modelName)
    }
}

private func tone(_ seconds: Double) -> [Float] {
    (0 ..< Int(seconds * 16000)).map { i in
        let t = Double(i) / 16000
        return Float(sin(2 * .pi * 180 * t) * 0.25 * (0.55 + 0.45 * sin(2 * .pi * 4 * t)))
    }
}

@Suite("Recognizer")
struct RecognizerTests {
    @Test func silenceNeverReachesTheEngine() async throws {
        let engine = FakeTranscriber(reply: "Продолжение следует...")
        let result = try await Recognizer(transcriber: engine).recognize([Float](repeating: 0, count: 48000))
        #expect(result == .noSpeech(reason: "no speech in the recording"))
        #expect(engine.callSizes.isEmpty)
    }

    @Test func speechIsTrimmedTranscribedAndCleaned() async throws {
        let engine = FakeTranscriber(reply: " Позвонить маме [Музыка]")
        let audio = [Float](repeating: 0, count: 32000) + tone(1.5) + [Float](repeating: 0, count: 32000)
        let result = try await Recognizer(transcriber: engine).recognize(audio)
        guard case let .speech(output) = result else { Issue.record("expected speech: \(result)"); return }
        #expect(output.text == "Позвонить маме")
        #expect(engine.callSizes.count == 1 && engine.callSizes[0] < audio.count) // silence was trimmed away
    }

    @Test func aHallucinatedAnswerIsDropped() async throws {
        let engine = FakeTranscriber(reply: "Субтитры сделал DimaTorzok")
        let result = try await Recognizer(transcriber: engine).recognize(tone(2))
        guard case let .noSpeech(reason) = result else { Issue.record("expected noSpeech"); return }
        #expect(reason.contains("DimaTorzok"))
    }
}
