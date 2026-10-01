import Foundation

/// Decides whether a recording contains speech at all, and trims the silence around it, before any audio
/// reaches the recognizer. Whisper hallucinates confident phrases ("Продолжение следует…", "To be continued…") on silence and
/// noise and its own no-speech probability does not help, so this gate runs first.
public struct EnergyGate: Sendable {
    public struct Analysis: Equatable, Sendable {
        public var totalSeconds: Double
        public var speechSeconds: Double
        public var peakRMS: Float
        public var noiseFloor: Float
        public var leadingSilence: Double
        public var trailingSilence: Double
        public var hasSpeech: Bool
    }

    public var sampleRate = 16_000
    public var frameSeconds = 0.02
    /// Total voiced time required to call a recording speech.
    public var minSpeechSeconds = 0.5
    /// The least voiced time that is still an answer to a question ("да", "нет").
    public static let shortestReplySeconds = 0.2
    /// A frame is voiced when its RMS is above `noiseFloor × ratio` and above `absoluteMin`.
    public var ratio: Float = 4
    public var absoluteMin: Float = 0.008
    /// Silence kept on each side when trimming.
    public var padding = 0.25

    public init() {}

    private func frameRMS(_ samples: [Float]) -> [Float] {
        let size = max(1, Int(Double(sampleRate) * frameSeconds))
        var result: [Float] = []
        result.reserveCapacity(samples.count / size + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + size, samples.count)
            var sum: Float = 0
            for i in index ..< end { sum += samples[i] * samples[i] }
            result.append((sum / Float(end - index)).squareRoot())
            index = end
        }
        return result
    }

    public func analyze(_ samples: [Float]) -> Analysis {
        let rms = frameRMS(samples)
        let total = Double(samples.count) / Double(sampleRate)
        guard !rms.isEmpty else {
            return Analysis(totalSeconds: 0, speechSeconds: 0, peakRMS: 0, noiseFloor: 0, leadingSilence: 0, trailingSilence: 0, hasSpeech: false)
        }
        let sorted = rms.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let threshold = max(floor * ratio, absoluteMin)
        let voiced = rms.map { $0 > threshold }
        let speechSeconds = Double(voiced.filter { $0 }.count) * frameSeconds
        let first = voiced.firstIndex(of: true)
        let last = voiced.lastIndex(of: true)
        return Analysis(
            totalSeconds: total, speechSeconds: speechSeconds, peakRMS: sorted.last ?? 0, noiseFloor: floor,
            leadingSilence: Double(first ?? voiced.count) * frameSeconds,
            trailingSilence: Double(voiced.count - 1 - (last ?? -1)) * frameSeconds,
            hasSpeech: speechSeconds >= minSpeechSeconds
        )
    }

    /// The recording without leading/trailing silence (keeping a little padding), or `nil` when it holds no speech.
    public func trimmed(_ samples: [Float]) -> [Float]? {
        let analysis = analyze(samples)
        guard analysis.hasSpeech else { return nil }
        let start = max(0, Int((analysis.leadingSilence - padding) * Double(sampleRate)))
        let endSeconds = analysis.totalSeconds - max(0, analysis.trailingSilence - padding)
        let end = min(samples.count, Int(endSeconds * Double(sampleRate)))
        guard start < end else { return samples }
        return Array(samples[start ..< end])
    }
}
