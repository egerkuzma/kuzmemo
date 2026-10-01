import AVFoundation

/// Loads any audio file the system can read into 16 kHz mono Float32 samples (used by the dev control
/// channel to feed recordings through the same path as the microphone).
public enum AudioFileLoader {
    public enum LoadError: Error, Equatable {
        case unreadable(String)
    }

    public static func load(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw LoadError.unreadable("\(error)") }
        let format = file.processingFormat
        guard let resampler = AudioResampler16k(inputFormat: format) else { throw LoadError.unreadable("unsupported format \(format)") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * 16_000 / format.sampleRate) + 1024)
        let chunk: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            let count = min(chunk, AVAudioFrameCount(file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            do { try file.read(into: buffer, frameCount: count) } catch { throw LoadError.unreadable("\(error)") }
            guard buffer.frameLength > 0 else { break } // a file shorter than its header says: stop instead of waiting for frames that never come
            samples += resampler.convert(buffer)
        }
        samples += resampler.finish()
        return samples
    }
}
