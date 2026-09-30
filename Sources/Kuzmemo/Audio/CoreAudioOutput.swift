import AudioToolbox
import CoreAudio
import Foundation
import KuzmemoCore

/// The Mac's default sound output through Core Audio: a device with a mute switch is muted, one without (many Bluetooth
/// headsets) has its volume set to zero. What was there before is kept in the token, and nothing is restored that the person
/// has changed meanwhile.
final class CoreAudioOutput: OutputAudioBackend {
    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func uid(of device: AudioDeviceID) -> String? {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func device(forUID uid: String) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var cfUID = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func settable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var property = address(selector)
        guard AudioObjectHasProperty(device, &property) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
    }

    private func muted(_ device: AudioDeviceID) -> Bool? {
        var property = address(kAudioDevicePropertyMute)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private func setMuted(_ device: AudioDeviceID, _ on: Bool) -> Bool {
        var property = address(kAudioDevicePropertyMute)
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The volume as the system's own slider has it (0...1), which also works for devices with several channels.
    private func volume(_ device: AudioDeviceID) -> Float? {
        var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func setVolume(_ device: AudioDeviceID, _ level: Float) -> Bool {
        var property = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(level)
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    func silenceDefaultOutput() -> SilenceToken? {
        guard let device = defaultDevice(), let uid = uid(of: device) else { return nil }
        if settable(device, kAudioDevicePropertyMute), let already = muted(device) {
            if already { return nil } // the person's own mute stays theirs
            return setMuted(device, true) ? SilenceToken(deviceUID: uid, usedVolume: false) : nil
        }
        if settable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume), let level = volume(device) {
            if level <= 0.001 { return nil }
            return setVolume(device, 0) ? SilenceToken(deviceUID: uid, usedVolume: true, previousVolume: level) : nil
        }
        return nil
    }

    func isStillSilenced(_ token: SilenceToken) -> Bool {
        guard let device = device(forUID: token.deviceUID) else { return false }
        if token.usedVolume { return (volume(device) ?? 1) <= 0.001 }
        return muted(device) == true
    }

    func restore(_ token: SilenceToken) {
        guard let device = device(forUID: token.deviceUID) else { return }
        if token.usedVolume { _ = setVolume(device, token.previousVolume) } else { _ = setMuted(device, false) }
    }
}

/// What the automation build uses instead: it never touches the sound of the Mac, but scripts can see what would have
/// happened.
final class SimulatedOutput: OutputAudioBackend {
    private(set) var silenced = false
    private(set) var events: [String] = []

    func silenceDefaultOutput() -> SilenceToken? {
        events.append("silence")
        silenced = true
        return SilenceToken(deviceUID: "simulated", usedVolume: false)
    }

    func isStillSilenced(_ token: SilenceToken) -> Bool { silenced }

    func restore(_ token: SilenceToken) {
        events.append("restore")
        silenced = false
    }
}
