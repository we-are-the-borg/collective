import SubspaceKit

/// A session is unique per source; two tools may reuse the same session id.
public struct SessionKey: Hashable, Sendable, Codable {
    public let source: SourceID
    public let sessionID: String

    public init(source: SourceID, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }
}

/// Addresses an agent within a session: the orchestrator itself or one of its subagents.
public enum AgentRef: Hashable, Sendable, Codable {
    case root
    case subagent(String)
}

/// What the user archived: a whole session or one agent in it. Codable so the
/// app can keep the marks across restarts.
public enum ArchiveTarget: Hashable, Sendable, Codable {
    case session(SessionKey)
    case agent(SessionKey, AgentRef)
}
