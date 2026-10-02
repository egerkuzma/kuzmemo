import AVFoundation
import AppKit
import KuzmemoCore

/// The sounds an alert can use, where their files are, and playing them for a preview.
///
/// Three kinds: the app's own chimes (`Kuzmemo-<id>.wav`, bundled), macOS system sounds (not shipped, they are Apple's: the
/// one in use is copied from the system's folder into `~/Library/Sounds` on the person's Mac, see `SystemSoundLibrary`), and a
/// file the person chose (copied to `~/Library/Sounds` as well). The notification system finds a sound by file name in the app
/// bundle and in that folder, and nowhere else.
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

    private static let systemSounds = SystemSoundLibrary()
    static var systemDirectory: URL { systemSounds.systemDirectory }
    static var userSoundsDirectory: URL { systemSounds.userDirectory }

    /// Names of the macOS system sounds ("Glass", "Hero", …).
    static var systemSoundNames: [String] { systemSounds.names }

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
            // Copied into the person's sounds folder when first needed. The automation build only plans: it never writes to the
            // person's folders. Nil (no such sound, no copy) falls back to the default alert sound.
            return systemSounds.notificationFileName(for: sound.name, copy: !AppPaths.isAutomation)
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
