import Foundation
import SubspaceKit

/// Checks whether one tool has subspace installed and enabled. One per tool,
/// so a new tool brings its own probe and the presentation stays unchanged.
public protocol IntegrationProbe: Sendable {
    var source: SourceID { get }
    /// What `check()` reports as `IntegrationStatus.commands`, known without a
    /// check, so the settings window can link the plugin before the first one returns.
    var commands: SetupCommands { get }
    func check() async -> IntegrationStatus
}
