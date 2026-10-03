import Foundation

/// A folder of raw recordings (16 kHz mono Float32) that have not been transcribed yet. A recording lives here
/// only until its transcript is stored, so a phrase survives a crash or a missing speech model but audio is
/// never kept for long.
public struct AudioSpool: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes the samples atomically and returns the file's path.
    public func write(_ samples: [Float], name: String) throws -> String {
        try PrivateFiles.directory(directory)
        let url = directory.appendingPathComponent("\(name).f32")
        let data = samples.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
        try PrivateFiles.file(url)
        return url.path
    }

    public func read(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public func remove(path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Paths of the recordings in the spool that were written more than `age` seconds ago.
    public func files(olderThan age: TimeInterval = 0) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        return urls.filter { url in
            guard url.pathExtension == "f32" else { return false }
            let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return modified <= cutoff
        }.map(\.path)
    }
}
