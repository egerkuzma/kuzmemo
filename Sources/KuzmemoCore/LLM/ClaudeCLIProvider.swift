import Foundation

/// Which flags the installed `claude` understands, read from `claude --help`. The CLI updates itself
/// silently, so the app builds its argument list from what actually exists instead of assuming.
public struct ClaudeCapabilities: Sendable, Equatable {
    public let flags: Set<String>

    public init(helpText: String) {
        var found = Set<String>()
        let scanner = helpText as NSString
        if let regex = try? NSRegularExpression(pattern: #"(?<![\w-])--[A-Za-z][A-Za-z0-9-]*"#) {
            for match in regex.matches(in: helpText, range: NSRange(location: 0, length: scanner.length)) {
                found.insert(scanner.substring(with: match.range))
            }
        }
        flags = found
    }

    public init(flags: Set<String>) { self.flags = flags }

    public func supports(_ flag: String) -> Bool { flags.contains(flag) }
}

public enum ClaudeEnvironment {
    /// Environment for the child process: no inherited session markers or API keys (so a stray
    /// `ANTHROPIC_API_KEY` cannot silently switch billing), quiet networking (halves the latency), and a PATH
    /// that also works when the app was launched from Finder.
    public static func childEnvironment(base: [String: String], quiet: Bool = true) -> [String: String] {
        var env = base.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_"))
        }
        if quiet {
            env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            env["DISABLE_TELEMETRY"] = "1"
        }
        let home = env["HOME"] ?? NSHomeDirectory()
        let extras = ["\(home)/.local/bin", "\(home)/homebrew/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (existing + extras).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}

public struct ClaudeCLIConfiguration: Sendable {
    /// Explicit path from Settings; `nil` searches `searchPaths`.
    public var executable: URL?
    public var searchPaths: [String]
    /// An empty folder, so no project hooks, `.mcp.json` or CLAUDE.md are ever picked up.
    public var workingDirectory: URL
    public var baseEnvironment: [String: String]
    public var quietEnvironment: Bool

    public init(
        executable: URL? = nil,
        searchPaths: [String] = ClaudeCLIConfiguration.defaultSearchPaths(),
        workingDirectory: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        quietEnvironment: Bool = true
    ) {
        self.executable = executable
        self.searchPaths = searchPaths
        self.workingDirectory = workingDirectory
        self.baseEnvironment = baseEnvironment
        self.quietEnvironment = quietEnvironment
    }

    public static func defaultSearchPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin/claude", "\(home)/homebrew/bin/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.claude/local/claude",
        ]
    }
}

public enum ClaudeAuthStatus: Sendable, Equatable {
    case loggedIn(method: String?)
    case loggedOut
    case unknown(String)
}

/// Runs `claude -p` as a subprocess and returns its structured answer.
public actor ClaudeCLIProvider: LLMProvider {
    public let configuration: ClaudeCLIConfiguration
    private var capabilityCache: [String: ClaudeCapabilities] = [:]

    public init(configuration: ClaudeCLIConfiguration) {
        self.configuration = configuration
    }

    // MARK: - LLMProvider

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let executable = try resolveExecutable()
        try prepareWorkingDirectory()
        let capabilities = try await capabilities(for: executable)
        let arguments = try Self.arguments(for: request, capabilities: capabilities)

        let result = try await ProcessRunner.run(
            executable: executable, arguments: arguments, stdin: Data(request.userMessage.utf8),
            environment: environment(), workingDirectory: configuration.workingDirectory, timeout: request.timeout
        )
        try Task.checkCancellation()
        if result.timedOut { throw LLMError.timedOut(seconds: request.timeout) }

        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        guard let envelope = ClaudeEnvelope(parsing: stdoutText) else {
            if result.exitCode != 0 || result.killedBySignal {
                throw LLMError.processFailed(exitCode: result.exitCode, stderr: Self.tail(result.stderr))
            }
            throw LLMError.invalidEnvelope(String(stdoutText.prefix(300)))
        }
        if envelope.isError { throw Self.classify(envelope.result ?? "") }
        guard let json = envelope.structuredJSON else { throw LLMError.missingStructuredOutput }
        return LLMResponse(
            structuredJSON: json, rawEnvelope: stdoutText, model: request.model,
            wallMs: Int(result.wallSeconds * 1000), reportedMs: envelope.durationMs,
            usageJSON: envelope.usageJSON, costUSD: envelope.costUSD
        )
    }

    // MARK: - Environment probing

    public func resolvedExecutable() throws -> URL { try resolveExecutable() }

    public func capabilities() async throws -> ClaudeCapabilities {
        try await capabilities(for: resolveExecutable())
    }

    /// `claude auth status`, used by Settings and the not-logged-in banner.
    public func authStatus() async -> ClaudeAuthStatus {
        do {
            let executable = try resolveExecutable()
            try prepareWorkingDirectory()
            let result = try await ProcessRunner.run(
                executable: executable, arguments: ["auth", "status"], stdin: nil,
                environment: environment(), workingDirectory: configuration.workingDirectory, timeout: 15
            )
            let text = String(decoding: result.stdout, as: UTF8.self)
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unknown(String(text.prefix(200)))
            }
            if object["loggedIn"] as? Bool == true { return .loggedIn(method: object["authMethod"] as? String) }
            return .loggedOut
        } catch {
            return .unknown("\(error)")
        }
    }

    // MARK: - Internals

    /// The child always starts in an empty folder of its own; it must exist before any launch, including the
    /// `--help` and `auth status` probes.
    private func prepareWorkingDirectory() throws {
        try FileManager.default.createDirectory(at: configuration.workingDirectory, withIntermediateDirectories: true)
    }

    private func environment() -> [String: String] {
        ClaudeEnvironment.childEnvironment(base: configuration.baseEnvironment, quiet: configuration.quietEnvironment)
    }

    private func resolveExecutable() throws -> URL {
        if let explicit = configuration.executable {
            guard FileManager.default.isExecutableFile(atPath: explicit.path) else {
                throw LLMError.executableNotFound(searched: [explicit.path])
            }
            return explicit
        }
        for path in configuration.searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw LLMError.executableNotFound(searched: configuration.searchPaths)
    }

    private func capabilities(for executable: URL) async throws -> ClaudeCapabilities {
        // The path usually is a symlink into a versioned folder, so a silent update changes the key.
        let key = executable.resolvingSymlinksInPath().path
        if let cached = capabilityCache[key] { return cached }
        try prepareWorkingDirectory()
        let result = try await ProcessRunner.run(
            executable: executable, arguments: ["--help"], stdin: nil, environment: environment(),
            workingDirectory: configuration.workingDirectory, timeout: 15
        )
        // A probe that failed says nothing about the CLI, and remembering it would shut the app out until it restarts: a cold
        // start after a silent update, or a wake from sleep, can make `--help` slow. These errors are transient (the memo is
        // tried again); the answer is remembered only when the CLI really described itself.
        if result.timedOut { throw LLMError.timedOut(seconds: 15) }
        if result.exitCode != 0 || result.killedBySignal {
            throw LLMError.processFailed(exitCode: result.exitCode, stderr: Self.tail(result.stderr))
        }
        let capabilities = ClaudeCapabilities(helpText: String(decoding: result.stdout + result.stderr, as: UTF8.self))
        guard !capabilities.flags.isEmpty else { throw LLMError.invalidEnvelope("`claude --help` listed no options") }
        capabilityCache[key] = capabilities
        return capabilities
    }

    /// The argument list, built only from flags the installed CLI supports. The prompt travels on stdin.
    static func arguments(for request: LLMRequest, capabilities: ClaudeCapabilities) throws -> [String] {
        // The model reads text the person (or a title in the calendar) controls, so it runs with no tools and without the
        // user's customizations. If a CLI update renames either flag, the call is refused and the phrase waits: dropping the
        // flag would leave the model with the default tools, hooks and MCP servers.
        let required = ["--output-format", "--json-schema", "--system-prompt", "--model", "--safe-mode", "--tools"]
        let missing = required.filter { !capabilities.supports($0) }
        guard missing.isEmpty else { throw LLMError.unsupportedCLI(missing: missing) }

        var args = ["-p", "--output-format", "json", "--safe-mode"]
        if capabilities.supports("--no-session-persistence") { args.append("--no-session-persistence") }
        args += ["--tools", ""]
        if capabilities.supports("--strict-mcp-config") { args.append("--strict-mcp-config") }
        args += ["--model", request.model]
        if let effort = request.effort, capabilities.supports("--effort"), !request.model.lowercased().contains("haiku") {
            args += ["--effort", effort]
        }
        args += ["--json-schema", request.schema, "--system-prompt", request.systemPrompt]
        return args
    }

    static func classify(_ message: String) -> LLMError {
        let lower = message.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("invalid api key") {
            return .notLoggedIn
        }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("limit reached") || lower.contains("quota") {
            return .rateLimited(message)
        }
        return .apiError(message)
    }

    static func tail(_ data: Data, limit: Int = 400) -> String {
        String(String(decoding: data, as: UTF8.self).suffix(limit))
    }
}

/// The JSON object `claude -p --output-format json` prints.
struct ClaudeEnvelope {
    var isError: Bool
    var result: String?
    var structuredJSON: String?
    var durationMs: Int?
    var costUSD: Double?
    var usageJSON: String?

    init?(parsing text: String) {
        // stdout should be a single JSON object; tolerate stray lines before it.
        let candidates = [text] + text.split(separator: "\n").reversed().map(String.init).filter { $0.hasPrefix("{") }
        guard let object = candidates.lazy.compactMap({ candidate -> [String: Any]? in
            (candidate.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }).first else { return nil }

        isError = object["is_error"] as? Bool ?? false
        result = object["result"] as? String
        durationMs = object["duration_ms"] as? Int
        costUSD = object["total_cost_usd"] as? Double
        usageJSON = ClaudeEnvelope.serialize(object["usage"])
        if let structured = object["structured_output"], !(structured is NSNull) {
            structuredJSON = ClaudeEnvelope.serialize(structured)
        } else if let result, let data = result.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data), parsed is [String: Any] {
            structuredJSON = result
        }
    }

    private static func serialize(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
