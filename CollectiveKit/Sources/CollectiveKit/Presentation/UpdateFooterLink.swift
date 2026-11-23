import Foundation
import SubspaceKit

/// The link right in the popover's status bar to the settings pane of a
/// source whose subspace should be updated. One link for all sources: a required update outranks an available one, then the first
/// source in registration order wins.
public struct UpdateFooterLink: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case available, required }

    public let kind: Kind
    /// The source whose settings pane the link opens.
    public let source: SourceID

    public var text: LocalizedStringResource {
        switch kind {
        case .available: .kit("Update available", defaultValue: "Update available")
        case .required: .kit("Update required", defaultValue: "Update required")
        }
    }

    /// Symbol and text; the status bar's dot stays `success`, the connection is fine.
    public var role: ThemeRole {
        switch kind {
        case .available: .info
        case .required: .warning
        }
    }

    /// - Parameters:
    ///   - statuses: The probed sources in registration order.
    ///   - availability: What the release check says per source; a missing source is up to date.
    ///   - checksForUpdates: The switch in General › Updates; off, only a required update links.
    /// - Returns: nil while no source's pane offers an update.
    public init?(statuses: [IntegrationStatus], availability: [SourceID: UpdateAvailability], checksForUpdates: Bool) {
        // The pane's own group decides, so the link never points at a pane
        // that offers nothing. Without a run the clock plays no part.
        let kinds: [(SourceID, Kind)] = statuses.compactMap { status in
            let group = SourceUpdateModel(status, checkedAt: nil, availability: availability[status.source] ?? .upToDate,
                                          checksForUpdates: checksForUpdates, now: .distantPast)
            return switch group?.state {
            case .required?: (status.source, .required)
            case .available?: (status.source, .available)
            case .running?, .failed?, .updated?, nil: nil
            }
        }
        guard let (source, kind) = kinds.first(where: { $0.1 == .required }) ?? kinds.first else { return nil }
        self.kind = kind
        self.source = source
    }
}
