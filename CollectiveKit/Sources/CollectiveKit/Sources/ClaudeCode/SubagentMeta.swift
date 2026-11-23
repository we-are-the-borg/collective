import Foundation

/// What Claude Code records about a subagent in `agent-<id>.meta.json`, next to
/// the session transcript. The format is internal to Claude Code (subspace
/// contract §6, §8), so everything but the link to the `Agent` call is optional.
public struct SubagentMeta: Sendable, Equatable {
    /// `tool_use_id` of the `Agent` call that started the subagent.
    public var toolUseID: String
    public var description: String?
    public var isBackground: Bool?

    public init(toolUseID: String, description: String? = nil, isBackground: Bool? = nil) {
        self.toolUseID = toolUseID
        self.description = description
        self.isBackground = isBackground
    }
}

/// Reads subagent meta files. A protocol so adapter tests run without a file system.
public protocol SubagentMetaReading: Sendable {
    /// `nil` while the file doesn't exist yet or can't be understood.
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta?
}

/// Reads `<transcript without .jsonl>/subagents/agent-<agentID>.meta.json`, read-only.
public struct FileSubagentMetaReader: SubagentMetaReading {
    public init() {}

    public func meta(transcriptPath: String, agentID: String) -> SubagentMeta? {
        guard transcriptPath.hasSuffix(".jsonl") else { return nil }
        let session = String(transcriptPath.dropLast(".jsonl".count))
        let url = URL(fileURLWithPath: session)
            .appendingPathComponent("subagents")
            .appendingPathComponent("agent-\(agentID).meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let toolUseID = json["toolUseId"] as? String
        else { return nil }
        return SubagentMeta(
            toolUseID: toolUseID,
            description: json["description"] as? String,
            isBackground: (json["requestShape"] as? String).map { $0 == "background" }
        )
    }
}
