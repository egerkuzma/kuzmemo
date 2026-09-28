import AVFoundation
import Foundation
import KuzmemoSTT

enum MicError: Error, Equatable {
    case noInputDevice
    case engineFailed(String)
}

/// Records from the default input device into 16 kHz mono Float32 samples held in memory. The audio tap runs
/// on a real-time thread, so it only converts, appends under a lock and reports a level.
nonisolated final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var resampler: AudioResampler16k?
    private var running = false

    /// Called from the audio thread with the RMS of each converted chunk.
    var onLevel: (@Sendable (Float) -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = AudioResampler16k(inputFormat: format) else {
            throw MicError.noInputDevice
        }
        lock.lock()
        self.resampler = resampler
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 30)
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicError.engineFailed("\(error)")
        }
        lock.lock(); running = true; lock.unlock()
    }

    /// Stops recording and returns everything captured.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        running = false
        if let tail = resampler?.finish() { samples.append(contentsOf: tail) }
        let captured = samples
        samples = []
        return captured
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let resampler = self.resampler
        lock.unlock()
        guard let converted = resampler?.convert(buffer), !converted.isEmpty else { return }
        var sum: Float = 0
        for x in converted { sum += x * x }
        let level = (sum / Float(converted.count)).squareRoot()
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
        onLevel?(level)
    }
}
