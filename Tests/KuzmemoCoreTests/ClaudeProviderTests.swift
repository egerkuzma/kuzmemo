import Foundation
import Testing
@testable import KuzmemoCore

/// A stand-in for the `claude` binary: a bash script that records how it was called and prints canned output.
final class FakeClaude: @unchecked Sendable {
    static let allFlags = [
        "-p, --print", "--output-format", "--json-schema", "--system-prompt", "--model", "--effort",
        "--safe-mode", "--no-session-persistence", "--tools", "--strict-mcp-config", "--bare",
    ]

    let dir: URL
    let executable: URL

    var recordDir: URL { dir.appendingPathComponent("rec") }

    init(body: String, flags: [String] = FakeClaude.allFlags, auth: String = "echo '{\"loggedIn\":true}'", helpPrelude: String = "") throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        dir = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rec"), withIntermediateDirectories: true)
        executable = root.appendingPathComponent("claude")
        let help = flags.map { "  \($0) <value>  description" }.joined(separator: "\n")
        let script = #"""
        #!/bin/bash
        REC="$FAKE_DIR"
        if [ "$1" = "--help" ]; then
        echo x >> "$REC/help-count.txt"
        \#(helpPrelude)
        cat <<'HELP'
        Usage: claude [options] [prompt]
        \#(help)
        HELP
        exit 0
        fi
        if [ "$1" = "auth" ]; then
        \#(auth)
        exit 0
        fi
        printf '%s\0' "$@" > "$REC/args.bin"
        env > "$REC/env.txt"
        pwd > "$REC/pwd.txt"
        cat > "$REC/stdin.txt"
        \#(body)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func provider(baseEnvironment: [String: String] = [:], quiet: Bool = true) -> ClaudeCLIProvider {
        var env = baseEnvironment
        env["FAKE_DIR"] = recordDir.path
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        return ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(
            executable: executable, workingDirectory: dir.appendingPathComponent("cwd"),
            baseEnvironment: env, quietEnvironment: quiet
        ))
    }

    func read(_ name: String) -> String { (try? String(contentsOf: recordDir.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    func arguments() -> [String] {
        var parts = read("args.bin").components(separatedBy: "\0")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static let okBody = #"""
    cat <<'JSON'
    {"type":"result","subtype":"success","is_error":false,"result":"done","structured_output":{"intent":"unknown","confidence":0.9},"duration_ms":1200,"total_cost_usd":0.003,"usage":{"input_tokens":10,"output_tokens":5}}
    JSON
    """#
}

private func request(model: String = "sonnet", timeout: TimeInterval = 20, message: String = "привет") -> LLMRequest {
    LLMRequest(
        systemPrompt: "Line one \"quoted\"\nLine two with 'single' and $dollar", userMessage: message,
        schema: #"{"type":"object"}"#, model: model, effort: "low", timeout: timeout
    )
}

@Suite("ClaudeCLIProvider", .serialized)
struct ClaudeProviderTests {
    @Test func successfulCallReturnsTheStructuredAnswerAndBuildsTheExpectedCommand() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody)
        let response = try await fake.provider().complete(request(message: "напомни завтра"))

        let parsed = try JSONDecoder().decode(ParserResponse.self, from: Data(response.structuredJSON.utf8))
        #expect(parsed.intent == .unknown)
        #expect(response.model == "sonnet" && response.reportedMs == 1200 && response.costUSD == 0.003)
        #expect(response.usageJSON?.contains("\"input_tokens\":10") == true)
        #expect(response.wallMs >= 0)

        #expect(fake.arguments() == [
            "-p", "--output-format", "json", "--safe-mode", "--no-session-persistence", "--tools", "",
            "--strict-mcp-config", "--model", "sonnet", "--effort", "low", "--json-schema", #"{"type":"object"}"#,
            "--system-prompt", "Line one \"quoted\"\nLine two with 'single' and $dollar",
        ])
        #expect(fake.read("stdin.txt") == "напомни завтра")
    }

    @Test func childEnvironmentIsScrubbedAndQuiet() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody)
        let provider = fake.provider(baseEnvironment: [
            "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "sk-secret", "CLAUDE_CODE_ENTRYPOINT": "cli", "KEEP_ME": "1", "PATH": "/custom/bin",
        ])
        _ = try await provider.complete(request())
        let env = fake.read("env.txt")
        #expect(!env.contains("CLAUDECODE=") && !env.contains("ANTHROPIC_API_KEY") && !env.contains("CLAUDE_CODE_ENTRYPOINT"))
        #expect(env.contains("KEEP_ME=1"))
        #expect(env.contains("DISABLE_TELEMETRY=1"))
        #expect(env.contains("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"))
        let path = try #require(env.split(separator: "\n").first { $0.hasPrefix("PATH=") })
        #expect(path.contains("/custom/bin") && path.contains("/usr/bin"))
        let cwd = fake.read("pwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().lastPathComponent == "cwd")
    }

    @Test func quietVariablesCanBeSwitchedOff() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody)
        _ = try await fake.provider(quiet: false).complete(request())
        #expect(!fake.read("env.txt").contains("DISABLE_TELEMETRY"))
    }

    @Test func notLoggedInIsRecognisedEvenThoughTheSubtypeSaysSuccess() async throws {
        let body = #"""
        echo '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","terminal_reason":"api_error"}'
        exit 1
        """#
        let fake = try FakeClaude(body: body)
        await #expect(throws: LLMError.notLoggedIn) { try await fake.provider().complete(request()) }
    }

    @Test func rateLimitAndOtherApiErrorsAreClassified() async throws {
        let limited = try FakeClaude(body: #"echo '{"is_error":true,"result":"5-hour usage limit reached, resets at 18:00"}'; exit 1"#)
        await #expect(throws: LLMError.rateLimited("5-hour usage limit reached, resets at 18:00")) {
            try await limited.provider().complete(request())
        }
        let other = try FakeClaude(body: #"echo '{"is_error":true,"result":"Overloaded"}'; exit 1"#)
        await #expect(throws: LLMError.apiError("Overloaded")) { try await other.provider().complete(request()) }
    }

    @Test func aHungProcessIsKilledAtTheTimeout() async throws {
        let fake = try FakeClaude(body: "sleep 30")
        let started = Date()
        await #expect(throws: LLMError.timedOut(seconds: 1)) { try await fake.provider().complete(request(timeout: 1)) }
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func crashesAndGarbageBecomeDistinctErrors() async throws {
        let crash = try FakeClaude(body: "echo boom >&2; exit 3")
        await #expect(throws: LLMError.processFailed(exitCode: 3, stderr: "boom\n")) { try await crash.provider().complete(request()) }
        let garbage = try FakeClaude(body: "echo 'oops, not json'")
        await #expect(throws: LLMError.invalidEnvelope("oops, not json\n")) { try await garbage.provider().complete(request()) }
    }

    @Test func runawayOutputIsBoundedAndTheProcessStops() async throws {
        let fake = try FakeClaude(body: "head -c 10485760 /dev/zero; sleep 30")
        let started = Date()
        await #expect(throws: LLMError.processFailed(exitCode: -3, stderr: "CLI output exceeded the size limit")) {
            try await fake.provider().complete(request())
        }
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func structuredAnswerFallsBackToJSONInTheResultText() async throws {
        let body = #"""
        cat <<'JSON'
        {"type":"result","subtype":"success","is_error":false,"result":"{\"intent\":\"unknown\",\"confidence\":0.5}"}
        JSON
        """#
        let fake = try FakeClaude(body: body)
        let response = try await fake.provider().complete(request())
        let parsed = try JSONDecoder().decode(ParserResponse.self, from: Data(response.structuredJSON.utf8))
        #expect(parsed.confidence == 0.5)

        let none = try FakeClaude(body: #"echo '{"type":"result","is_error":false,"result":"just words"}'"#)
        await #expect(throws: LLMError.missingStructuredOutput) { try await none.provider().complete(request()) }
    }

    @Test func missingRequiredFlagsAreReportedAndOptionalOnesSkipped() async throws {
        let isolation = ["--safe-mode", "--tools"]
        let old = try FakeClaude(body: FakeClaude.okBody, flags: ["-p, --print", "--output-format", "--system-prompt", "--model"] + isolation)
        await #expect(throws: LLMError.unsupportedCLI(missing: ["--json-schema"])) { try await old.provider().complete(request()) }

        let minimal = try FakeClaude(
            body: FakeClaude.okBody, flags: ["-p, --print", "--output-format", "--json-schema", "--system-prompt", "--model"] + isolation
        )
        _ = try await minimal.provider().complete(request())
        let args = minimal.arguments()
        #expect(args.contains("--safe-mode") && args.contains("--tools"))
        #expect(!args.contains("--effort") && !args.contains("--no-session-persistence") && !args.contains("--strict-mcp-config"))
        #expect(args.contains("--json-schema"))
    }

    /// The model reads text that others control, so it never runs without the flags that take its tools and the user's
    /// customizations away: a CLI that stops listing one is refused (the phrase waits) rather than called without it.
    @Test func aCLIWithoutItsIsolationFlagsIsRefusedNotRunWithoutThem() async throws {
        for dropped in ["--safe-mode", "--tools"] {
            let fake = try FakeClaude(body: FakeClaude.okBody, flags: FakeClaude.allFlags.filter { $0 != dropped })
            await #expect(throws: LLMError.unsupportedCLI(missing: [dropped])) { try await fake.provider().complete(request()) }
            #expect(fake.read("args.bin").isEmpty, "the CLI was started without \(dropped)")
        }
        #expect(!LLMError.unsupportedCLI(missing: ["--tools"]).isTransient)
    }

    /// A probe that failed (it was slow, crashed, printed nothing) must not be remembered: it used to leave the app with empty
    /// capabilities, so every later phrase failed with a non-transient error until the app restarted.
    @Test func aFailedHelpProbeIsNotRemembered() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody, helpPrelude: #"if [ ! -f "$REC/probed" ]; then touch "$REC/probed"; echo "starting up" >&2; exit 7; fi"#)
        let provider = fake.provider()
        await #expect(throws: LLMError.processFailed(exitCode: 7, stderr: "starting up\n")) { try await provider.complete(request()) }
        _ = try await provider.complete(request()) // the probe is repeated, and this time it works
        #expect(fake.read("help-count.txt").split(separator: "\n").count == 2)
        _ = try await provider.complete(request())
        #expect(fake.read("help-count.txt").split(separator: "\n").count == 2) // and now it is remembered
        #expect(LLMError.processFailed(exitCode: 7, stderr: "").isTransient)
    }

    @Test func haikuNeverGetsAnEffortFlag() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody)
        _ = try await fake.provider().complete(request(model: "haiku"))
        #expect(!fake.arguments().contains("--effort"))
    }

    @Test func missingExecutableIsReportedWithTheSearchedPaths() async throws {
        let provider = ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(
            searchPaths: ["/nonexistent/one/claude", "/nonexistent/two/claude"],
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cwd-missing")
        ))
        await #expect(throws: LLMError.executableNotFound(searched: ["/nonexistent/one/claude", "/nonexistent/two/claude"])) {
            try await provider.complete(request())
        }
        let explicit = ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(
            executable: URL(fileURLWithPath: "/nonexistent/claude"),
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cwd-missing")
        ))
        await #expect(throws: LLMError.executableNotFound(searched: ["/nonexistent/claude"])) { try await explicit.complete(request()) }
    }

    @Test func searchPathsFindTheFirstExecutable() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody)
        var env = ["FAKE_DIR": fake.recordDir.path, "HOME": NSHomeDirectory()]
        env["X"] = "1"
        let provider = ClaudeCLIProvider(configuration: ClaudeCLIConfiguration(
            searchPaths: ["/nonexistent/claude", fake.executable.path], workingDirectory: fake.dir.appendingPathComponent("cwd"),
            baseEnvironment: env
        ))
        #expect(try await provider.resolvedExecutable() == URL(fileURLWithPath: fake.executable.path))
    }

    @Test func largePromptsAndLargeOutputsDoNotDeadlock() async throws {
        let body = #"""
        BYTES=$(wc -c < "$REC/stdin.txt" | tr -d ' ')
        PAD=$(head -c 1500000 /dev/zero | tr '\0' 'x')
        printf '{"type":"result","is_error":false,"structured_output":{"intent":"unknown","confidence":1,"speech":"%s","bytes":%s}}' "$PAD" "$BYTES"
        """#
        let fake = try FakeClaude(body: body)
        let big = String(repeating: "я", count: 1_500_000) // 3 MB in UTF-8
        let response = try await fake.provider().complete(request(timeout: 60, message: big))
        #expect(response.structuredJSON.utf8.count > 1_400_000)
        #expect(response.structuredJSON.contains("\"bytes\":3000000"))
    }

    /// A child that exits at once with output used to lose it: the termination handler waited for the readers before they
    /// had been started, so it saw an empty group and answered with whatever had arrived (nothing). Each run must also give
    /// its pipes back.
    @Test func quickChildrenKeepTheirOutputAndLeaveNoDescriptorsBehind() async throws {
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        for _ in 0 ..< 5 { _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["warm-up"], stdin: nil, environment: [:], workingDirectory: nil, timeout: 10) }
        let before = openDescriptors()
        for index in 0 ..< 150 {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out-\(index); echo err-\(index) >&2"],
                stdin: nil, environment: [:], workingDirectory: nil, timeout: 10
            )
            #expect(String(decoding: result.stdout, as: UTF8.self) == "out-\(index)\n", "run \(index) lost its output")
            #expect(String(decoding: result.stderr, as: UTF8.self) == "err-\(index)\n", "run \(index) lost its error text")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(openDescriptors() <= before + 4, "descriptors grew from \(before) to \(openDescriptors())")
    }

    @Test func capabilitiesAreProbedOncePerExecutable() async throws {
        let fake = try FakeClaude(body: FakeClaude.okBody)
        let provider = fake.provider()
        _ = try await provider.complete(request())
        _ = try await provider.complete(request())
        #expect(fake.read("help-count.txt").split(separator: "\n").count == 1)
        #expect(try await provider.capabilities().supports("--safe-mode"))
    }

    @Test func cancellingTheTaskStopsTheProcess() async throws {
        let fake = try FakeClaude(body: "sleep 30")
        let provider = fake.provider()
        let task = Task { try await provider.complete(request(timeout: 60)) }
        try await Task.sleep(for: .milliseconds(600))
        let started = Date()
        task.cancel()
        let outcome = await task.result
        #expect(Date().timeIntervalSince(started) < 8)
        if case .success = outcome { Issue.record("expected a failure") }
    }

    @Test func authStatusReadsTheJSON() async throws {
        let ok = try FakeClaude(body: FakeClaude.okBody, auth: #"echo '{"loggedIn":true,"authMethod":"claude.ai"}'"#)
        #expect(await ok.provider().authStatus() == .loggedIn(method: "claude.ai"))
        let out = try FakeClaude(body: FakeClaude.okBody, auth: #"echo '{"loggedIn":false}'"#)
        #expect(await out.provider().authStatus() == .loggedOut)
        let junk = try FakeClaude(body: FakeClaude.okBody, auth: "echo hmm")
        if case .unknown = await junk.provider().authStatus() {} else { Issue.record("expected unknown") }
    }
}

@Suite("Claude helpers")
struct ClaudeHelperTests {
    @Test func capabilitiesParseFlagsFromHelpText() {
        let help = """
        Usage: claude [options]
          -p, --print   Print and exit
          --output-format <format>   Output format
              --safe-mode   Start with customizations disabled
          --no-session-persistence
        Not a flag: -x and text--like--this
        """
        let caps = ClaudeCapabilities(helpText: help)
        #expect(caps.supports("--print") && caps.supports("--output-format") && caps.supports("--safe-mode"))
        #expect(caps.supports("--no-session-persistence"))
        #expect(!caps.supports("--bare") && !caps.supports("--like"))
    }

    @Test func environmentKeepsUsefulVariablesAndAddsPathEntries() {
        let env = ClaudeEnvironment.childEnvironment(base: ["HOME": "/Users/x", "PATH": "/a:/usr/bin", "LANG": "ru_RU.UTF-8", "ANTHROPIC_BASE_URL": "u"])
        #expect(env["LANG"] == "ru_RU.UTF-8" && env["ANTHROPIC_BASE_URL"] == nil)
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/a")
        #expect(path.filter { $0 == "/usr/bin" }.count == 1) // deduplicated
        #expect(path.contains("/Users/x/.local/bin") && path.contains("/Users/x/homebrew/bin"))
    }

    @Test func classifiesErrorMessages() {
        #expect(ClaudeCLIProvider.classify("Not logged in · Please run /login") == .notLoggedIn)
        #expect(ClaudeCLIProvider.classify("Weekly limit reached") == .rateLimited("Weekly limit reached"))
        #expect(ClaudeCLIProvider.classify("Internal error") == .apiError("Internal error"))
    }

    @Test func envelopeToleratesStrayLinesBeforeTheJSON() throws {
        let text = "warning: something\n{\"is_error\":false,\"structured_output\":{\"a\":1}}\n"
        let envelope = try #require(ClaudeEnvelope(parsing: text))
        #expect(envelope.structuredJSON == #"{"a":1}"#)
        #expect(ClaudeEnvelope(parsing: "nothing here") == nil)
    }
}
