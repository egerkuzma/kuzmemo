import AVFoundation
import CoreMedia
import Foundation
import KuzmemoSTT

/// Records from one chosen input device through a capture session, without touching the system's default input. That is
/// the point: when macOS has selected a Bluetooth headset, opening its microphone switches the headset to call mode,
/// which takes seconds (the first words are lost) and makes it sound worse. A capture session on the built-in
/// microphone leaves the headset alone. The audio goes through the same 16 kHz conversion as `MicCapture`.
nonisolated final class DeviceMicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "kuzmemo.device-mic-capture")
    private let lock = NSLock()
    private var samples: [Float] = []
    private var resampler: AudioResampler16k?
    private var resamplerFormat: AVAudioFormat?

    var onLevel: (@Sendable (Float) -> Void)?
    private(set) var startSeconds: TimeInterval = 0
    var sourceName: String { device.localizedName }

    init(device: AVCaptureDevice) {
        self.device = device
        super.init()
    }

    func start() throws {
        let began = ProcessInfo.processInfo.systemUptime
        defer { startSeconds = ProcessInfo.processInfo.systemUptime - began }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw MicError.engineFailed("\(error)") }
        guard session.canAddInput(input) else { throw MicError.engineFailed("cannot use the microphone \(device.localizedName)") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw MicError.engineFailed("cannot read from the microphone \(device.localizedName)") }
        session.addOutput(output)
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 30)
        resampler = nil
        resamplerFormat = nil
        lock.unlock()
        session.startRunning() // returns once the device is running
        guard session.isRunning else { throw MicError.engineFailed("the microphone \(device.localizedName) did not start") }
    }

    /// Stops recording and returns everything captured.
    func stop() -> [Float] {
        session.stopRunning()
        queue.sync {} // the last callback has finished
        lock.lock(); defer { lock.unlock() }
        if let tail = resampler?.finish() { samples.append(contentsOf: tail) }
        let captured = samples
        samples = []
        return captured
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = Self.buffer(from: sampleBuffer) else { return }
        lock.lock()
        if resampler == nil || resamplerFormat != buffer.format {
            resampler = AudioResampler16k(inputFormat: buffer.format)
            resamplerFormat = buffer.format
        }
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

    /// The PCM audio of a capture buffer, in the format the device delivers.
    private static func buffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: stream) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
