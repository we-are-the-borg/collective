import Foundation
import SubspaceKit

/// Translates one tool's pushed payloads into `AgentEvent`s.
///
/// Adapters may keep state (e.g. to correlate ids across hook calls), so they
/// are reference types confined to the store's actor.
public protocol PushAdapter: AnyObject {
    var source: SourceID { get }
    /// The tool's name as the popover shows it next to a session, e.g. "Claude Code".
    var displayName: String { get }
    /// The tool's logo, an image in `ToolLogo.bundle`, which the popover's
    /// jump line shows instead of the name; nil shows the raw source id.
    var logoName: String? { get }
    /// How the popover shortens this tool's model names.
    var modelNaming: any ModelNaming { get }
    /// How a session of this tool is resumed in a terminal; nil if it can't be.
    var resumeCommand: ResumeCommand? { get }
    func events(from envelope: Envelope) throws -> [AgentEvent]
    /// The mapping document this adapter reads payloads through, nil if there is
    /// none. The spool reader fetches it once per pass and maps the payloads in
    /// parallel; only `events(from:mapped:)` then runs in spool order.
    func mappingDocument() -> MappingDocument?
    /// `events(from:)` for a payload already mapped with `mappingDocument()`.
    func events(from envelope: Envelope, mapped: MappingResult) throws -> [AgentEvent]
    /// Target fields of the mapping this adapter never reads, e.g. large ones
    /// like a tool's output. The spool reader's store drops them from what it
    /// keeps, so `events(from:mapped:)` may get a result without them.
    var excludedFields: Set<String> { get }
    /// The folder subspace spools this source's events into (subspace contract §2),
    /// without the shared `SUBSPACE_DIR` override, which the reader applies.
    func spoolRoot(environment: [String: String], home: URL) -> URL
    /// Every folder subspace spools this source's events into, for a tool that
    /// writes to more than one (e.g. a CLI and a desktop app), the primary
    /// `spoolRoot` first. As there, without the `SUBSPACE_DIR` override.
    func spoolRoots(environment: [String: String], home: URL) -> [URL]
}

public extension PushAdapter {
    /// Tools without a bundled logo show their raw id.
    var logoName: String? { nil }
    /// Tools without own rules show their model names as delivered.
    var modelNaming: any ModelNaming { PlainModelNaming() }
    /// Tools without one get no "Copy Resume Command".
    var resumeCommand: ResumeCommand? { nil }
    /// Adapters that don't read through a mapping get every envelope whole.
    func mappingDocument() -> MappingDocument? { nil }
    func events(from envelope: Envelope, mapped: MappingResult) throws -> [AgentEvent] {
        try events(from: envelope)
    }
    /// Adapters that name nothing have every field kept.
    var excludedFields: Set<String> { [] }
    /// Most tools spool into one root.
    func spoolRoots(environment: [String: String], home: URL) -> [URL] {
        [spoolRoot(environment: environment, home: home)]
    }
}

/// A source that produces events by itself, e.g. by watching a tool's session files.
public protocol PullSource: Sendable {
    var source: SourceID { get }
    /// The tool's name as the popover shows it next to a session, e.g. "Claude Code".
    var displayName: String { get }
    /// As `PushAdapter.logoName`.
    var logoName: String? { get }
    /// Batches like `SpoolReader.events()`, so a consumer applies what one
    /// scan found at once; empty batches are not yielded. Ending the stream's
    /// iteration stops the source.
    func events() -> AsyncStream<[AgentEvent]>
}

public extension PullSource {
    var logoName: String? { nil }
}
