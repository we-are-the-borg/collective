import Foundation
import Testing
@testable import CollectiveKit

private let key = SessionKey(source: "test-tool", sessionID: "s1")
private let other = SessionKey(source: "other-tool", sessionID: "s2")
/// Sub-second on purpose: the file must keep the exact `Date`.
private let now = Date(timeIntervalSince1970: 1_790_000_000.123_456)
private let day: TimeInterval = 24 * 60 * 60

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ReadFileTests {
    @Test func savedMarksLoadBackExactly() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ReadFile(url: folder.appendingPathComponent("read.json"))
        let marks: [SessionKey: Date] = [
            key: now.addingTimeInterval(-0.987_654),
            other: now.addingTimeInterval(-3 * day),
        ]

        file.save(marks, now: now)

        #expect(file.load(now: now) == marks)
    }

    /// The first launch tells itself apart by the missing file: without one,
    /// what the first backlog brings counts as read.
    @Test func aMissingFileIsNotAFileWithoutMarks() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ReadFile(url: folder.appendingPathComponent("read.json"))
        #expect(file.load(now: now) == nil)

        file.save([:], now: now)
        #expect(file.load(now: now) == [:])
    }

    @Test func anUnreadableFileHasNoMarks() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("read.json")

        try Data([0xFF, 0x00, 0x7B, 0x22]).write(to: url)
        #expect(ReadFile(url: url).load(now: now) == [:])
    }

    @Test func marksOlderThanThirtyDaysAreDroppedOnSaveAndLoad() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ReadFile(url: folder.appendingPathComponent("read.json"))
        let old = SessionKey(source: "test-tool", sessionID: "old")

        file.save([key: now.addingTimeInterval(-29 * day),
                   other: now.addingTimeInterval(-29 * day),
                   old: now.addingTimeInterval(-31 * day)], now: now)
        #expect(file.load(now: now).map { Set($0.keys) } == [key, other])
        // Seen from two days earlier the old mark would be young again: only the
        // save can have dropped it.
        #expect(file.load(now: now.addingTimeInterval(-2 * day)).map { Set($0.keys) } == [key, other])

        // Two days later the 29-day marks have aged past retention in the file.
        #expect(file.load(now: now.addingTimeInterval(2 * day)) == [:])
    }

    @Test func savingCreatesMissingFolders() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ReadFile(url: folder.appendingPathComponent("Application Support/Collective/read.json"))

        file.save([key: now], now: now)

        #expect(file.load(now: now) == [key: now])
    }

    @Test func readSessionsStayReadInANewState() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ReadFile(url: folder.appendingPathComponent("read.json"))
        let ended = now.addingTimeInterval(-60)
        var before = CollectiveState()
        for session in [key, other] {
            before.apply(AgentEvent(session: session, timestamp: ended.addingTimeInterval(-10), kind: .promptSubmitted("go")))
            before.apply(AgentEvent(session: session, timestamp: ended, kind: .turnEnded()))
        }
        before.markRead(key, upTo: ended)

        file.save(before.readMarks, now: now)
        // The new state has no sessions yet: marks must not depend on them.
        var after = CollectiveState()
        after.restoreReadMarks(try #require(file.load(now: now)))
        for session in [key, other] {
            after.apply(AgentEvent(session: session, timestamp: ended.addingTimeInterval(-10), kind: .promptSubmitted("go")))
            after.apply(AgentEvent(session: session, timestamp: ended, kind: .turnEnded()))
        }

        #expect(!after.isUnread(key))
        #expect(after.isUnread(other))
    }
}
