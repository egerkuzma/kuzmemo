import CryptoKit
import Foundation

/// Lines of speech the engine has made, kept on disk so that a phrase it has said before ("Готово.", "Ничего не
/// запланировано", a repeating entry read out every morning) is played at once instead of after a few seconds of work.
///
/// A line sounds the way it does because of the voice sample, the number of steps and the language, so those are part of
/// its name: changing the sample or the quality never plays something made with the old ones. The folder is trimmed to a
/// size, the least recently played lines first.
public struct OmniVoiceCache: Sendable {
    /// What a line's sound depends on besides its words.
    public struct Voice: Equatable, Sendable {
        public var fingerprint: String
        public var steps: Int
        public var language: String

        public init(fingerprint: String, steps: Int, language: String) {
            self.fingerprint = fingerprint
            self.steps = steps
            self.language = language
        }
    }

    public let directory: URL
    public var maxBytes: Int

    public init(directory: URL, maxBytes: Int = 150 << 20) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// A short name for a voice sample: it changes when the recording's codes or the words said in it change. `nil` when
    /// there is no voice.
    public static func fingerprint(of locator: OmniVoiceLocator) -> String? {
        guard let codes = try? Data(contentsOf: locator.referenceCodes), let words = try? Data(contentsOf: locator.referenceText) else { return nil }
        var hash = SHA256()
        hash.update(data: codes)
        hash.update(data: Data([0]))
        hash.update(data: words)
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func file(for line: String, voice: Voice) -> URL {
        let key = "v1|\(voice.fingerprint)|\(voice.steps)|\(voice.language)|\(line)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".wav")
    }

    /// The made line, or `nil` when there is none (or the file is damaged, which is then removed).
    public func segment(for line: String, voice: Voice) -> SpokenSegment? {
        let url = file(for: line, voice: voice)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let segment = SpokenSegment(wav: data), segment.seconds > 0.2 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) // played just now
        return segment
    }

    public func store(_ segment: SpokenSegment, for line: String, voice: Voice) {
        guard segment.seconds > 0.2 else { return }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(for: line, voice: voice)
        let partial = url.appendingPathExtension("partial")
        do {
            try segment.wav.write(to: partial)
            _ = try? files.removeItem(at: url)
            try files.moveItem(at: partial, to: url)
        } catch {
            try? files.removeItem(at: partial)
        }
    }

    /// Removes the oldest lines until the folder fits in `maxBytes`.
    public func prune() {
        let files = FileManager.default
        guard let urls = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            guard url.pathExtension == "wav" || url.pathExtension == "partial",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > maxBytes {
            try? files.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Forgets every line (the voice was replaced or removed).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
