import Foundation
import Testing
@testable import CollectiveKit

/// The lines of a run's edited transcript excerpt, in file order.
func antigravityExcerptLines(_ run: AntigravityRun) -> [Data] {
    let url = run.directory.appendingPathComponent("transcripts/excerpt.jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map { Data($0.utf8) }
}

/// The excerpt's lines of one conversation, by the `conversation_id` the
/// curation added (fixture README); a real transcript is one conversation's.
func antigravityTranscript(of conversation: String, in run: AntigravityRun) -> [Data] {
    antigravityExcerptLines(run).filter {
        (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["conversation_id"] as? String == conversation
    }
}

@Suite struct AntigravityTranscriptTests {
    @Test func readsTheParentAndPromptOfRunOnesChild() throws {
        let line = try #require(antigravityTranscript(of: "bd793872-9200-404c-922e-0d0017b69b7f", in: .headlessSubagent).first)
        #expect(FileAntigravityTranscriptReader.parse(line) == AntigravityTranscriptOrigin(
            parent: "ea5fa741-34ec-4612-ad24-205289f3eb4b",
            prompt: #"Reply strictly with "sub-ok". Do not call any tools or edit any files."#
        ))
    }

    @Test func readsTheParentAndPromptOfRunTwosChildren() throws {
        let alpha = try #require(antigravityTranscript(of: "91921677-ee57-400f-8371-5ea165c7bfd2", in: .parallelSubagents).first)
        let beta = try #require(antigravityTranscript(of: "eb79fbb4-b523-43b2-ba16-e221db8df6f5", in: .parallelSubagents).first)
        #expect(FileAntigravityTranscriptReader.parse(alpha) == AntigravityTranscriptOrigin(
            parent: "9387948b-0c36-40db-986f-d38d89d7b6dc",
            prompt: "Run the command `pwd` using run_command and report the exact output."
        ))
        #expect(FileAntigravityTranscriptReader.parse(beta) == AntigravityTranscriptOrigin(
            parent: "9387948b-0c36-40db-986f-d38d89d7b6dc",
            prompt: "Read lines 1-3 of README.md using read_file and report the first heading found."
        ))
    }

    /// A hand-off message later in a parent's transcript (step 14) names the
    /// child as its sender: only step 0 says who started the conversation.
    @Test func readsNoParentFromALaterStep() throws {
        let handOff = try #require(antigravityExcerptLines(.headlessSubagent).first {
            String(decoding: $0, as: UTF8.self).contains(#""step_index": 14"#)
        })
        #expect(FileAntigravityTranscriptReader.parse(handOff) == nil)
    }

    /// A tool result and a planner response are other shapes than a hand-off.
    @Test func readsNoParentFromALineOfAnotherShape() throws {
        let generic = try #require(antigravityExcerptLines(.headlessSubagent).first)
        #expect(FileAntigravityTranscriptReader.parse(generic) == nil)
        let planner = try #require(antigravityExcerptLines(.desktopApp).first)
        #expect(FileAntigravityTranscriptReader.parse(planner) == nil)
        #expect(FileAntigravityTranscriptReader.parse(Data("not json".utf8)) == nil)
    }

    @Test func readsNothingFromAMissingOrEmptyFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = FileAntigravityTranscriptReader()
        #expect(reader.origin(transcriptPath: folder.appendingPathComponent("missing.jsonl").path) == nil)

        let empty = folder.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        #expect(reader.origin(transcriptPath: empty.path) == nil)
    }

    /// The first line still being written is no answer yet; once it is, the file is read anew.
    @Test func readsTheFirstLineOnceItIsComplete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = antigravityTranscript(of: "bd793872-9200-404c-922e-0d0017b69b7f", in: .headlessSubagent)
        let line = try #require(lines.first)
        let file = folder.appendingPathComponent("transcript_full.jsonl")
        let reader = FileAntigravityTranscriptReader()

        try line.prefix(line.count / 2).write(to: file)
        #expect(reader.origin(transcriptPath: file.path) == nil)

        try (line + Data("\n".utf8) + antigravityExcerptLines(.headlessSubagent)[0] + Data("\n".utf8)).write(to: file)
        #expect(reader.origin(transcriptPath: file.path)?.parent == "ea5fa741-34ec-4612-ad24-205289f3eb4b")
    }
}
