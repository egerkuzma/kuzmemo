import Foundation

/// A group of related preferences stored as one JSON value in the settings table. Reading is forgiving: a value
/// saved by an older version (fewer fields) or a damaged one falls back to the defaults field by field.
public protocol SettingsGroup: Codable, Equatable, Sendable {
    static var storageKey: String { get }
    init()
}

extension Store {
    /// The stored group, or the defaults when nothing is stored or the stored value cannot be read as this group. A read that
    /// fails (the database cannot be read right now) is the defaults too: for whoever only needs something to show.
    public func settings<T: SettingsGroup>(_ type: T.Type = T.self) async -> T {
        (try? await loadSettings(type)) ?? T()
    }

    /// Like `settings`, but a read that fails is an error, not the defaults. "Nothing stored" and "a damaged value" still fall back
    /// to the defaults field by field, which is what they mean; "could not read" means nothing about what is stored, and a
    /// caller that would save the group later must not take the defaults for the person's choices.
    public func loadSettings<T: SettingsGroup>(_ type: T.Type = T.self) async throws -> T {
        guard let text = try await setting(T.storageKey), let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return T() }
        return value
    }

    public func save<T: SettingsGroup>(settings value: T) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try await setSetting(String(decoding: try encoder.encode(value), as: UTF8.self), for: T.storageKey)
    }
}

/// What produces the voice: the system's synthesizer, the Silero neural voice (a Python helper process), or the
/// person's own cloned voice ("My voice", a native program that runs for as long as an answer is spoken).
public enum SpeechEngine: String, Codable, CaseIterable, Sendable {
    case system, silero, clone
}

/// Voice output.
public struct SpeechSettings: SettingsGroup {
    public static let storageKey = "settings.speech"

    /// The speech engine; the system voice is always the fallback when Silero is missing or fails.
    public var engine = SpeechEngine.system
    /// The Silero speaker ("eugene", "xenia", …).
    public var sileroSpeaker = SileroVoice.defaultSpeaker
    /// A Python interpreter with torch chosen by hand; `nil` looks in the usual places.
    public var sileroPython: String?
    /// An `AVSpeechSynthesisVoice` identifier for Russian speech; `nil` picks the best installed Russian voice.
    public var voiceIdentifier: String?
    /// The same for English speech.
    public var englishVoiceIdentifier: String?
    /// The speaking rate of the system voice and Silero; 0.5 is the system default. The cloned voice keeps its own pace.
    public var rate = 0.5
    /// How many decoding steps the cloned voice takes for every sentence: fewer is quicker, more is clearer. The owner listened
    /// to 8, 12 and 16 with their own sample and chose to start with 8 (the answer starts about 1.6 s sooner than with 16).
    public var cloneSteps = SpeechSettings.defaultCloneSteps
    /// Read answers and questions aloud.
    public var speakAnswers = true
    /// Also say what was saved ("Saved: …").
    public var speakConfirmations = false
    /// A short sound when something was saved.
    public var confirmationSound = true

    public static let defaultCloneSteps = 8
    public static let cloneStepsRange = 8 ... 32

    public init() {}

    enum CodingKeys: String, CodingKey {
        case engine, sileroSpeaker, sileroPython, voiceIdentifier, englishVoiceIdentifier, rate, cloneSteps, speakAnswers, speakConfirmations, confirmationSound
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try c.decodeIfPresent(String.self, forKey: .engine)).flatMap(SpeechEngine.init(rawValue:)) ?? engine
        let speaker = try c.decodeIfPresent(String.self, forKey: .sileroSpeaker)?.trimmingCharacters(in: .whitespaces)
        sileroSpeaker = speaker.flatMap { $0.isEmpty ? nil : $0 } ?? sileroSpeaker
        sileroPython = try c.decodeIfPresent(String.self, forKey: .sileroPython).flatMap { $0.isEmpty ? nil : $0 }
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        englishVoiceIdentifier = try c.decodeIfPresent(String.self, forKey: .englishVoiceIdentifier)
        rate = min(max(try c.decodeIfPresent(Double.self, forKey: .rate) ?? rate, 0.2), 0.7)
        cloneSteps = min(max(try c.decodeIfPresent(Int.self, forKey: .cloneSteps) ?? cloneSteps, Self.cloneStepsRange.lowerBound), Self.cloneStepsRange.upperBound)
        speakAnswers = try c.decodeIfPresent(Bool.self, forKey: .speakAnswers) ?? speakAnswers
        speakConfirmations = try c.decodeIfPresent(Bool.self, forKey: .speakConfirmations) ?? speakConfirmations
        confirmationSound = try c.decodeIfPresent(Bool.self, forKey: .confirmationSound) ?? confirmationSound
    }
}

/// Speech recognition.
public struct RecognitionSettings: SettingsGroup {
    public static let storageKey = "settings.recognition"
    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"

    /// The folder name of the WhisperKit model in use.
    public var modelVariant = RecognitionSettings.defaultVariant
    /// "ru", or `nil` to let the model detect the language.
    public var language: String? = "ru"
    /// The model leaves memory after this many idle minutes (0: keep it loaded).
    public var idleUnloadMinutes = 15

    public init() {}

    enum CodingKeys: String, CodingKey { case modelVariant, language, idleUnloadMinutes, languageAuto }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelVariant = try c.decodeIfPresent(String.self, forKey: .modelVariant) ?? modelVariant
        if try c.decodeIfPresent(Bool.self, forKey: .languageAuto) == true {
            language = nil
        } else if c.contains(.language) {
            language = try c.decodeNil(forKey: .language) ? nil : try c.decode(String.self, forKey: .language) // explicit null: detect
        }
        idleUnloadMinutes = min(max(try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? idleUnloadMinutes, 0), 240)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelVariant, forKey: .modelVariant)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encode(language == nil, forKey: .languageAuto) // nil is otherwise indistinguishable from "missing"
        try c.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
    }
}

/// How recording behaves.
public struct RecordingSettings: SettingsGroup {
    public static let storageKey = "settings.recording"

    /// Held at least this long means push-to-talk, seconds.
    public var holdThreshold = 0.30
    /// A hands-free recording stops after this much silence following speech, seconds.
    public var handsFreeSilence = 2.5
    /// The longest recording, seconds.
    public var maxSeconds = 120
    /// The microphone: `nil` is automatic (the built-in one when the system input is a Bluetooth headset), "system" is
    /// whatever macOS has selected, anything else is the UID of one device. See `MicrophonePreference`.
    public var microphone: String?
    /// The sound of the Mac (headphones or speakers) is turned off while a recording lasts and comes back afterwards.
    public var muteWhileRecording = true

    public init() {}

    /// The stored choice as a value.
    public var microphonePreference: MicrophonePreference {
        get { MicrophonePreference(stored: microphone) }
        set { microphone = newValue.stored }
    }

    enum CodingKeys: String, CodingKey { case holdThreshold, handsFreeSilence, maxSeconds, microphone, muteWhileRecording }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        holdThreshold = min(max(try c.decodeIfPresent(Double.self, forKey: .holdThreshold) ?? holdThreshold, 0.15), 0.8)
        handsFreeSilence = min(max(try c.decodeIfPresent(Double.self, forKey: .handsFreeSilence) ?? handsFreeSilence, 1), 8)
        maxSeconds = min(max(try c.decodeIfPresent(Int.self, forKey: .maxSeconds) ?? maxSeconds, 20), 600)
        let stored = try c.decodeIfPresent(String.self, forKey: .microphone)
        microphone = stored?.isEmpty == false ? stored : nil
        muteWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .muteWhileRecording) ?? muteWhileRecording
    }
}
