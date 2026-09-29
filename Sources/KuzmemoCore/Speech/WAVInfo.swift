import Foundation

/// What a WAV file says about itself: enough to tell whether it can be a voice sample, and where its samples start.
public struct WAVInfo: Equatable, Sendable {
    public var channels: Int
    public var sampleRate: Int
    public var bitsPerSample: Int
    /// Bytes of samples.
    public var dataBytes: Int
    /// Where the samples start in the file.
    public var dataOffset: Int

    public var seconds: Double {
        let bytesPerSecond = sampleRate * channels * bitsPerSample / 8
        return bytesPerSecond > 0 ? Double(dataBytes) / Double(bytesPerSecond) : 0
    }

    public enum Problem: Error, Equatable, Sendable { case notAWAVFile }

    public init(channels: Int, sampleRate: Int, bitsPerSample: Int, dataBytes: Int, dataOffset: Int = 44) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.dataBytes = dataBytes
        self.dataOffset = dataOffset
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Problem.notAWAVFile }
        try self.init(data: data)
    }

    /// Reads the header of plain PCM. A length that says "unknown" (a streamed file) or is longer than the file is taken
    /// from the file.
    public init(data: Data) throws {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8), data[data.startIndex + 8 ..< data.startIndex + 12] == Data("WAVE".utf8) else {
            throw Problem.notAWAVFile
        }
        let base = data.startIndex
        func u32(_ at: Int) -> Int { Int(data[base + at]) | Int(data[base + at + 1]) << 8 | Int(data[base + at + 2]) << 16 | Int(data[base + at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(data[base + at]) | Int(data[base + at + 1]) << 8 }
        var channels = 0, rate = 0, bits = 0
        var position = 12
        while position + 8 <= data.count {
            let name = String(decoding: data[base + position ..< base + position + 4], as: UTF8.self)
            let size = u32(position + 4)
            let body = position + 8
            if name == "fmt ", body + 16 <= data.count {
                guard u16(body) == 1 else { throw Problem.notAWAVFile } // plain PCM only
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if name == "data" {
                guard channels > 0, rate > 0, bits > 0 else { throw Problem.notAWAVFile }
                self.init(channels: channels, sampleRate: rate, bitsPerSample: bits, dataBytes: min(size, data.count - body), dataOffset: body)
                return
            }
            position = body + size + size % 2
        }
        throw Problem.notAWAVFile
    }
}
