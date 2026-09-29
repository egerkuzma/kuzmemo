/// An audio input the Mac offers.
public struct InputDevice: Equatable, Hashable, Sendable, Identifiable {
    public enum Transport: String, Sendable {
        case builtIn, bluetooth, usb, virtual, other
    }

    /// The device's stable identifier (it survives a restart and a re-plug; the numeric id does not).
    public var uid: String
    public var name: String
    public var transport: Transport
    /// The input macOS has selected in System Settings → Sound.
    public var isSystemDefault: Bool

    public var id: String { uid }

    public init(uid: String, name: String, transport: Transport, isSystemDefault: Bool = false) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isSystemDefault = isSystemDefault
    }
}

/// Which microphone the person asked for in Settings → Recording.
public enum MicrophonePreference: Equatable, Sendable {
    /// What macOS selected, except a Bluetooth headset: its microphone needs a few seconds to switch the headset to call
    /// mode (the first words of a phrase are lost) and makes it sound worse, so the built-in one is used instead.
    case automatic
    /// Exactly the input macOS has selected.
    case systemDefault
    /// One device, by its UID.
    case device(String)

    /// The value kept in the settings: `nil` for automatic, "system" for the system default, else a device UID.
    public init(stored: String?) {
        switch stored {
        case nil, "": self = .automatic
        case "system": self = .systemDefault
        case let uid?: self = .device(uid)
        }
    }

    public var stored: String? {
        switch self {
        case .automatic: nil
        case .systemDefault: "system"
        case let .device(uid): uid
        }
    }
}

/// The outcome of choosing a microphone.
public struct MicrophonePick: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The system input is a Bluetooth headset, so the built-in microphone is used instead.
        case bluetoothAvoided(systemDefault: String)
        /// The device the person picked is not connected now, so the automatic choice was made.
        case pickedDeviceMissing
    }

    /// The device to record from; `nil` means leave the system default alone.
    public var device: InputDevice?
    /// Why the choice differs from what the person asked for or from the system default, if it does.
    public var reason: Reason?

    public init(device: InputDevice?, reason: Reason? = nil) {
        self.device = device
        self.reason = reason
    }
}

public enum MicrophoneChoice {
    public static func pick(_ preference: MicrophonePreference, among devices: [InputDevice]) -> MicrophonePick {
        switch preference {
        case .systemDefault:
            return MicrophonePick(device: nil)
        case let .device(uid):
            if let device = devices.first(where: { $0.uid == uid }) { return MicrophonePick(device: device) }
            var fallback = automatic(among: devices)
            fallback.reason = fallback.reason ?? .pickedDeviceMissing
            return fallback
        case .automatic:
            return automatic(among: devices)
        }
    }

    private static func automatic(among devices: [InputDevice]) -> MicrophonePick {
        guard let systemDefault = devices.first(where: \.isSystemDefault), systemDefault.transport == .bluetooth,
              let builtIn = devices.first(where: { $0.transport == .builtIn })
        else { return MicrophonePick(device: nil) }
        return MicrophonePick(device: builtIn, reason: .bluetoothAvoided(systemDefault: systemDefault.name))
    }
}
