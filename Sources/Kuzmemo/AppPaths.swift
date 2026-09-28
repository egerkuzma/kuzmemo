import Foundation

/// Where the app keeps its data. The dev bundle (`app.kuzmemo.dev`) uses its own folder so automated
/// tests never touch real entries; `KUZMEMO_DATA_DIR` overrides the location entirely.
struct AppPaths {
    let support: URL
    let isDev: Bool

    var database: URL { support.appendingPathComponent("kuzmemo.sqlite") }
    var claudeWorkingDirectory: URL { support.appendingPathComponent("claude-cwd", isDirectory: true) }
    var runDirectory: URL { support.appendingPathComponent("run", isDirectory: true) }
    var controlSocket: URL { runDirectory.appendingPathComponent("control.sock") }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }

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

    /// The control channel is compiled into every build but only listens when asked (dev bundle or env).
    static var controlEnabled: Bool {
        if ProcessInfo.processInfo.environment["KUZMEMO_CONTROL"] == "1" { return true }
        return (Bundle.main.object(forInfoDictionaryKey: "KuzmemoControlEnabled") as? Bool) ?? false
    }
}
