import Foundation
import SubspaceKit

/// What a probe found out about one tool's subspace integration (subspace contract §11).
public struct IntegrationStatus: Sendable, Equatable {
    public enum CLI: Sendable, Equatable { case found(path: String, version: String?), notFound }
    public enum Plugin: Sendable, Equatable { case notInstalled, disabled(version: String?), enabled(version: String?), unknown }
    public var source: SourceID
    public var toolName: String
    /// The name of the command the probe looks for; the "not found" line names it.
    public var cliName: String
    public var cli: CLI
    /// `.unknown` when the list failed and no earlier state is known (`pluginIsCarriedOver` marks a kept one).
    public var plugin: Plugin
    /// Whether the marketplace subspace is installed from is already known to the tool;
    /// nil = unknown: no CLI, or no list ever succeeded. After a failed list the previous answer stays (`keepingKnownPlugin(from:)`).
    public var marketplaceAdded: Bool?
    /// mtime of `$ROOT/plugin.json`: the last session start subspace saw; nil = never.
    public var lastSessionStartAt: Date?
    public var commands: SetupCommands
    /// Where the probe looked for the CLI, for the "not found" text, e.g. ["~/.local/bin", "/opt/homebrew/bin"]; the text adds "your login shell's PATH" itself.
    public var searchedLocations: [String]
    /// `plugin` is an earlier check's, kept because this one couldn't read it
    /// (`keepingKnownPlugin(from:)`); it shows, but proves nothing about now.
    public var pluginIsCarriedOver = false

    public init(
        source: SourceID,
        toolName: String,
        cliName: String,
        cli: CLI,
        plugin: Plugin,
        marketplaceAdded: Bool? = nil,
        lastSessionStartAt: Date? = nil,
        commands: SetupCommands,
        searchedLocations: [String] = []
    ) {
        self.source = source
        self.toolName = toolName
        self.cliName = cliName
        self.cli = cli
        self.plugin = plugin
        self.marketplaceAdded = marketplaceAdded
        self.lastSessionStartAt = lastSessionStartAt
        self.commands = commands
        self.searchedLocations = searchedLocations
    }
}

extension IntegrationStatus {
    /// A failed list (a timed-out CLI, say) says nothing about the installation,
    /// so the last known plugin state and marketplace answer of `previous` stay,
    /// as a failed release lookup keeps its last result. Everything
    /// else is this check's. A CLI that is no longer found keeps nothing: the
    /// tool is really gone.
    public func keepingKnownPlugin(from previous: IntegrationStatus?) -> IntegrationStatus {
        guard let previous, previous.source == source, case .found = cli else { return self }
        var result = self
        if plugin == .unknown, previous.plugin != .unknown {
            result.plugin = previous.plugin
            result.pluginIsCarriedOver = true
        }
        if marketplaceAdded == nil { result.marketplaceAdded = previous.marketplaceAdded }
        return result
    }
}

/// Tool-specific command lines delivered by the probe as plain strings, so presentation stays tool-neutral.
public struct SetupCommands: Sendable, Equatable {
    /// Typed in a terminal.
    public var install: [String]
    /// Typed in a session of the tool itself.
    public var installInApp: [String]
    public var enable: [String]
    public var enableInApp: [String]
    /// The line of `install` that adds the marketplace, so it can be skipped once the
    /// marketplace is known (`IntegrationStatus.marketplaceAdded`); nil if the tool has none.
    public var marketplaceLine: String?
    /// The repository the user installs from, for a link to its source.
    public var sourceURL: URL?
    /// What to do in the first session, when the tool asks more than starting
    /// one; nil keeps the setup card's general advice.
    public var firstSessionHint: LocalizedStringResource?
    /// Typed in a terminal, in order, to update an installed subspace; empty = no update to offer.
    public var update: [String]
    /// What to do after an update besides restarting sessions; nil keeps the general advice.
    public var updateHint: LocalizedStringResource?
    /// Where the published versions are listed; nil = they can't be looked up.
    public var release: SubspaceRelease?

    public init(
        install: [String],
        installInApp: [String],
        enable: [String],
        enableInApp: [String],
        marketplaceLine: String? = nil,
        sourceURL: URL? = nil,
        firstSessionHint: LocalizedStringResource? = nil,
        update: [String] = [],
        updateHint: LocalizedStringResource? = nil,
        release: SubspaceRelease? = nil
    ) {
        // Deliberately a trap: adapters pass constants, programmer-controlled and
        // covered by their probe tests, so a malformed one fails loudly in development.
        precondition(marketplaceLine.map(install.contains) ?? true, "marketplaceLine must be one of the install lines")
        self.install = install
        self.installInApp = installInApp
        self.enable = enable
        self.enableInApp = enableInApp
        self.marketplaceLine = marketplaceLine
        self.sourceURL = sourceURL
        self.firstSessionHint = firstSessionHint
        self.update = update
        self.updateHint = updateHint
        self.release = release
    }
}

/// Where one tool's published subspace versions are tagged, delivered by the adapter as plain data.
public struct SubspaceRelease: Sendable, Equatable {
    /// `owner/repo` whose git tags list the published versions: the repo the marketplace comes from.
    public var tagsRepository: String
    /// Put in front of the version in a tag, e.g. `<prefix>1.3.0`; one repo may tag several tools.
    public var tagPrefix: String
    /// The oldest installed version the app still works with; nil = any. Kept a string
    /// so the adapter states it as written; the update check parses it.
    public var minimumVersion: String?
    /// `owner/repo` that carries the same tags with the history behind them, for the changes link.
    public var changesRepository: String

    public init(tagsRepository: String, tagPrefix: String, minimumVersion: String? = nil, changesRepository: String) {
        self.tagsRepository = tagsRepository
        self.tagPrefix = tagPrefix
        self.minimumVersion = minimumVersion
        self.changesRepository = changesRepository
    }

    /// The GitHub comparison between two released versions, the form subspace's changelog links.
    public func changesURL(from old: String, to new: String) -> URL? {
        URL(string: "https://github.com/\(changesRepository)/compare/\(tagPrefix)\(old)...\(tagPrefix)\(new)")
    }
}
