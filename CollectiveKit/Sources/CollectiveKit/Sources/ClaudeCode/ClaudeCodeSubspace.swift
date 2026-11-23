import Foundation

/// Where subspace comes from for Claude Code. The only place that names the
/// marketplace and the plugin, so a move changes one line.
enum ClaudeCodeSubspace {
    /// The marketplace argument of `claude plugin marketplace add`: the distribution
    /// repo the release workflow of we-are-the-borg/subspace writes.
    static let marketplace = "we-are-the-borg/subspace-claude-code"
    /// The name the marketplace registers under, as `claude plugin marketplace list --json` reports it.
    static let marketplaceName = "subspace"
    /// `<plugin>@<marketplace>`, as `claude plugin list --json` reports it (contract §11).
    static let pluginID = "subspace@\(marketplaceName)"
    /// The repository behind `marketplace`.
    static let sourceURL = URL(string: "https://github.com/\(marketplace)")

    /// The dev repo; it carries the distribution repo's tags, so changes between two versions can be linked.
    static let changesRepository = "we-are-the-borg/subspace"

    private static let marketplaceLine = "claude plugin marketplace add \(marketplace)"

    static let commands = SetupCommands(
        install: [
            marketplaceLine,
            "claude plugin install \(pluginID) --scope user",
        ],
        installInApp: ["/plugin marketplace add \(marketplace)", "/plugin install \(pluginID)"],
        enable: ["claude plugin enable \(pluginID)"],
        enableInApp: ["/plugin enable \(pluginID)"],
        marketplaceLine: marketplaceLine,
        sourceURL: sourceURL,
        // The plugin updates to what the local copy of the marketplace knows, so that copy is refreshed first.
        update: [
            "claude plugin marketplace update \(marketplaceName)",
            "claude plugin update \(pluginID) --scope user",
        ],
        release: SubspaceRelease(tagsRepository: marketplace, tagPrefix: "claude-code-", changesRepository: changesRepository)
    )
}
