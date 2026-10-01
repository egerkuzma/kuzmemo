import Foundation
import Testing
@testable import KuzmemoCore

/// A sound output the tests can play with: with or without a mute switch, and the person can touch it at any time.
private final class FakeOutput: OutputAudioBackend {
    var hasMuteSwitch = true
    var muted = false
    var volume: Float = 0.6
    var canBeControlled = true
    /// A device that has dropped out (a headset that was switched off): nothing about it can be read.
    var available = true
    private(set) var silenceCalls = 0
    private(set) var restoreCalls = 0

    func silenceDefaultOutput() -> SilenceToken? {
        silenceCalls += 1
        guard canBeControlled else { return nil }
        if hasMuteSwitch {
            if muted { return nil }
            muted = true
            return SilenceToken(deviceUID: "speakers", usedVolume: false)
        }
        if volume <= 0.001 { return nil }
        let before = volume
        volume = 0
        return SilenceToken(deviceUID: "speakers", usedVolume: true, previousVolume: before)
    }

    func isStillSilenced(_ token: SilenceToken) -> Bool { token.usedVolume ? volume <= 0.001 : muted }

    func state(of token: SilenceToken) -> SilenceState {
        available ? (isStillSilenced(token) ? .silenced : .changedByPerson) : .deviceUnavailable
    }

    func restore(_ token: SilenceToken) {
        restoreCalls += 1
        if token.usedVolume { volume = token.previousVolume } else { muted = false }
    }
}

private final class MemoryJournal: SilenceJournal {
    var token: SilenceToken?
    func load() -> SilenceToken? { token }
    func save(_ token: SilenceToken) { self.token = token }
    func clear() { token = nil }
}

@MainActor
@Suite("The sound goes off while recording")
struct OutputMuteTests {
    private func make(_ output: FakeOutput = FakeOutput()) -> (OutputMuteGuard, FakeOutput, MemoryJournal) {
        let journal = MemoryJournal()
        return (OutputMuteGuard(backend: output, journal: journal), output, journal)
    }

    @Test func theOutputIsMutedForTheRecordingAndComesBack() {
        let (guardian, output, journal) = make()
        guardian.begin()
        #expect(output.muted && guardian.isSilencing && journal.token != nil)
        guardian.end()
        #expect(!output.muted && !guardian.isSilencing && journal.token == nil)
    }

    @Test func aMuteThePersonMadeThemselvesStays() {
        let output = FakeOutput()
        output.muted = true
        let (guardian, _, journal) = make(output)
        guardian.begin()
        #expect(!guardian.isSilencing && journal.token == nil)
        guardian.end()
        #expect(output.muted, "their own mute must not be undone")
    }

    /// A headset that drops out mid-recording may come back still muted. The note of the silence must survive until it can be
    /// settled, or the mute is later taken for the person's own and never undone.
    @Test func aDeviceThatWasAwayIsPutRightWhenItIsBack() {
        let (guardian, output, journal) = make()
        guardian.begin()
        output.available = false // the headset dropped out
        guardian.end()
        #expect(output.muted && output.restoreCalls == 0 && journal.token != nil, "the note must stay while the device cannot be read")
        output.available = true // it is back, still muted
        guardian.recoverAfterCrash()
        #expect(!output.muted && output.restoreCalls == 1 && journal.token == nil)
    }

    @Test func theNextRecordingSettlesWhatTheLastCouldNot() {
        let (guardian, output, journal) = make()
        guardian.begin()
        output.available = false
        guardian.end()
        output.available = true
        guardian.begin() // the device is back: the old mute is undone, then this recording silences it afresh
        #expect(output.muted && output.restoreCalls == 1 && output.silenceCalls == 2 && journal.token != nil)
        guardian.end()
        #expect(!output.muted && journal.token == nil)
    }

    @Test func aDeviceThatStaysAwayKeepsTheNoteForTheNextLaunch() {
        let (guardian, output, journal) = make()
        guardian.begin()
        output.available = false
        guardian.end()
        guardian.recoverAfterCrash() // the launch: still away
        #expect(journal.token != nil && output.restoreCalls == 0)
    }

    @Test func aPersonWhoUnmutesDuringTheRecordingIsNotMutedAgain() {
        let (guardian, output, _) = make()
        guardian.begin()
        output.muted = false // they reached for the keyboard
        guardian.end()
        #expect(!output.muted && output.restoreCalls == 0)
    }

    @Test func overlappingRecordingsShareOneSilence() {
        let (guardian, output, _) = make()
        guardian.begin()
        guardian.begin()
        #expect(output.silenceCalls == 1)
        guardian.end()
        #expect(output.muted, "the outer recording is still going")
        guardian.end()
        #expect(!output.muted)
    }

    @Test func aDeviceWithoutAMuteSwitchHasItsVolumeTurnedDownAndBack() {
        let output = FakeOutput()
        output.hasMuteSwitch = false
        let (guardian, _, _) = make(output)
        guardian.begin()
        #expect(output.volume == 0)
        guardian.end()
        #expect(output.volume == 0.6)
    }

    @Test func aVolumeThePersonRaisedDuringTheRecordingIsLeftAlone() {
        let output = FakeOutput()
        output.hasMuteSwitch = false
        let (guardian, _, _) = make(output)
        guardian.begin()
        output.volume = 0.9
        guardian.end()
        #expect(output.volume == 0.9)
    }

    @Test func aDeviceThatCannotBeControlledIsLeftAlone() {
        let output = FakeOutput()
        output.canBeControlled = false
        let (guardian, _, journal) = make(output)
        guardian.begin()
        guardian.end()
        #expect(journal.token == nil && output.restoreCalls == 0)
    }

    @Test func endingWithoutBeginningDoesNothing() {
        let (guardian, output, _) = make()
        guardian.end()
        guardian.forceEnd()
        #expect(output.silenceCalls == 0 && output.restoreCalls == 0 && !output.muted)
    }

    @Test func quittingBringsTheSoundBackWhateverTheCount() {
        let (guardian, output, journal) = make()
        guardian.begin()
        guardian.begin()
        guardian.forceEnd()
        #expect(!output.muted && journal.token == nil)
    }

    @Test func aKilledAppPutsTheSoundBackAtTheNextLaunch() {
        let output = FakeOutput()
        output.muted = true // left so by the run that was killed
        let journal = MemoryJournal()
        journal.token = SilenceToken(deviceUID: "speakers", usedVolume: false)
        let guardian = OutputMuteGuard(backend: output, journal: journal)
        guardian.recoverAfterCrash()
        #expect(!output.muted && journal.token == nil)
    }

    @Test func aLeftoverNoteIsDroppedWhenThePersonHasSinceUnmuted() {
        let output = FakeOutput() // not muted
        let journal = MemoryJournal()
        journal.token = SilenceToken(deviceUID: "speakers", usedVolume: false)
        let guardian = OutputMuteGuard(backend: output, journal: journal)
        guardian.recoverAfterCrash()
        #expect(output.restoreCalls == 0 && journal.token == nil)
    }

    @Test func theNoteSurvivesInAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mute-\(UUID().uuidString)/note.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = FileSilenceJournal(url: url)
        #expect(journal.load() == nil)
        let token = SilenceToken(deviceUID: "abc", usedVolume: true, previousVolume: 0.4)
        journal.save(token)
        #expect(FileSilenceJournal(url: url).load() == token)
        journal.clear()
        #expect(journal.load() == nil)
    }
}
