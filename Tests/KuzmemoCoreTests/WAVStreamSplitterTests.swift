import Foundation
import Testing
@testable import KuzmemoCore

@Suite("The stream of the My voice engine")
struct WAVStreamSplitterTests {
    /// The header `omnivoice-tts -o -` writes: sizes say "unknown".
    private func header(rate: Int = 24000, channels: Int = 1, bits: Int = 16) -> Data {
        var out = Data(Array("RIFF".utf8))
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put32(0x7FFF_FFFF)
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16)
        put16(1)
        put16(UInt16(channels))
        put32(UInt32(rate))
        put32(UInt32(rate * channels * bits / 8))
        put16(UInt16(channels * bits / 8))
        put16(UInt16(bits))
        out.append(contentsOf: Array("data".utf8))
        put32(0x7FFF_FFFF)
        return out
    }

    private func samples(_ count: Int, seed: UInt8) -> Data {
        Data((0 ..< count * 2).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 * 7) })
    }

    @Test func aLineIsHandedOutWhenTheNextHeaderAppearsAndTheLastOneAtTheEnd() {
        var splitter = WAVStreamSplitter()
        let one = samples(1000, seed: 1), two = samples(2500, seed: 2)
        #expect(splitter.feed(header() + one).isEmpty) // nothing yet: this line might still grow
        let first = splitter.feed(header() + two)
        #expect(first.count == 1 && first[0].pcm == one && first[0].sampleRate == 24000)
        let last = splitter.finish()
        #expect(last.count == 1 && last[0].pcm == two)
        #expect(splitter.finish().isEmpty)
    }

    @Test func theSameResultWhateverTheChunking() {
        let all = header() + samples(700, seed: 3) + header() + samples(1300, seed: 4) + header() + samples(50, seed: 5)
        for size in [1, 2, 3, 7, 44, 45, 1000, all.count] {
            var splitter = WAVStreamSplitter()
            var segments: [SpokenSegment] = []
            var index = 0
            while index < all.count {
                let end = min(index + size, all.count)
                segments += splitter.feed(all[index ..< end])
                index = end
            }
            segments += splitter.finish()
            #expect(segments.map(\.pcm.count) == [1400, 2600, 100], "chunk size \(size)")
            #expect(segments[0].pcm == samples(700, seed: 3) && segments[2].pcm == samples(50, seed: 5), "chunk size \(size)")
        }
    }

    @Test func aSegmentBecomesAnOrdinaryWavFile() throws {
        let segment = SpokenSegment(sampleRate: 24000, pcm: samples(480, seed: 9))
        let wav = segment.wav
        #expect(wav.count == 44 + 960)
        #expect(String(decoding: wav[0 ..< 4], as: UTF8.self) == "RIFF" && String(decoding: wav[8 ..< 16], as: UTF8.self) == "WAVEfmt ")
        func u32(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 | Int(wav[at + 2]) << 16 | Int(wav[at + 3]) << 24 }
        #expect(u32(4) == 36 + 960) // true sizes, not "unknown"
        #expect(u32(24) == 24000 && u32(28) == 48000 && u32(40) == 960)
        #expect(wav.suffix(960) == segment.pcm)
        #expect(abs(segment.seconds - 0.02) < 1e-9)
    }

    @Test func audioBytesThatLookLikeTheStartOfAHeaderAreNotOne() {
        // "RIFF" inside the samples, but not followed by "WAVE" eight bytes later
        let tricky = Data(Array("RIFF".utf8)) + Data(repeating: 0x11, count: 40) + samples(200, seed: 6)
        var splitter = WAVStreamSplitter()
        var segments = splitter.feed(header() + tricky)
        segments += splitter.finish()
        #expect(segments.count == 1 && segments[0].pcm == tricky)
    }

    @Test func junkBeforeTheFirstHeaderAndAHeaderCutOffAtTheEndAreIgnored() {
        var splitter = WAVStreamSplitter()
        var segments = splitter.feed(Data("warming up…\n".utf8) + header() + samples(300, seed: 7) + header().prefix(30))
        segments += splitter.finish()
        // the cut-off header ends the line before it (which stays whole); it is not a complete header, so it is no line
        #expect(segments.count == 1 && segments[0].pcm.count == 600)
        var empty = WAVStreamSplitter()
        #expect(empty.feed(Data()).isEmpty && empty.finish().isEmpty)
    }

    /// Nothing is played from a stream that is not mono 16-bit, but the line keeps its place as an empty segment.
    @Test func aStreamThatIsNotMonoSixteenBitIsNotPlayedButKeepsItsPlace() {
        var splitter = WAVStreamSplitter()
        var segments = splitter.feed(header(channels: 2) + samples(300, seed: 8))
        segments += splitter.finish()
        #expect(segments.count == 1 && segments[0].pcm.isEmpty)
        var other = WAVStreamSplitter()
        var eight = other.feed(header(bits: 8) + samples(300, seed: 8))
        eight += other.finish()
        #expect(eight.count == 1 && eight[0].pcm.isEmpty)
    }

    /// Whoever pairs the segments with the sentences by position needs the k-th segment to be the k-th line: a line that made
    /// no sound used to be dropped, which moved every later sentence under the sound of the one before it.
    @Test func aLineThatMadeNoSoundKeepsItsPlace() {
        var splitter = WAVStreamSplitter()
        var segments = splitter.feed(header() + samples(100, seed: 1) + header() + header() + samples(50, seed: 2) + header())
        segments += splitter.finish()
        #expect(segments.map(\.pcm.count) == [200, 0, 100, 0]) // the last header is a line that has no samples yet
        #expect(segments[1].pcm.isEmpty && segments[1].seconds == 0)
        // whatever the chunking, the places are the same
        let all = header() + samples(10, seed: 1) + header() + header(channels: 2) + samples(10, seed: 3) + header() + samples(5, seed: 4)
        for size in [1, 5, 44, all.count] {
            var chunked = WAVStreamSplitter()
            var got: [SpokenSegment] = []
            var index = 0
            while index < all.count {
                let end = min(index + size, all.count)
                got += chunked.feed(all[index ..< end])
                index = end
            }
            got += chunked.finish()
            #expect(got.map(\.pcm.count) == [20, 0, 0, 10], "chunk size \(size)")
        }
    }
}
