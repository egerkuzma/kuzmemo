import AVFoundation

/// Converts whatever the input device delivers (44.1/48 kHz, mono or stereo, Float32 or Int16) into the
/// 16 kHz mono Float32 samples the recognizer wants. One instance per recording keeps the filter state
/// continuous across buffers.
public final class AudioResampler16k {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    public init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        // Without this a stereo input is made mono by taking the first channel only: a voice that reaches the microphone
        // through the second channel (an audio interface's second input, a one-sided file) would come out silent.
        converter.downmix = true
        self.converter = converter
        self.outputFormat = output
        self.ratio = 16_000 / inputFormat.sampleRate
    }

    /// Flushes the samples the sample-rate converter still holds (about 20 ms) at the end of a recording.
    public func finish() -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return [] }
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Converts one buffer; returns the 16 kHz mono samples (possibly a few fewer or more than proportional).
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
