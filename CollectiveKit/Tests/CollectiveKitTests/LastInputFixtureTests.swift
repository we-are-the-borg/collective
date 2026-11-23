import Foundation
import Testing
@testable import CollectiveKit

private extension CollectiveState {
    var only: Session { sessions.values.first! }
}

private func second(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// Store seam: when the user last gave a session input, which the
/// notification for a long turn measures from.
@Suite struct LastInputFixtureTests {
    /// S4: prompt 007 at 1790969315; the request 010 is approved, which the
    /// status file says with `busy` in 012 (updated 1790969332.188, taken in
    /// whole seconds like any report that answers a request).
    @Test func answeringAPermissionRequestIsInput() throws {
        let run = Timeline("4-waiting-permission-question")
        #expect(try run.replay(through: 11).only.lastInputAt == second(1_790_969_315))
        #expect(try run.replay(through: 12).only.lastInputAt == second(1_790_969_332))
    }

    /// S4 asks a question with 026 after prompt 025 (1790969359). The status
    /// file's `busy` in 030 (1790969376.960) answers it; without the status
    /// file, the call's end 031 (1790969377) does.
    @Test func answeringAQuestionIsInput() throws {
        let run = Timeline("4-waiting-permission-question")
        #expect(try run.replay(through: 29).only.lastInputAt == second(1_790_969_359))
        #expect(try run.replay(through: 30).only.lastInputAt == second(1_790_969_376))
        #expect(try run.replay(through: 31, statuses: false).only.lastInputAt == second(1_790_969_377))
    }

    /// S6: the background agents hand back with 025 and 034, which the
    /// adapter reports as turns starting, not as prompts: the input stays
    /// prompt 014 (1790969576), and so does it once the turns ended.
    @Test func aHandBackIsNoInput() throws {
        let run = Timeline("6-background-subagents")
        #expect(try run.replay(through: 14).only.lastInputAt == second(1_790_969_576))
        let handedBack = try run.replay(through: 25).only
        #expect(handedBack.turnStartedAt == second(1_790_969_584))
        #expect(handedBack.lastInputAt == second(1_790_969_576))
        #expect(try run.replay(through: 36).only.lastInputAt == second(1_790_969_576))
    }
}
