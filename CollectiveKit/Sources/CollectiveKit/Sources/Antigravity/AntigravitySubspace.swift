import Foundation

/// Where subspace comes from for Antigravity. The only place that names the
/// repository and the plugin, so a move changes one line.
enum AntigravitySubspace {
    /// The repository `agy plugin install` takes: the distribution repo the
    /// release workflow of we-are-the-borg/subspace writes.
    static let repository = "we-are-the-borg/subspace-antigravity"
    /// The `name` `agy plugin list --json` reports (contract §11).
    static let pluginName = "subspace"
    static let sourceURL = URL(string: "https://github.com/\(repository)")

    /// The dev repo; it carries the distribution repo's tags, so changes between two versions can be linked.
    static let changesRepository = "we-are-the-borg/subspace"

    private static let installLine = "agy plugin install https://github.com/\(repository)"

    /// `agy` installs straight from the repository, so there is no marketplace
    /// to add, and installing again is the update.
    static let commands = SetupCommands(
        install: [installLine],
        installInApp: [],
        enable: ["agy plugin enable \(pluginName)"],
        enableInApp: [],
        sourceURL: sourceURL,
        firstSessionHint: .kit(
            "Start a new Antigravity conversation.",
            defaultValue: "Start a new Antigravity conversation."
        ),
        update: [installLine],
        updateHint: .kit(
            "Start a new Antigravity conversation to use the updated subspace.",
            defaultValue: "Start a new Antigravity conversation to use the updated subspace."
        ),
        release: SubspaceRelease(tagsRepository: repository, tagPrefix: "antigravity-", minimumVersion: "1.0.0",
                                 changesRepository: changesRepository)
    )
}
