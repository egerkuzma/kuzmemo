import Foundation

/// Follows the microphone level while a hands-free recording runs and reports when the speaker has started,
/// has finished (a stretch of silence after speech), or never started at all. Times are seconds since the
/// recording began. Unlike `EnergyGate`, which judges a finished recording, this works on a live stream.
public struct EndOfSpeechDetector: Sendable {
    public struct Configuration: Sendable {
        /// Silence after speech that ends the recording.
        public var silenceAfterSpeech: TimeInterval = 2.5
        /// Voiced time before speech counts as started; a click or a cough is shorter than this.
        public var minVoiced: TimeInterval = 0.3
        /// A frame is voiced when its level is above `noiseFloor × ratio` and above `absoluteMin`.
        public var ratio: Float = 4
        public var absoluteMin: Float = 0.008
        /// How fast the noise floor climbs towards a steady level, per second. It starts at the first reading
        /// and drops at once to any quieter frame, so the gaps between words keep it near the room noise, and a
        /// fan that starts humming mid-recording is absorbed within a couple of seconds.
        public var floorRisePerSecond: Float = 0.2
        /// Give up when nothing was said within this long (nil waits until the caller's own limit).
        public var speechWait: TimeInterval?

        public init(silenceAfterSpeech: TimeInterval = 2.5, speechWait: TimeInterval? = nil) {
            self.silenceAfterSpeech = silenceAfterSpeech
            self.speechWait = speechWait
        }
    }

    public enum Event: Equatable, Sendable {
        case speechStarted
        case endOfSpeech
        /// `speechWait` passed without speech.
        case noSpeech
    }

    public var configuration: Configuration
    public private(set) var hasSpeech = false
    public private(set) var noiseFloor: Float?

    private var lastTime: TimeInterval?
    private var voicedSeconds: TimeInterval = 0
    private var lastVoicedAt: TimeInterval = 0
    private var finished = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feeds one level reading (RMS of the latest audio, 0...1). Returns an event when something changed;
    /// after `endOfSpeech` or `noSpeech` nothing more is reported.
    public mutating func feed(level: Float, at time: TimeInterval) -> Event? {
        defer { lastTime = time }
        guard !finished else { return nil }
        let step = min(0.25, max(0, time - (lastTime ?? time)))

        let floor = noiseFloor ?? level
        let voiced = level > max(floor * configuration.ratio, configuration.absoluteMin)
        if voiced {
            voicedSeconds += step
            lastVoicedAt = time
        }
        noiseFloor = level < floor ? level : floor + (level - floor) * min(1, configuration.floorRisePerSecond * Float(step))

        if !hasSpeech {
            if voicedSeconds >= configuration.minVoiced {
                hasSpeech = true
                return .speechStarted
            }
            if let wait = configuration.speechWait, time >= wait {
                finished = true
                return .noSpeech
            }
            return nil
        }
        if time - lastVoicedAt >= configuration.silenceAfterSpeech {
            finished = true
            return .endOfSpeech
        }
        return nil
    }
}
