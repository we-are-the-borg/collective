import Foundation

/// Who started a subagent conversation, as the first step of its transcript
/// says. No hook names a subagent's parent; the step-0 `SYSTEM_MESSAGE` of
/// its transcript is the message it was started with (subspace contract §6, §8).
public struct AntigravityTranscriptOrigin: Sendable, Equatable {
    /// The `conversationId` of the conversation that sent the first message.
    public var parent: String
    /// The message the subagent was started with: its spawn call's `Prompt`.
    public var prompt: String?

    public init(parent: String, prompt: String? = nil) {
        self.parent = parent
        self.prompt = prompt
    }
}

/// Reads transcript origins. A protocol so adapter tests run without a file system.
public protocol AntigravityTranscriptReading: Sendable {
    /// `nil` while the transcript doesn't exist yet, its first line isn't
    /// complete or isn't a message from another conversation.
    func origin(transcriptPath: String) -> AntigravityTranscriptOrigin?
}

/// Reads the first line of a transcript JSONL, read-only. Antigravity writes
/// it asynchronously and its format is internal (contract §8), so anything
/// unexpected is simply no answer.
public struct FileAntigravityTranscriptReader: AntigravityTranscriptReading {
    /// The first line carries the subagent's prompt; beyond this it is not a
    /// line we understand, and the link waits for the subagent's `send_message`.
    private static let maxLineLength = 256 << 10

    public init() {}

    public func origin(transcriptPath: String) -> AntigravityTranscriptOrigin? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxLineLength + 1) else { return nil }
        // Until its newline is written, the line may be unfinished.
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return Self.parse(data[data.startIndex..<newline])
    }

    /// The origin in a step-0 `SYSTEM_MESSAGE` record, whose content holds
    /// `[Message] timestamp=… sender=<id> priority=… content=<prompt>`.
    static func parse(_ line: Data) -> AntigravityTranscriptOrigin? {
        guard
            let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            json["step_index"] as? Int == 0,
            json["type"] as? String == "SYSTEM_MESSAGE",
            let content = json["content"] as? String,
            let header = content.range(of: "[Message] ")
        else { return nil }
        let message = content[header.upperBound...]
        guard let sender = message.range(of: "sender=") else { return nil }
        let parent = message[sender.upperBound...].prefix { !$0.isWhitespace }
        guard !parent.isEmpty else { return nil }

        var prompt: String?
        if let start = message.range(of: " content=", range: sender.upperBound..<message.endIndex) {
            var text = message[start.upperBound...]
            if let end = text.range(of: "</SYSTEM_MESSAGE>", options: .backwards) { text = text[..<end.lowerBound] }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = trimmed.isEmpty ? nil : trimmed
        }
        return AntigravityTranscriptOrigin(parent: String(parent), prompt: prompt)
    }
}
