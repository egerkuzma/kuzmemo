import Foundation

/// The macOS system sounds ("Glass", "Hero", …) as sounds for notifications.
///
/// The notification system plays a sound only by the name of a file in the app's own bundle or in the person's
/// `~/Library/Sounds`; it never looks in `/System/Library/Sounds`. The files are Apple's, so they are not shipped inside the app
/// or its disk image. The one that is chosen is copied from the system's own folder on the person's Mac, once, when it is first
/// needed, and the copy is named so that it is recognisable in the system's list of alert sounds ("Kuzmemo Tink").
public struct SystemSoundLibrary: Sendable {
    public let systemDirectory: URL
    public let userDirectory: URL

    public init(
        systemDirectory: URL = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
        userDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true)
    ) {
        self.systemDirectory = systemDirectory
        self.userDirectory = userDirectory
    }

    /// Names of the sounds the system has, sorted.
    public var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: systemDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// The file a copy of the sound has in the person's sounds folder.
    public static func installedFileName(for name: String) -> String { "Kuzmemo \(name).aiff" }

    /// The file name to give the notification system for the system sound `name`, after making sure the file is there: it is
    /// copied from the system's folder when it is not. With `copy` false nothing is written (the automation build only plans).
    /// Nil when the system has no such sound (a name is only ever taken from the system's own list, never used as a path) or
    /// the copy could not be made.
    public func notificationFileName(for name: String, copy: Bool = true) -> String? {
        guard names.contains(name) else { return nil }
        let file = Self.installedFileName(for: name)
        let target = userDirectory.appendingPathComponent(file)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) || !copy { return file }
        do {
            try manager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            // Beside the target and moved into place when whole: the system must never find half a sound.
            let part = userDirectory.appendingPathComponent(file + ".part")
            try? manager.removeItem(at: part)
            try manager.copyItem(at: systemDirectory.appendingPathComponent("\(name).aiff"), to: part)
            try manager.moveItem(at: part, to: target)
            return file
        } catch {
            return nil
        }
    }
}
