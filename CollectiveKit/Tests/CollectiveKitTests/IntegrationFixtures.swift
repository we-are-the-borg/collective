import Foundation
import SubspaceKit
@testable import CollectiveKit

/// A probe result for a made-up tool, so the presentation tests stay tool-neutral.
func integration(
    _ plugin: IntegrationStatus.Plugin,
    source: SourceID = "test-tool",
    toolName: String = "Test Tool",
    cli: IntegrationStatus.CLI = .found(path: "/usr/local/bin/tt", version: "1.2.3"),
    lastSessionStartAt: Date? = nil,
    searchedLocations: [String] = ["~/.local/bin", "/opt/homebrew/bin"]
) -> IntegrationStatus {
    IntegrationStatus(
        source: source,
        toolName: toolName,
        cliName: "tt",
        cli: cli,
        plugin: plugin,
        lastSessionStartAt: lastSessionStartAt,
        commands: SetupCommands(
            install: ["tt plugin marketplace add example/subspace", "tt plugin install subspace"],
            installInApp: ["/plugin install subspace"],
            enable: ["tt plugin enable subspace"],
            enableInApp: ["/plugin enable subspace"]
        ),
        searchedLocations: searchedLocations
    )
}
