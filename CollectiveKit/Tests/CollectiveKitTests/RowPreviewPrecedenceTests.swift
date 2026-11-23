import CollectiveKit
import Testing
@testable import CollectiveUI

/// Which preview shows when a card and a subagent row in its list both ask
/// the subagent row under the pointer wins, whichever order SwiftUI
/// merges the preferences in; otherwise the first ask stays.
@Suite("Row preview precedence")
struct RowPreviewPrecedenceTests {
    private let session = SessionKey(source: "tool", sessionID: "s1")
    private var idle: RowPreviewRequest.ID { .session(session) }
    private var subagent: RowPreviewRequest.ID { .subagent(session, .subagent("a1")) }

    @Test func aSubagentAfterTheCardTakesOver() {
        #expect(RowPreviewRequest.ID.takesOver(subagent, from: idle))
    }

    @Test func theCardAfterASubagentDoesNotTakeOver() {
        #expect(!RowPreviewRequest.ID.takesOver(idle, from: subagent))
    }

    @Test func anyAskTakesOverFromNone() {
        #expect(RowPreviewRequest.ID.takesOver(idle, from: nil))
        #expect(RowPreviewRequest.ID.takesOver(subagent, from: nil))
    }

    @Test func noAskNeverTakesOver() {
        #expect(!RowPreviewRequest.ID.takesOver(nil, from: idle))
        #expect(!RowPreviewRequest.ID.takesOver(nil, from: subagent))
        #expect(!RowPreviewRequest.ID.takesOver(nil, from: nil))
    }

    @Test func ofTheSameKindTheFirstStays() {
        let otherIdle = RowPreviewRequest.ID.session(SessionKey(source: "tool", sessionID: "s2"))
        let otherSubagent = RowPreviewRequest.ID.subagent(session, .subagent("a2"))
        #expect(!RowPreviewRequest.ID.takesOver(otherIdle, from: idle))
        #expect(!RowPreviewRequest.ID.takesOver(otherSubagent, from: subagent))
    }
}
