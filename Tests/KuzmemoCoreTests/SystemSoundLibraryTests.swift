import Foundation
import Testing
@testable import KuzmemoCore

/// A pretend system sounds folder and a pretend person's sounds folder, in a folder of their own.
private struct Folders {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-sounds-\(UUID().uuidString)")
    var system: URL { root.appendingPathComponent("System", isDirectory: true) }
    var user: URL { root.appendingPathComponent("Library/Sounds", isDirectory: true) }
    var library: SystemSoundLibrary { SystemSoundLibrary(systemDirectory: system, userDirectory: user) }

    init(sounds: [String: String] = ["Tink": "tink-bytes", "Hero": "hero-bytes"]) throws {
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        for (name, content) in sounds { try Data(content.utf8).write(to: system.appendingPathComponent("\(name).aiff")) }
        try Data("not a sound".utf8).write(to: system.appendingPathComponent("README.txt"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func userFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: user.path)) ?? []).sorted() }
}

@Suite("System sounds as notification sounds")
struct SystemSoundLibraryTests {
    @Test func theNamesAreTheSystemsOwnAiffFiles() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(folders.library.names == ["Hero", "Tink"]) // the README is not a sound
    }

    @Test func aSoundIsCopiedIntoThePersonsFolderTheFirstTimeItIsNeeded() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(!FileManager.default.fileExists(atPath: folders.user.path)) // not even the folder is there yet
        #expect(folders.library.notificationFileName(for: "Tink") == "Kuzmemo Tink.aiff")
        #expect(folders.userFiles() == ["Kuzmemo Tink.aiff"]) // only the one that was asked for, and no half-made leftover
        let copy = try String(contentsOf: folders.user.appendingPathComponent("Kuzmemo Tink.aiff"), encoding: .utf8)
        #expect(copy == "tink-bytes")
    }

    @Test func aSoundThatIsThereAlreadyIsLeftAlone() throws {
        let folders = try Folders()
        defer { folders.remove() }
        _ = folders.library.notificationFileName(for: "Tink")
        let copy = folders.user.appendingPathComponent("Kuzmemo Tink.aiff")
        try Data("edited".utf8).write(to: copy)
        #expect(folders.library.notificationFileName(for: "Tink") == "Kuzmemo Tink.aiff")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "edited")
    }

    @Test func aLeftoverOfAnInterruptedCopyIsReplaced() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try FileManager.default.createDirectory(at: folders.user, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: folders.user.appendingPathComponent("Kuzmemo Hero.aiff.part"))
        #expect(folders.library.notificationFileName(for: "Hero") == "Kuzmemo Hero.aiff")
        #expect(folders.userFiles() == ["Kuzmemo Hero.aiff"])
        #expect(try String(contentsOf: folders.user.appendingPathComponent("Kuzmemo Hero.aiff"), encoding: .utf8) == "hero-bytes")
    }

    @Test func planningWritesNothing() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(folders.library.notificationFileName(for: "Hero", copy: false) == "Kuzmemo Hero.aiff")
        #expect(!FileManager.default.fileExists(atPath: folders.user.path))
        #expect(folders.library.notificationFileName(for: "Nope", copy: false) == nil)
    }

    @Test func aNameThatTheSystemDoesNotListIsNeverUsed() throws {
        let folders = try Folders()
        defer { folders.remove() }
        try Data("secret".utf8).write(to: folders.root.appendingPathComponent("outside.aiff"))
        for name in ["Missing", "../outside", "../../etc/passwd", "", "Tink.aiff", "tink"] {
            #expect(folders.library.notificationFileName(for: name) == nil, "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: folders.user.path)) // nothing was written for any of them
    }

    @Test func aCopyThatCannotBeMadeIsNoSound() throws {
        let folders = try Folders()
        defer { folders.remove() }
        // the person's "Sounds" is a file, so there is no folder to put a copy in
        try FileManager.default.createDirectory(at: folders.user.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: folders.user)
        #expect(folders.library.notificationFileName(for: "Tink") == nil)
    }

    @Test func theFileNameOfACopyCarriesTheAppsName() {
        #expect(SystemSoundLibrary.installedFileName(for: "Glass") == "Kuzmemo Glass.aiff")
    }

    /// Every Mac has these (the defaults of the notification settings are among them), and they are the real thing.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Library/Sounds/Tink.aiff")))
    func theRealSystemFolderHasTheSoundsTheDefaultsUse() throws {
        let real = SystemSoundLibrary()
        let defaults = NotificationSettings()
        for sound in [defaults.headsUpSound, defaults.atTimeSound, defaults.allDaySound] where sound.kind == .system {
            #expect(real.names.contains(sound.name), "\(sound.name)")
        }
        let folders = try Folders()
        defer { folders.remove() }
        let scratch = SystemSoundLibrary(systemDirectory: real.systemDirectory, userDirectory: folders.user)
        #expect(scratch.notificationFileName(for: "Tink") == "Kuzmemo Tink.aiff")
        let size = try FileManager.default.attributesOfItem(atPath: folders.user.appendingPathComponent("Kuzmemo Tink.aiff").path)[.size] as? Int
        #expect((size ?? 0) > 1000)
    }
}
