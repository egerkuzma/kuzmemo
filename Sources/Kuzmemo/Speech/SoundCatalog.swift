import AVFoundation
import AppKit
import KuzmemoCore

/// The sounds an alert can use, where their files are, and playing them for a preview.
///
/// Three kinds: the app's own chimes (`Kuzmemo-<id>.wav`, bundled), macOS system sounds (copied into the bundle as
/// `System-<Name>.aiff` when the app is built, so that the notification system can find them by file name), and a file
/// the person chose (copied to `~/Library/Sounds`, the other place the notification system looks in).
enum SoundCatalog {
    struct Chime: Identifiable, Equatable {
        var id: String
        var title: String
    }

    /// The app's own chimes. Computed, not stored: the titles must follow the interface language when it changes.
    static var chimes: [Chime] { [
        Chime(id: "bell", title: tr("Bell")), Chime(id: "drop", title: tr("Drop")), Chime(id: "gong", title: tr("Soft gong")),
        Chime(id: "marimba", title: tr("Marimba")), Chime(id: "sonar", title: tr("Sonar")), Chime(id: "glass", title: tr("Glass chime")),
        Chime(id: "melody", title: tr("Rising melody")), Chime(id: "soft", title: tr("Soft signal")),
    ] }

    static let systemDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    static var userSoundsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// Names of the macOS system sounds ("Glass", "Hero", …).
    static var systemSoundNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: systemDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    static func title(for sound: AlertSound) -> String {
        switch sound.kind {
        case .none: tr("No sound")
        case .chime: chimes.first { $0.id == sound.name }?.title ?? sound.name
        case .system: tr("System: %1$@", "\(sound.name)")
        case .file: tr("Custom: %1$@", "\(URL(fileURLWithPath: sound.name).deletingPathExtension().lastPathComponent)")
        }
    }

    /// The file to play for a preview.
    static func fileURL(for sound: AlertSound) -> URL? {
        switch sound.kind {
        case .none: return nil
        case .chime: return Bundle.main.url(forResource: "Kuzmemo-\(sound.name)", withExtension: "wav")
        case .system: return systemDirectory.appendingPathComponent("\(sound.name).aiff")
        case .file: return URL(fileURLWithPath: sound.name)
        }
    }

    /// The file name the notification system should be given (it looks in the app bundle and in `~/Library/Sounds`),
    /// or `nil` for no sound.
    static func notificationSoundName(for sound: AlertSound) -> String? {
        switch sound.kind {
        case .none: return nil
        case .chime: return Bundle.main.url(forResource: "Kuzmemo-\(sound.name)", withExtension: "wav") == nil ? nil : "Kuzmemo-\(sound.name).wav"
        case .system:
            if Bundle.main.url(forResource: "System-\(sound.name)", withExtension: "aiff") != nil { return "System-\(sound.name).aiff" }
            return "\(sound.name).aiff" // not bundled (a build without the script): let the system try its own folder
        case .file:
            let url = URL(fileURLWithPath: sound.name)
            return url.deletingLastPathComponent().standardizedFileURL == userSoundsDirectory.standardizedFileURL ? url.lastPathComponent : nil
        }
    }

    // MARK: Preview

    private static var player: NSSound?

    static func preview(_ sound: AlertSound) {
        stopPreview()
        guard !AppPaths.isAutomation else { return } // the automation build never makes a sound
        guard let url = fileURL(for: sound), let next = NSSound(contentsOf: url, byReference: true) else { return }
        player = next
        next.play()
    }

    static func stopPreview() {
        player?.stop()
        player = nil
    }

    // MARK: A file of the person's own

    enum ImportError: Error, LocalizedError {
        case unreadable, tooLong(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: tr("Could not read the sound file.")
            case let .tooLong(seconds): tr("The sound is longer than 30 seconds (%1$lld s): the system does not play such sounds in notifications.", numbers: seconds)
            }
        }
    }

    /// Copies (and, if needed, converts) the file into `~/Library/Sounds` where the notification system can play it.
    static func importFile(_ url: URL) throws -> AlertSound {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ImportError.unreadable }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        guard seconds <= 30 else { throw ImportError.tooLong(Int(seconds)) }
        try FileManager.default.createDirectory(at: userSoundsDirectory, withIntermediateDirectories: true)
        let base = "Kuzmemo " + url.deletingPathExtension().lastPathComponent
        let native = ["aiff", "aif", "wav", "caf"].contains(url.pathExtension.lowercased())
        let target = userSoundsDirectory.appendingPathComponent(base + (native ? ".\(url.pathExtension.lowercased())" : ".caf"))
        try? FileManager.default.removeItem(at: target)
        if native {
            try FileManager.default.copyItem(at: url, to: target)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "caff", "-d", "LEI16", url.path, target.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ImportError.unreadable }
        }
        return .file(target.path)
    }
}
