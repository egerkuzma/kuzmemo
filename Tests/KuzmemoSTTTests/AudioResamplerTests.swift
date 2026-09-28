import AVFoundation
import Testing
@testable import KuzmemoSTT

private func toneBuffer(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, frequency: Double = 440, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0 ..< Int(channels) {
        let data = buffer.floatChannelData![channel]
        for i in 0 ..< Int(frames) { data[i] = amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) }
    }
    return buffer
}

private func rms(_ samples: [Float]) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
}

/// Feeds a long tone in device-sized chunks, the way the audio tap delivers it.
private func convertInChunks(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, chunk: AVAudioFrameCount = 1024) -> [Float] {
    let whole = toneBuffer(sampleRate: sampleRate, channels: channels, seconds: seconds)
    let resampler = AudioResampler16k(inputFormat: whole.format)!
    var result: [Float] = []
    var start: AVAudioFrameCount = 0
    while start < whole.frameLength {
        let count = min(chunk, whole.frameLength - start)
        let piece = AVAudioPCMBuffer(pcmFormat: whole.format, frameCapacity: count)!
        piece.frameLength = count
        for channel in 0 ..< Int(channels) {
            for i in 0 ..< Int(count) { piece.floatChannelData![channel][i] = whole.floatChannelData![channel][Int(start) + i] }
        }
        result += resampler.convert(piece)
        start += count
    }
    return result
}

@Suite("AudioResampler16k")
struct AudioResamplerTests {
    @Test(arguments: [(48_000.0, AVAudioChannelCount(2)), (44_100.0, 1), (48_000.0, 1), (16_000.0, 1), (24_000.0, 2)])
    func producesSixteenKilohertzMonoOfTheRightLength(rate: Double, channels: AVAudioChannelCount) {
        let samples = convertInChunks(sampleRate: rate, channels: channels, seconds: 2)
        #expect(abs(samples.count - 32_000) < 400, "\(rate) Hz/\(channels)ch gave \(samples.count) samples")
        // a 440 Hz tone at amplitude 0.5 has RMS 0.354; resampling must keep the level
        #expect(abs(rms(Array(samples.dropFirst(800))) - 0.354) < 0.03)
    }

    @Test func aToneKeepsItsFrequency() {
        let samples = convertInChunks(sampleRate: 48_000, channels: 2, seconds: 1)
        var crossings = 0
        for i in 1 ..< samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
        #expect(abs(crossings - 440) <= 6, "counted \(crossings) rising zero crossings")
    }

    @Test func invalidFormatsAreRejected() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        #expect(AudioResampler16k(inputFormat: format) != nil)
    }
}

@Suite("AudioFileLoader")
struct AudioFileLoaderTests {
    @Test func loadsAWrittenFileAtSixteenKilohertz() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0 ..< 2 { for i in 0 ..< Int(frames) { buffer.floatChannelData![channel][i] = 0.4 * Float(sin(2 * .pi * 300 * Double(i) / 44_100)) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do { // the writer finalises the WAV header when it is released, so it must not outlive this block
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }

        let samples = try AudioFileLoader.load(url)
        #expect(abs(samples.count - 16_000) < 300, "got \(samples.count) samples")
        #expect(abs(rms(Array(samples.dropFirst(400))) - 0.283) < 0.03)
    }

    @Test func aMissingFileIsAnError() {
        #expect(throws: AudioFileLoader.LoadError.self) { try AudioFileLoader.load(URL(fileURLWithPath: "/nonexistent/x.wav")) }
    }
}
