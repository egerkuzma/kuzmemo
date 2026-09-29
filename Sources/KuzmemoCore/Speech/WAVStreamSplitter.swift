import Foundation

/// One spoken line as the "My voice" engine renders it: 16-bit mono samples at the engine's rate.
public struct SpokenSegment: Equatable, Sendable {
    public var sampleRate: Int
    /// Signed 16-bit little-endian samples, one channel.
    public var pcm: Data

    public init(sampleRate: Int, pcm: Data) {
        self.sampleRate = sampleRate
        self.pcm = pcm
    }

    /// The samples of a mono 16-bit WAV file (one this type wrote, or any other plain one); `nil` for anything else.
    public init?(wav: Data) {
        guard let info = try? WAVInfo(data: wav), info.channels == 1, info.bitsPerSample == 16, info.dataBytes >= 2 else { return nil }
        let start = wav.startIndex + info.dataOffset
        self.init(sampleRate: info.sampleRate, pcm: Data(wav[start ..< start + info.dataBytes - info.dataBytes % 2]))
    }

    public var seconds: Double { Double(pcm.count / 2) / Double(max(sampleRate, 1)) }

    /// A complete WAV file with true sizes in its header, which a player can open (the stream's own headers say "length
    /// unknown").
    public var wav: Data {
        var out = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16)
        put16(1) // PCM
        put16(1) // mono
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))
        put16(2)
        put16(16)
        out.append(contentsOf: Array("data".utf8))
        put32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}

/// Splits the bytes that `omnivoice-tts -o - --stream-by-line` writes into one segment per line.
///
/// Every line of text starts with its own 44-byte WAV header whose sizes say "unknown" (0x7FFFFFFF), followed by the
/// samples of that line, so the only way to find where a line ends is to see the next header: `RIFF`, four size bytes,
/// `WAVE`. A segment is handed out as soon as the next header has been seen (that happens while the following line is
/// still being made, which is what lets the first sentence be played early), and the last one at `finish()`.
public struct WAVStreamSplitter: Sendable {
    private static let headerSize = 44
    private var buffer = Data()
    private var started = false

    public init() {}

    /// Adds bytes from the stream and returns the segments that are complete now.
    public mutating func feed(_ chunk: Data) -> [SpokenSegment] {
        buffer.append(chunk)
        var done: [SpokenSegment] = []
        while let first = headerIndex(from: buffer.startIndex) {
            if !started { // whatever came before the first header is not audio
                buffer.removeSubrange(buffer.startIndex ..< first)
                started = true
                continue
            }
            guard let next = headerIndex(from: first + Self.headerSize) else { break }
            if let segment = Self.segment(header: buffer[first ..< first + Self.headerSize], samples: buffer[(first + Self.headerSize) ..< next]) {
                done.append(segment)
            }
            buffer.removeSubrange(buffer.startIndex ..< next)
        }
        return done
    }

    /// The stream has ended: the segment in progress is complete.
    public mutating func finish() -> [SpokenSegment] {
        defer { buffer = Data(); started = false }
        guard started, buffer.count >= Self.headerSize else { return [] }
        let start = buffer.startIndex
        let segment = Self.segment(header: buffer[start ..< start + Self.headerSize], samples: buffer[(start + Self.headerSize)...])
        return segment.map { [$0] } ?? []
    }

    /// The index of the next `RIFF????WAVE` at or after `from`, when all twelve bytes are in the buffer.
    private func headerIndex(from: Int) -> Int? {
        let riff = Array("RIFF".utf8), wave = Array("WAVE".utf8)
        var i = from
        while i + 12 <= buffer.endIndex {
            if buffer[i] == riff[0], buffer[i + 1] == riff[1], buffer[i + 2] == riff[2], buffer[i + 3] == riff[3],
               buffer[i + 8] == wave[0], buffer[i + 9] == wave[1], buffer[i + 10] == wave[2], buffer[i + 11] == wave[3] {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func segment(header: Data.SubSequence, samples: Data.SubSequence) -> SpokenSegment? {
        let base = header.startIndex
        // Mono 16-bit PCM is all the engine writes; anything else is not something to play.
        let channels = Int(header[base + 22]) | Int(header[base + 23]) << 8
        let bits = Int(header[base + 34]) | Int(header[base + 35]) << 8
        let rate = Int(header[base + 24]) | Int(header[base + 25]) << 8 | Int(header[base + 26]) << 16 | Int(header[base + 27]) << 24
        guard channels == 1, bits == 16, rate > 0 else { return nil }
        let even = samples.count - samples.count % 2
        guard even > 0 else { return nil }
        return SpokenSegment(sampleRate: rate, pcm: Data(samples.prefix(even)))
    }
}
