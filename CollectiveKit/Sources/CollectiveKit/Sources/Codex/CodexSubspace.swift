import Foundation

/// Where subspace comes from for Codex. The only place that names the
/// marketplace and the plugin, so a move changes one line.
enum CodexSubspace {
    /// The marketplace argument of `codex plugin marketplace add`.
    static let marketplace = "we-are-the-borg/subspace-codex"
    /// `<plugin>@<marketplace>`, as `codex plugin list --json` reports it (contract §11).
    static let pluginID = "subspace@subspace"
    static let marketplaceName = "subspace"
    /// The repository behind `marketplace`.
    static let sourceURL = URL(string: "https://github.com/\(marketplace)")

    /// The dev repo; it carries the distribution repo's tags, so changes between two versions can be linked.
    static let changesRepository = "we-are-the-borg/subspace"

    private static let marketplaceLine = "codex plugin marketplace add \(marketplace)"

    /// Codex 0.160 has no command to enable an installed plugin, so there is
    /// nothing to offer for enabling. Its sessions hold a plugin's hooks back
    /// until they are approved in `/hooks` (subspace contract §11), so the
    /// first session needs that step too, and so does the first after an update,
    /// whose changed hooks are held back again. Codex has no plugin update
    /// command: adding the plugin again from the upgraded marketplace updates it.
    static let commands = SetupCommands(
        install: [
            marketplaceLine,
            "codex plugin add \(pluginID)",
        ],
        installInApp: [],
        enable: [],
        enableInApp: [],
        marketplaceLine: marketplaceLine,
        sourceURL: sourceURL,
        firstSessionHint: .kit(
            "Start a new Codex session, then approve subspace’s hooks with /hooks.",
            defaultValue: "Start a new Codex session, then approve subspace’s hooks with /hooks."
        ),
        update: [
            "codex plugin marketplace upgrade \(marketplaceName)",
            "codex plugin add \(pluginID)",
        ],
        updateHint: .kit(
            "Start a new Codex session, then approve subspace’s changed hooks with /hooks.",
            defaultValue: "Start a new Codex session, then approve subspace’s changed hooks with /hooks."
        ),
        release: SubspaceRelease(tagsRepository: marketplace, tagPrefix: "codex-", changesRepository: changesRepository)
    )
}
