import Foundation
import SubspaceKit

/// The link right in the popover's status bar to an update: the settings
/// pane of a source whose subspace should be updated, or the app's own update
/// window. One link for everything: a required subspace update outranks an
/// app update, which outranks an available subspace update; among sources the
/// first in registration order wins.
public struct UpdateFooterLink: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case available
        case required
        /// A newer version of the app.
        case app(SubspaceVersion)
    }

    /// Where a click leads.
    public enum Target: Sendable, Equatable {
        /// The source's settings pane.
        case source(SourceID)
        /// The app's update window.
        case app
    }

    public let kind: Kind
    public let target: Target

    public var text: LocalizedStringResource {
        switch kind {
        case .available: .kit("Update available", defaultValue: "Update available")
        case .required: .kit("Update required", defaultValue: "Update required")
        case .app: .kit("App update available", defaultValue: "App update available")
        }
    }

    /// The tooltip and what VoiceOver reads.
    public var help: LocalizedStringResource {
        switch kind {
        case .available, .required: text
        case .app(let version):
            .kit("The Collective %@ is available", defaultValue: "The Collective \(version.description) is available")
        }
    }

    /// Symbol and text; the status bar's dot stays `success`, the connection is fine.
    public var role: ThemeRole {
        switch kind {
        case .available, .app: .info
        case .required: .warning
        }
    }

    /// - Parameters:
    ///   - statuses: The probed sources in registration order.
    ///   - availability: What the release check says per source; a missing source is up to date.
    ///   - checksForUpdates: The switch in General › Updates; off, only a required update links.
    ///   - appUpdate: A newer version of the app the last check found.
    /// - Returns: nil while no source's pane offers an update and the app has none.
    public init?(statuses: [IntegrationStatus], availability: [SourceID: UpdateAvailability], checksForUpdates: Bool,
                 appUpdate: SubspaceVersion? = nil) {
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
        if let (source, kind) = kinds.first(where: { $0.1 == .required }) {
            (self.kind, target) = (kind, .source(source))
        } else if let appUpdate {
            (self.kind, target) = (.app(appUpdate), .app)
        } else if let (source, kind) = kinds.first {
            (self.kind, target) = (kind, .source(source))
        } else {
            return nil
        }
    }
}
