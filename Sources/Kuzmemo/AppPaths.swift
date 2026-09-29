import Foundation

/// Where the app keeps its data. There are two bundles with separate folders, so that nothing the scripts do can
/// touch the person's entries: the daily app (`app.kuzmemo`), and the dev bundle (`app.kuzmemo.dev`), which is the
/// automation build: control socket on, muted, no reaction to physical keys, never opens the real microphone by
/// itself. `KUZMEMO_DATA_DIR` overrides the location entirely.
struct AppPaths {
    let support: URL
    let isDev: Bool

    var database: URL { support.appendingPathComponent("kuzmemo.sqlite") }
    /// Copies of the database (see `BackupService`).
    var backups: URL { support.appendingPathComponent("backups", isDirectory: true) }
    var claudeWorkingDirectory: URL { support.appendingPathComponent("claude-cwd", isDirectory: true) }
    var runDirectory: URL { support.appendingPathComponent("run", isDirectory: true) }
    var controlSocket: URL { runDirectory.appendingPathComponent("control.sock") }
    /// Recordings waiting to be transcribed (deleted as soon as their text is stored).
    var audioSpool: URL { support.appendingPathComponent("spool", isDirectory: true) }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    /// Phrases made by the Silero voice, deleted as soon as they have been played.
    var speechCache: URL { support.appendingPathComponent("speech-cache", isDirectory: true) }
    /// The person's own voice for the "My voice" engine: the sample, its codes and the words said in it. The program and
    /// its weights are shared by both bundles (`OmniVoiceLocator.engineDirectory`); the voice is this bundle's own.
    var voice: URL { support.appendingPathComponent("voice", isDirectory: true) }
    /// Lines the "My voice" engine has already made, kept so that a repeated phrase is played at once.
    var voiceCache: URL { support.appendingPathComponent("voice-cache", isDirectory: true) }

    static func resolve() -> AppPaths {
        let environment = ProcessInfo.processInfo.environment
        let bundleID = Bundle.main.bundleIdentifier ?? "app.kuzmemo"
        let isDev = bundleID.hasSuffix(".dev")
        let base: URL
        if let override = environment["KUZMEMO_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(isDev ? "Kuzmemo-Dev" : "Kuzmemo", isDirectory: true)
        }
        return AppPaths(support: base, isDev: isDev)
    }

    /// Scripts drive this build (the dev bundle): it must stay silent, must not react to the person's keys and must
    /// not open the real microphone by itself.
    static var isAutomation: Bool {
        if ProcessInfo.processInfo.environment["KUZMEMO_AUTOMATION"] == "1" { return true }
        return (Bundle.main.object(forInfoDictionaryKey: "KuzmemoAutomation") as? Bool) ?? false
    }

    /// The control channel is compiled into every build but only listens when asked (dev bundle or env).
    static var controlEnabled: Bool {
        if ProcessInfo.processInfo.environment["KUZMEMO_CONTROL"] == "1" { return true }
        return (Bundle.main.object(forInfoDictionaryKey: "KuzmemoControlEnabled") as? Bool) ?? false
    }
}
