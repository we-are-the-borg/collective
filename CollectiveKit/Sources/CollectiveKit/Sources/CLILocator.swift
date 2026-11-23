import Foundation

/// Finds a tool's command line program and prepares the environment to run it,
/// for the probes of every tool. Read-only: it only asks the file system and,
/// as a last resort, a login shell.
struct CLILocator: Sendable {
    /// Apps started from Finder or Dock lack the shell's `PATH`, so these come
    /// first, in this order, before asking a login shell.
    static let candidateDirectories = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    static let commandTimeout: Duration = .seconds(5)
    /// For `plugin list` and `plugin marketplace list`: a cold call of Codex
    /// 0.166.0 took 38 s (apparently a sync over the network, the next one 1 s),
    /// and a list that times out leaves the plugin unknown.
    static let listTimeout: Duration = .seconds(60)
    /// A login shell reads the user's profile, which can be slow.
    static let shellTimeout: Duration = .seconds(10)
    /// Prepended to `PATH` for the CLI: a Homebrew install can be a node script
    /// that needs `node` from there.
    static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    var cliName: String
    var candidateDirectories: [String] = Self.candidateDirectories
    var runner: any CommandRunner
    var isExecutable: @Sendable (String) -> Bool
    var environment: [String: String]
    var home: URL

    /// The first executable candidate, else what the login shell finds.
    func locate() async -> String? {
        for directory in candidateDirectories {
            let expanded = directory.hasPrefix("~/")
                ? home.appendingPathComponent(String(directory.dropFirst(2))).path
                : directory
            let path = (expanded as NSString).appendingPathComponent(cliName)
            if isExecutable(path) { return path }
        }
        let result = await runner.run(executable: Self.loginShell(in: environment),
                                      arguments: ["-l", "-c", "command -v \(cliName)"],
                                      environment: environment, timeout: Self.shellTimeout)
        guard !result.timedOut else { return nil }
        // A profile can print its own lines; only an executable absolute path counts.
        return result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") && isExecutable($0) }
    }

    /// The environment to run the CLI at `executable` in.
    func environment(forCLIAt executable: URL) -> [String: String] {
        Self.environment(forCLIAt: executable, base: environment)
    }

    /// Static so the setup commands run the CLI in the same environment as its probe.
    static func environment(forCLIAt executable: URL, base environment: [String: String]) -> [String: String] {
        var result = environment
        let ownDirectory = executable.deletingLastPathComponent().path
        let inherited = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
        result["PATH"] = [ownDirectory, Self.toolPath, inherited].compactMap { $0 }.joined(separator: ":")
        return result
    }

    /// The user's login shell, `zsh` (the macOS default) if the environment names none.
    static func loginShell(in environment: [String: String]) -> URL {
        URL(fileURLWithPath: environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh")
    }
}
