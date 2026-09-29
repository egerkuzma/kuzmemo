import Foundation
import Testing
@testable import KuzmemoCore

@Suite("Microphone choice")
struct MicrophoneChoiceTests {
    private let builtIn = InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", transport: .builtIn)
    private let headset = InputDevice(uid: "00-11-22", name: "WH-1000XM3", transport: .bluetooth)
    private let usb = InputDevice(uid: "AppleUSBAudioEngine:1", name: "Dell USB Audio", transport: .usb)
    private let loopback = InputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transport: .virtual)

    private func devices(default systemDefault: String, _ all: [InputDevice]) -> [InputDevice] {
        all.map { var d = $0; d.isSystemDefault = d.uid == systemDefault; return d }
    }

    @Test func automaticLeavesAWiredOrBuiltInDefaultAlone() {
        for chosen in [builtIn, usb, loopback] {
            let list = devices(default: chosen.uid, [builtIn, headset, usb, loopback])
            #expect(MicrophoneChoice.pick(.automatic, among: list) == MicrophonePick(device: nil), "default \(chosen.name)")
        }
    }

    @Test func automaticAvoidsABluetoothHeadsetBecauseItIsSlowToStartAndSoundsPoor() {
        let list = devices(default: headset.uid, [headset, builtIn, usb])
        let pick = MicrophoneChoice.pick(.automatic, among: list)
        #expect(pick.device?.uid == builtIn.uid)
        #expect(pick.reason == .bluetoothAvoided(systemDefault: "WH-1000XM3"))
    }

    @Test func aBluetoothDefaultStaysWhenThereIsNothingElse() {
        let list = devices(default: headset.uid, [headset, usb])
        #expect(MicrophoneChoice.pick(.automatic, among: list) == MicrophonePick(device: nil))
        #expect(MicrophoneChoice.pick(.automatic, among: []) == MicrophonePick(device: nil))
    }

    @Test func theSystemDefaultIsExactlyThatEvenWhenItIsBluetooth() {
        let list = devices(default: headset.uid, [headset, builtIn])
        #expect(MicrophoneChoice.pick(.systemDefault, among: list) == MicrophonePick(device: nil))
    }

    @Test func aPickedDeviceIsUsedWhileItIsThere() {
        let list = devices(default: headset.uid, [headset, builtIn, usb])
        #expect(MicrophoneChoice.pick(.device(usb.uid), among: list) == MicrophonePick(device: usb))
        #expect(MicrophoneChoice.pick(.device(headset.uid), among: list).device?.uid == headset.uid) // the person's word wins
    }

    @Test func aPickedDeviceThatWasUnpluggedFallsBackToTheAutomaticChoice() {
        let plain = devices(default: builtIn.uid, [builtIn, headset])
        #expect(MicrophoneChoice.pick(.device("gone"), among: plain) == MicrophonePick(device: nil, reason: .pickedDeviceMissing))
        let bluetooth = devices(default: headset.uid, [builtIn, headset])
        let pick = MicrophoneChoice.pick(.device("gone"), among: bluetooth)
        #expect(pick.device?.uid == builtIn.uid)
        #expect(pick.reason == .bluetoothAvoided(systemDefault: "WH-1000XM3")) // the more useful reason wins
    }

    @Test func thePreferenceIsStoredAsAShortString() {
        #expect(MicrophonePreference(stored: nil) == .automatic)
        #expect(MicrophonePreference(stored: "") == .automatic)
        #expect(MicrophonePreference(stored: "system") == .systemDefault)
        #expect(MicrophonePreference(stored: "some-uid") == .device("some-uid"))
        for preference in [MicrophonePreference.automatic, .systemDefault, .device("x")] {
            #expect(MicrophonePreference(stored: preference.stored) == preference)
        }
    }

    @Test func theChoiceSurvivesTheSettingsStoreAndDamageFallsBackToAutomatic() async throws {
        let store = try makeStore()
        #expect(await store.settings(RecordingSettings.self).microphonePreference == .automatic)
        var settings = RecordingSettings()
        settings.microphonePreference = .device("AppleUSBAudioEngine:1")
        try await store.save(settings: settings)
        #expect(await store.settings(RecordingSettings.self).microphonePreference == .device("AppleUSBAudioEngine:1"))
        settings.microphonePreference = .systemDefault
        try await store.save(settings: settings)
        #expect(await store.settings(RecordingSettings.self).microphone == "system")
        try await store.setSetting(#"{"microphone":""}"#, for: RecordingSettings.storageKey)
        #expect(await store.settings(RecordingSettings.self).microphonePreference == .automatic)
        try await store.setSetting(#"{"maxSeconds":90}"#, for: RecordingSettings.storageKey) // saved before the option existed
        let older = await store.settings(RecordingSettings.self)
        #expect(older.maxSeconds == 90 && older.microphonePreference == .automatic)
    }
}
