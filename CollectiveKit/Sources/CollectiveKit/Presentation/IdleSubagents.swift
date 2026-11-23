import Foundation

/// "4 subagents, all done · Sonnet 5, Haiku 5.5": an idle row's subagents
/// at the foot of its reply preview, once the row is all that is left of
/// the card.
public struct IdleSubagents: Sendable, Equatable {
    /// The texts come from it when a view asks.
    private let summary: SessionItem.Summary
    /// The subagents' own models as the popover names them, each once, in
    /// the order they were first spawned with; those the source never named
    /// left out.
    public let modelNames: [String]

    /// `nil` without subagents.
    init?(_ session: Session, summary: SessionItem.Summary, naming: any ModelNaming) {
        guard summary.subagentCount > 0 else { return nil }
        self.summary = summary
        var seen: Set<String> = []
        modelNames = session.descendants(of: .root)
            .sorted { SubagentListBuild.newestFirst($1, $0) }
            .compactMap { ModelLabel(knownModelOf: $0, naming: naming)?.name }
            .filter { seen.insert($0).inserted }
    }

    private var allDone: Bool { summary.doneCount == summary.subagentCount }

    /// "4 subagents, all done" while every one is done, else "4 subagents",
    /// followed by `statusParts`.
    public var title: LocalizedStringResource {
        allDone
            ? .kit("%lld subagents, all done", defaultValue: "\(summary.subagentCount) subagents, all done")
            : .kit("%lld subagents", defaultValue: "\(summary.subagentCount) subagents")
    }

    /// The counts by status; empty while all are done.
    public var statusParts: [LocalizedStringResource] {
        allDone ? [] : SubagentsHeader(summary: summary).statusParts
    }
}
