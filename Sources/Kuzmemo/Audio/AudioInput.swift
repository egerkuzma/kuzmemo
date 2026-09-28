import Foundation
import KuzmemoSTT

/// Where a recording's audio comes from: the microphone, or a file played back in real time so the whole
/// voice path (hotkey, recording, silence detection) can be exercised from the control channel without a person.
nonisolated protocol AudioInput: AnyObject, Sendable {
    /// Called from a background thread with the RMS of each converted chunk.
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    func start() throws
    /// Stops and returns everything captured as 16 kHz mono Float32.
    func stop() -> [Float]
}

extension MicCapture: AudioInput {}

/// Plays prepared samples as if they were being spoken now: levels are reported at the pace of real time, and
/// after the samples run out it "hears" silence for as long as the recording continues.
nonisolated final class ScriptedAudioInput: AudioInput, @unchecked Sendable {
    private let samples: [Float]
    private let lock = NSLock()
    private var startedAt: Date?
    private var reported = 0
    private var timer: (any DispatchSourceTimer)?
    var onLevel: (@Sendable (Float) -> Void)?

    init(samples: [Float]) {
        self.samples = samples
    }

    func start() throws {
        lock.lock()
        startedAt = Date()
        reported = 0
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kuzmemo.scripted-audio"))
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        lock.lock(); self.timer = timer; lock.unlock()
    }

    func stop() -> [Float] {
        lock.lock()
        timer?.cancel()
        timer = nil
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        lock.unlock()
        let count = Int(elapsed * 16_000)
        return count <= samples.count ? Array(samples[..<count]) : samples + [Float](repeating: 0, count: count - samples.count)
    }

    private func tick() {
        lock.lock()
        let target = Int(Date().timeIntervalSince(startedAt ?? Date()) * 16_000)
        let from = reported
        reported = target
        lock.unlock()
        guard target > from else { return }
        var sum: Float = 0
        var n = 0
        for i in from ..< target where i < samples.count {
            sum += samples[i] * samples[i]
            n += 1
        }
        onLevel?(n == 0 ? 0 : (sum / Float(n)).squareRoot())
    }
}

/// The loudest level reported since it was last read; the recording tick polls it.
nonisolated final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    func record(_ level: Float) {
        lock.lock(); peak = max(peak, level); lock.unlock()
    }

    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }
}
