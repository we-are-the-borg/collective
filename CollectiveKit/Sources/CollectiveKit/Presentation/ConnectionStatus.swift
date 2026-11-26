import Foundation

/// Whether the app warns about subspace: in the menu bar, above the popover's
/// list and in its footer. Only a missing or disabled plugin warns; an
/// installed and enabled one that stays silent is left to the FAQ, since the
/// app cannot tell silence from "no agent running".
public enum ConnectionStatus: Sendable, Equatable {
    case ok
    /// The tool has no user-scope install of subspace.
    case missing(IntegrationStatus)
    /// subspace is installed but switched off in the tool, so sessions started
    /// afterwards spool nothing; running ones keep reporting until they end.
    case disabled(IntegrationStatus)

    /// With several sources, a missing plugin warns only if no source has subspace
    /// enabled: whoever uses just one tool needn't be nagged about the others. The
    /// first missing one in `integrations` is named. A disabled plugin warns per
    /// source, even if another is enabled, since the user switched it off; missing
    /// wins over disabled. No status yet (the first check is still running) and
    /// an unknown one never warn.
    /// - Parameter allReported: Whether every source has reported once
    ///   (`IntegrationChecks.allReported`). Until then a missing plugin waits,
    ///   since a source still in its first check may have subspace enabled; a
    ///   disabled one warns at once.
    public init(integrations: [IntegrationStatus], allReported: Bool = true) {
        let anyEnabled = integrations.contains { if case .enabled = $0.plugin { true } else { false } }
        if allReported, !anyEnabled, let missing = integrations.first(where: { $0.plugin == .notInstalled }) {
            self = .missing(missing)
        } else if let disabled = integrations.first(where: { if case .disabled = $0.plugin { true } else { false } }) {
            self = .disabled(disabled)
        } else {
            self = .ok
        }
    }
}
