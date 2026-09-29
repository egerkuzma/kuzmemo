import AVFoundation
import KuzmemoCore

/// Plays speech that arrives in pieces: each `SpokenSegment` is queued behind the ones before it as soon as it is made,
/// so a sentence that is ready in time follows the previous one without a gap, and a sentence that is late is simply
/// heard late. Nothing is played until the first segment arrives.
///
/// An `offline` player runs the same engine without any sound device: the audio is rendered into memory as fast as it can
/// be, so scripts can exercise the queueing and the waiting without making a sound.
@MainActor
final class SegmentPlayer {
    enum Problem: Error { case noOutput(String) }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let offline: Bool
    private var renderer: Task<Void, Never>?
    /// The seconds of audio an offline player has rendered.
    private(set) var renderedSeconds: Double = 0

    init(offline: Bool = false) { self.offline = offline }
    private var format: AVAudioFormat?
    private var running = false
    private var pending = 0
    private var sealed = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// When the audio queued so far would end if nothing more were added (an estimate from the lengths).
    private var endsAt: Date?
    /// The silences heard between segments: a segment queued after the earlier ones had already finished.
    private(set) var silences: [TimeInterval] = []
    private(set) var firstQueuedAt: Date?

    /// The seconds of speech still to be heard, counted from now.
    var remainingSeconds: TimeInterval { max(0, endsAt?.timeIntervalSinceNow ?? 0) }

    func enqueue(_ segment: SpokenSegment) throws {
        if !running { try start(sampleRate: Double(segment.sampleRate)) }
        guard let format, let buffer = Self.buffer(for: segment, format: format) else { return }
        let now = Date()
        if firstQueuedAt == nil { firstQueuedAt = now }
        if let endsAt, now > endsAt { silences.append(now.timeIntervalSince(endsAt)) }
        endsAt = max(now, endsAt ?? now).addingTimeInterval(segment.seconds)
        pending += 1
        // with no sound device nothing is ever "played back": what has been rendered is what has been heard
        node.scheduleBuffer(buffer, completionCallbackType: offline ? .dataRendered : .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played() }
        }
    }

    /// Nothing more will be queued: the wait ends when what is queued has been heard.
    func seal() {
        sealed = true
        finishIfDone()
    }

    /// Returns when everything queued has been played (or `stop()` was called, or the task is cancelled).
    func waitUntilFinished() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !running || (sealed && pending == 0) { continuation.resume(); return }
                waiter = continuation
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    /// The same, but the playback is stopped if it has not ended after `timeout` seconds (a sound device that went away
    /// mid-answer never reports the end).
    func waitUntilFinished(timeout: TimeInterval) async {
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.stop()
        }
        await waitUntilFinished()
        watchdog.cancel()
    }

    func stop() {
        renderer?.cancel()
        renderer = nil
        if running {
            node.stop()
            engine.stop()
            running = false
        }
        pending = 0
        sealed = true
        release()
    }

    private func start(sampleRate: Double) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw Problem.noOutput("unsupported sample rate \(sampleRate)")
        }
        self.format = format
        do {
            if offline { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch { throw Problem.noOutput("\(error)") }
        node.play()
        running = true
        if offline { startRendering() }
    }

    /// Pulls the audio through the engine, since with no device nothing else asks for it.
    private func startRendering() {
        let engine = engine
        renderer = Task { @MainActor [weak self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { return }
            while !Task.isCancelled, self?.running == true {
                guard let status = try? engine.renderOffline(buffer.frameCapacity, to: buffer), status == .success else { break }
                self?.renderedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
                try? await Task.sleep(for: .milliseconds(2)) // the queue is short; there is no hurry
            }
        }
    }

    private func played() {
        pending = max(0, pending - 1)
        finishIfDone()
    }

    private func finishIfDone() {
        guard sealed, pending == 0 else { return }
        renderer?.cancel()
        renderer = nil
        if running {
            node.stop()
            engine.stop()
            running = false
        }
        release()
    }

    private func release() {
        let waiting = waiter
        waiter = nil
        waiting?.resume()
    }

    /// 16-bit samples as the floats the player node wants.
    static func buffer(for segment: SpokenSegment, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(segment.pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        segment.pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0 ..< Int(frames) { channel[index] = Float(Int16(littleEndian: samples[index])) / 32768 }
        }
        return buffer
    }
}
