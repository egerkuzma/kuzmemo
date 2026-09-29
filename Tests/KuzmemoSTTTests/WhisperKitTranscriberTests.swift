import Foundation
import KuzmemoCore
import Testing
@testable import KuzmemoSTT

private let configuration = WhisperKitConfiguration.standard()
private let synth = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("scripts/fixtures/out/synth")

private var modelsAvailable: Bool {
    FileManager.default.fileExists(atPath: configuration.modelFolder.path)
        && FileManager.default.fileExists(atPath: synth.appendingPathComponent("03.wav").path)
}

/// Reads a 16-bit PCM mono 16 kHz WAV written by scripts/fixtures/make_synth.sh.
private func readWAV(_ name: String) -> [Float]? {
    guard let data = try? Data(contentsOf: synth.appendingPathComponent("\(name).wav")), data.count > 44 else { return nil }
    var offset = 12
    while offset + 8 < data.count {
        let id = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
        if id == "data" {
            return stride(from: offset + 8, to: min(data.count, offset + 8 + size) - 1, by: 2).map {
                Float(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)) / 32768
            }
        }
        offset += 8 + size
    }
    return nil
}

@Suite("WhisperKitTranscriber (needs the cloned model and spike fixtures)", .serialized)
struct WhisperKitTranscriberTests {
    @Test func specialTokensAreStripped() {
        #expect(WhisperKitTranscriber.stripSpecialTokens("<|startoftranscript|><|ru|> Привет <|endoftext|>") == "Привет")
    }

    @Test func aMissingModelIsReportedWithItsPath() async throws {
        let missing = WhisperKitConfiguration.standard(modelsRoot: URL(fileURLWithPath: "/nonexistent/models"))
        let transcriber = WhisperKitTranscriber(configuration: missing)
        await #expect(throws: TranscriberError.modelMissing(missing.modelFolder.path)) { try await transcriber.prepare() }
    }

    @Test(.enabled(if: modelsAvailable), .timeLimit(.minutes(5)))
    func recognisesSyntheticRussianAndRejectsSilenceAndNoise() async throws {
        let transcriber = WhisperKitTranscriber(configuration: configuration)
        let recognizer = Recognizer(transcriber: transcriber)

        try await transcriber.prepare()
        #expect(await transcriber.isLoaded)

        let expectations = [("03", "сегодня"), ("14", "завтра"), ("10", "полчаса"), ("13", "напоминани"), ("17", "маме")]
        for (name, word) in expectations {
            let samples = try #require(readWAV(name))
            let result = try await recognizer.recognize(samples)
            guard case let .speech(output) = result else { Issue.record("fixture \(name) was not recognised: \(result)"); continue }
            #expect(output.text.lowercased().contains(word), "fixture \(name): «\(output.text)»")
            #expect(output.processingSeconds < 4, "fixture \(name) took \(output.processingSeconds)s")
            #expect(output.language == "ru")
        }
        for name in ["silence3", "noise5"] {
            let samples = try #require(readWAV(name))
            guard case .noSpeech = try await recognizer.recognize(samples) else { Issue.record("\(name) must be rejected"); continue }
        }

        await transcriber.unload()
        #expect(await !transcriber.isLoaded)
        // and it loads again on demand
        let again = try #require(readWAV("03"))
        _ = try await recognizer.recognize(again)
        #expect(await transcriber.isLoaded)
        await transcriber.unload()
    }

    @Test(.enabled(if: modelsAvailable), .timeLimit(.minutes(5)))
    func concurrentPrepareCallsShareOneLoad() async throws {
        let transcriber = WhisperKitTranscriber(configuration: configuration)
        async let first: Void = transcriber.prepare()
        async let second: Void = transcriber.prepare()
        _ = try await (first, second)
        #expect(await transcriber.isLoaded)
        await transcriber.unload()
    }
}
