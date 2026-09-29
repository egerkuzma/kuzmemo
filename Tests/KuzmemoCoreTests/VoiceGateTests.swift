import Foundation
import Testing
@testable import KuzmemoCore

/// Deterministic pseudo-noise so tests are repeatable.
private struct Noise {
    var state: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1 // -1...1
    }
}

private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16000)) }

private func noise(_ seconds: Double, amplitude: Float) -> [Float] {
    var generator = Noise()
    return (0 ..< Int(seconds * 16000)).map { _ in generator.next() * amplitude }
}

/// A crude stand-in for speech: a 180 Hz tone with a syllable-like envelope on top of light noise.
private func speechLike(_ seconds: Double, amplitude: Float = 0.25) -> [Float] {
    var generator = Noise()
    return (0 ..< Int(seconds * 16000)).map { i in
        let t = Double(i) / 16000
        let envelope = Float(0.55 + 0.45 * sin(2 * .pi * 4 * t))
        return Float(sin(2 * .pi * 180 * t)) * amplitude * envelope + generator.next() * 0.003
    }
}

@Suite("EnergyGate")
struct EnergyGateTests {
    @Test func digitalSilenceAndQuietNoiseAreRejected() {
        let gate = EnergyGate()
        #expect(!gate.analyze(silence(3)).hasSpeech)
        #expect(!gate.analyze(noise(5, amplitude: 0.02)).hasSpeech)     // steady room noise
        #expect(!gate.analyze(noise(5, amplitude: 0.002)).hasSpeech)
        #expect(gate.trimmed(silence(3)) == nil)
        #expect(!gate.analyze([]).hasSpeech)
    }

    @Test func speechOverBackgroundNoiseIsAccepted() {
        let gate = EnergyGate()
        let recording = noise(1, amplitude: 0.01) + speechLike(2.0) + noise(1, amplitude: 0.01)
        let analysis = gate.analyze(recording)
        #expect(analysis.hasSpeech)
        #expect(analysis.speechSeconds > 1.0 && analysis.totalSeconds == 4)
        #expect(analysis.leadingSilence > 0.8 && analysis.trailingSilence > 0.8)
    }

    @Test func aVeryShortBlipIsNotSpeech() {
        let gate = EnergyGate()
        let blip = silence(1) + speechLike(0.2) + silence(1)
        #expect(!gate.analyze(blip).hasSpeech)
    }

    @Test func trimmingKeepsPaddingAroundTheSpeech() throws {
        let gate = EnergyGate()
        let recording = silence(2) + speechLike(1.5) + silence(2)
        let trimmed = try #require(gate.trimmed(recording))
        let seconds = Double(trimmed.count) / 16000
        #expect(seconds > 1.9 && seconds < 2.3, "trimmed to \(seconds)s") // 1.5 s speech + 2 × 0.25 s padding
    }

    @Test func shortRecordingsWithoutSilenceAreKeptWhole() throws {
        let gate = EnergyGate()
        let recording = speechLike(1.0)
        let trimmed = try #require(gate.trimmed(recording))
        #expect(abs(trimmed.count - recording.count) < 400)
    }

    @Test func aLoudRoomIsNotMistakenForSpeechButSpeechInItIs() {
        let gate = EnergyGate()
        let loudRoom = noise(4, amplitude: 0.08)
        #expect(!gate.analyze(loudRoom).hasSpeech)
        let speechInLoudRoom = noise(1, amplitude: 0.08) + speechLike(2, amplitude: 0.7) + noise(1, amplitude: 0.08)
        #expect(gate.analyze(speechInLoudRoom).hasSpeech)
    }
}

@Suite("HallucinationFilter")
struct HallucinationFilterTests {
    @Test(arguments: [
        "Продолжение следует...", "продолжение следует", "  Спасибо за просмотр!  ", "Thank you.", "you", "Thanks for watching!",
        "Субтитры сделал DimaTorzok", "Редактор субтитров А.Семкин Корректор А.Егорова", "[Музыка]", "(аплодисменты)",
        "*смех*", "Музыка", "а а а а а а", "...", "", "  ", "я",
    ])
    func dropsKnownInventions(text: String) {
        #expect(HallucinationFilter.clean(text) == nil, "text '\(text)'")
    }

    @Test(arguments: [
        "Напомни мне послезавтра сказать Дмитрию про доступ в Notion",
        "Напомни сказать спасибо Дмитрию",
        "Завтра в одиннадцать созвон с Acme",
        "Скажи что на сегодня",
        "Позвонить маме",
        "Что у меня завтра?",
    ])
    func keepsRealCommands(text: String) {
        #expect(HallucinationFilter.clean(text) == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func removesSoundTagsButKeepsTheRealText() {
        #expect(HallucinationFilter.clean("[Музыка] Позвонить маме (смех)") == "Позвонить маме")
        #expect(HallucinationFilter.clean("Позвонить   маме\nзавтра") == "Позвонить маме завтра")
    }
}

/// Reads a 16-bit PCM mono WAV (as written by scripts/fixtures/make_synth.sh) into floats.
func readWAV(_ url: URL) -> [Float]? {
    guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
    // find the "data" chunk
    var offset = 12
    while offset + 8 < data.count {
        let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
        if id == "data" {
            let end = min(data.count, offset + 8 + size)
            return stride(from: offset + 8, to: end - 1, by: 2).map { i in
                Float(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)) / 32768
            }
        }
        offset += 8 + size
    }
    return nil
}

private let synthDirectory = Golden.packageRoot.appendingPathComponent("scripts/fixtures/out/synth")

@Suite("EnergyGate on real fixtures")
struct EnergyGateFixtureTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: synthDirectory.appendingPathComponent("silence3.wav").path)))
    func silenceAndPinkNoiseAreRejectedAndSyntheticSpeechIsAccepted() throws {
        let gate = EnergyGate()
        for name in ["silence3", "noise5"] {
            let samples = try #require(readWAV(synthDirectory.appendingPathComponent("\(name).wav")))
            #expect(!gate.analyze(samples).hasSpeech, "\(name) must be rejected")
        }
        var accepted = 0
        for index in 1 ... 19 {
            let name = String(format: "%02d", index)
            guard let samples = readWAV(synthDirectory.appendingPathComponent("\(name).wav")) else { continue }
            let analysis = gate.analyze(samples)
            #expect(analysis.hasSpeech, "phrase \(name): speech \(analysis.speechSeconds)s of \(analysis.totalSeconds)s")
            accepted += 1
        }
        #expect(accepted >= 15)
    }
}
