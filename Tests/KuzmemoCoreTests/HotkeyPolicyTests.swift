import Testing
@testable import KuzmemoCore

@Suite("HotkeyPolicy")
struct HotkeyPolicyTests {
    @Test func aQuickTapStartsHandsFreeRecordingAndTheNextPressStopsIt() {
        var policy = HotkeyPolicy()
        #expect(policy.triggerDown(at: 0) == [.startRecording])
        #expect(policy.triggerUp(at: 0.12).isEmpty)          // tap: keep recording
        #expect(policy.state == .toggled && policy.isRecording)
        #expect(policy.triggerDown(at: 5.0) == [.stopRecording])
        #expect(!policy.isRecording)
        #expect(policy.triggerUp(at: 5.1).isEmpty)           // the key-up of the stopping press is swallowed
        #expect(policy.state == .idle)
    }

    @Test func holdingIsPushToTalk() {
        var policy = HotkeyPolicy()
        #expect(policy.triggerDown(at: 0) == [.startRecording])
        #expect(policy.triggerUp(at: 1.4) == [.stopRecording])
        #expect(policy.state == .idle)
    }

    @Test func theThresholdIsInclusive() {
        var policy = HotkeyPolicy()
        _ = policy.triggerDown(at: 0)
        #expect(policy.triggerUp(at: 0.30) == [.stopRecording])
        var quicker = HotkeyPolicy()
        _ = quicker.triggerDown(at: 0)
        #expect(quicker.triggerUp(at: 0.299).isEmpty)
    }

    @Test func aChordEarlyInThePressCancelsTheTentativeRecording() {
        var policy = HotkeyPolicy()
        _ = policy.triggerDown(at: 0)
        #expect(policy.otherKeyPressed(at: 0.2) == [.cancelRecording])
        #expect(policy.state == .idle)
        #expect(policy.triggerUp(at: 0.4).isEmpty)            // nothing more to do on release
        // and a new press works normally afterwards
        #expect(policy.triggerDown(at: 1.0) == [.startRecording])
    }

    @Test func aStrayKeyDuringALongHoldIsIgnoredButStillFlagsTheRelease() {
        var policy = HotkeyPolicy()
        _ = policy.triggerDown(at: 0)
        #expect(policy.otherKeyPressed(at: 2.0).isEmpty)      // outside the chord window
        #expect(policy.state == .pressed(since: 0))
        // typing while speaking is not a command: the recording is discarded at release
        #expect(policy.triggerUp(at: 3.0) == [.cancelRecording])
    }

    @Test func keyRepeatAndDuplicateEventsDoNothing() {
        var policy = HotkeyPolicy()
        _ = policy.triggerDown(at: 0)
        #expect(policy.triggerDown(at: 0.05).isEmpty)
        #expect(policy.triggerDown(at: 0.10).isEmpty)
        #expect(policy.triggerUp(at: 0.5) == [.stopRecording])
        #expect(policy.triggerUp(at: 0.6).isEmpty)
        #expect(policy.otherKeyPressed(at: 1).isEmpty)
    }

    @Test func pressingWhileTheAppSpeaksInterruptsTheSpeech() {
        var policy = HotkeyPolicy()
        #expect(policy.triggerDown(at: 0, speaking: true) == [.interruptSpeech, .startRecording])
        // no interruption when a hands-free recording is being stopped
        var toggled = HotkeyPolicy()
        _ = toggled.triggerDown(at: 0); _ = toggled.triggerUp(at: 0.1)
        #expect(toggled.triggerDown(at: 4, speaking: true) == [.stopRecording])
    }

    @Test func endingTheRecordingElsewhereReturnsToIdle() {
        var policy = HotkeyPolicy()
        _ = policy.triggerDown(at: 0); _ = policy.triggerUp(at: 0.1)   // toggled
        policy.recordingEnded()                                        // silence timeout
        #expect(policy.state == .idle)
        #expect(policy.triggerDown(at: 10) == [.startRecording])
    }

    @Test func sleepOrLockCancelsWhateverIsInFlight() {
        var held = HotkeyPolicy()
        _ = held.triggerDown(at: 0)
        #expect(held.reset() == [.cancelRecording] && held.state == .idle)
        var toggled = HotkeyPolicy()
        _ = toggled.triggerDown(at: 0); _ = toggled.triggerUp(at: 0.1)
        #expect(toggled.reset() == [.cancelRecording])
        var idle = HotkeyPolicy()
        #expect(idle.reset().isEmpty)
    }

    @Test func listeningForAnAnswerBehavesLikeAHandsFreeRecording() {
        var policy = HotkeyPolicy()
        #expect(policy.beginHandsFree() == [.startRecording] && policy.state == .toggled)
        // a tap of the key means "that is all": stop, and swallow the key-up that belongs to it
        #expect(policy.triggerDown(at: 5) == [.stopRecording] && policy.state == .stopping)
        #expect(policy.triggerUp(at: 5.1).isEmpty && policy.state == .idle)

        // while the key is held, or a recording runs, nothing starts by itself
        var held = HotkeyPolicy()
        _ = held.triggerDown(at: 0)
        #expect(held.beginHandsFree().isEmpty && held.state == .pressed(since: 0))
        var running = HotkeyPolicy()
        _ = running.beginHandsFree()
        #expect(running.beginHandsFree().isEmpty)
    }

    @Test func thresholdsAreConfigurable() {
        var config = HotkeyPolicy.Configuration()
        config.holdThreshold = 0.6
        var policy = HotkeyPolicy(configuration: config)
        _ = policy.triggerDown(at: 0)
        #expect(policy.triggerUp(at: 0.5).isEmpty)                 // still a tap
        #expect(policy.state == .toggled)
    }
}
