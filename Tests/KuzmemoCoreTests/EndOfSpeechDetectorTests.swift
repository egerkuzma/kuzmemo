import Testing
@testable import KuzmemoCore

/// Levels at 50 ms steps, the cadence of the app's recording tick.
private struct Stream {
    var detector: EndOfSpeechDetector
    var time: Double = 0
    var events: [(EndOfSpeechDetector.Event, Double)] = []

    init(_ configuration: EndOfSpeechDetector.Configuration = .init()) {
        detector = EndOfSpeechDetector(configuration: configuration)
    }

    mutating func play(_ seconds: Double, level: (Double) -> Float) {
        let start = time
        var t = 0.0
        while t < seconds - 1e-9 {
            time += 0.05
            t += 0.05
            if let event = detector.feed(level: level(time - start), at: time) { events.append((event, time)) }
        }
    }

    mutating func silence(_ seconds: Double) { play(seconds) { _ in 0.003 } }

    /// Words of 0.4 s with 0.1 s gaps, like ordinary speech.
    mutating func speak(_ seconds: Double, loud: Float = 0.12) {
        play(seconds) { t in t.truncatingRemainder(dividingBy: 0.5) < 0.4 ? loud : 0.01 }
    }

    var kinds: [EndOfSpeechDetector.Event] { events.map(\.0) }
}

@Suite("EndOfSpeechDetector")
struct EndOfSpeechDetectorTests {
    @Test func aSentenceFollowedBySilenceEndsTheRecording() {
        var stream = Stream()
        stream.silence(1)
        stream.speak(3)
        stream.silence(4)
        #expect(stream.kinds == [.speechStarted, .endOfSpeech])
        // Speech ended at about 4.0 s; the recording stops 2.5 s later.
        let end = stream.events[1].1
        #expect(end > 6.3 && end < 6.7)
    }

    @Test func aPauseShorterThanTheTimeoutDoesNotEndIt() {
        var stream = Stream()
        stream.speak(2)
        stream.silence(2)
        stream.speak(2)
        stream.silence(3)
        #expect(stream.kinds == [.speechStarted, .endOfSpeech])
        #expect(stream.events[1].1 > 6.4) // after the second sentence, not the first
    }

    @Test func aClickIsNotSpeech() {
        var stream = Stream()
        stream.silence(1)
        stream.play(0.1) { _ in 0.3 }
        stream.silence(5)
        #expect(stream.kinds.isEmpty)
    }

    /// The app's meter reports its peak per 50 ms tick, and a tick that falls between two audio buffers reads exactly 0. That is
    /// "no new audio", not a silent room: the noise floor must not follow it down to zero (it used to, and room noise of 0.02
    /// then counted as speech).
    @Test func aTickWithoutNewAudioIsNotAQuietMoment() {
        var stream = Stream(.init(speechWait: 7))
        stream.play(0.05) { _ in 0 } // the first tick comes before any audio
        stream.play(8) { t in Int((t / 0.05).rounded()) % 2 == 0 ? 0 : 0.02 } // steady noise, every other tick empty
        #expect(stream.kinds == [.noSpeech], "room noise was taken for speech: \(stream.kinds)")
        var spoken = Stream()
        spoken.play(0.05) { _ in 0 }
        spoken.silence(1)
        spoken.speak(2)
        spoken.silence(4)
        #expect(spoken.kinds == [.speechStarted, .endOfSpeech])
    }

    @Test func waitingForSpeechGivesUpOnce() {
        var stream = Stream(.init(speechWait: 7))
        stream.silence(10)
        #expect(stream.kinds == [.noSpeech])
        #expect(abs(stream.events[0].1 - 7) < 0.06)
    }

    @Test func speechWithinTheWaitIsNotAbandoned() {
        var stream = Stream(.init(speechWait: 7))
        stream.silence(5)
        stream.speak(2)
        stream.silence(4)
        #expect(stream.kinds == [.speechStarted, .endOfSpeech])
    }

    @Test func steadyBackgroundNoiseIsNotSpeech() {
        // A fan at -30 dBFS from the first moment: the floor is seeded from it.
        var stream = Stream()
        stream.play(10) { _ in 0.03 }
        #expect(stream.kinds.isEmpty)
    }

    @Test func speechOverSteadyNoiseIsHeardAndEnds() {
        var stream = Stream()
        stream.play(3) { _ in 0.03 }
        stream.speak(3, loud: 0.3)
        stream.play(4) { _ in 0.03 }
        #expect(stream.kinds == [.speechStarted, .endOfSpeech])
        #expect(stream.events[0].1 > 3)
    }

    @Test func aFanThatStartsMidRecordingIsAbsorbed() {
        var stream = Stream(.init(speechWait: 12))
        stream.silence(2)
        stream.play(8) { _ in 0.03 } // looks like speech for about a second, then the floor catches up
        #expect(stream.kinds.first == .speechStarted)
        #expect(stream.kinds.last == .endOfSpeech)
    }

    @Test func quietSpeechInAQuietRoomIsDetected() {
        var stream = Stream()
        stream.silence(1)
        stream.speak(2, loud: 0.02)
        stream.silence(3)
        #expect(stream.kinds == [.speechStarted, .endOfSpeech])
    }
}
