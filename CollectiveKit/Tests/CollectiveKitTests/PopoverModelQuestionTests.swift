import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Events of one session, one second apart.
private func session(_ id: String, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key(id), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind)
    }
}

private func state(_ events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    for event in events { state.apply(event) }
    return state
}

/// Without an "Idle" group, so a resting card stays a card however long it rests.
private func model(_ state: CollectiveState, at seconds: TimeInterval = 30, idleAfter: IdleAfter = .never) -> PopoverModel {
    PopoverModel(state: state, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(idleAfter: idleAfter))
}

private func card(_ kinds: [AgentEvent.Kind]) throws -> SessionItem {
    try #require(model(state(session("s1", kinds))).sessions.first)
}

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private let ask = ToolActivity(name: "Ask")
private let mapping = Question(
    header: "Mapping",
    text: "Which mapping revision should the adapter read?",
    options: [QuestionOption(label: "Revision 5", detail: "The bundled one"), QuestionOption(label: "Revision 6")],
    allowsOwnAnswer: true
)
private let fruits = Question(
    header: "Fruits",
    text: "Which fruits do you like?",
    options: [QuestionOption(label: "apple"), QuestionOption(label: "banana"), QuestionOption(label: "cherry")],
    allowsMultiple: true,
    allowsOwnAnswer: true
)

/// The orchestrator asks from inside a tool call, as the sources do.
private func asking(_ questions: [Question]) -> [AgentEvent.Kind] {
    [
        .promptSubmitted("Go"),
        .toolStarted(agent: .root, ask, callID: "c1"),
        .questionAsked(agent: .root, questions, callID: "c1"),
    ]
}

/// An open question on the popover card: its own state, styled like
/// "needs permission", with the first question under the status word.
@Suite struct PopoverModelQuestionTests {
    // MARK: State and status word

    /// The asking tool is no activity worth showing: the question box stands alone.
    @Test func anOrchestratorAskingMakesAQuestionCard() throws {
        let item = try card(asking([mapping]))
        #expect(item.cardState == .question)
        #expect(item.rowStatus == .question(count: 1))
        #expect(item.activity == nil)
    }

    @Test func twoOpenQuestionsCountInTheStatusWord() throws {
        let item = try card(asking([mapping, fruits]))
        #expect(item.rowStatus == .question(count: 2))
        #expect(item.question?.moreCount == 1)
        #expect(item.question.flatMap(\.moreText).map(en) == "+1 more question")
    }

    /// A tool call waiting blocks the agent the same way, and the permission
    /// card says what to allow.
    @Test func aPermissionRequestWinsOverAQuestion() throws {
        let bash = ToolActivity(name: "Bash", detail: "make")
        let item = try card([
            .promptSubmitted("Go"),
            .agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "explore", title: "X1")),
            .toolStarted(agent: .subagent("x1"), bash),
            .permissionRequested(agent: .subagent("x1"), bash),
            .toolStarted(agent: .root, ask, callID: "c1"),
            .questionAsked(agent: .root, [mapping], callID: "c1"),
        ])
        #expect(item.cardState == .needsPermission)
        #expect(item.rowStatus == .needsPermission)
        #expect(item.question == nil)
    }

    /// Answered, the card works again and shows its activity.
    @Test func theAnswerEndsTheQuestionCard() throws {
        var answered = mapping
        answered.answer = "Revision 6"
        let item = try card(asking([mapping]) + [
            .toolFinished(agent: .root, callID: "c1"),
            .questionAnswered(agent: .root, [answered], callID: "c1"),
        ])
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .working)
        #expect(item.question == nil)
        #expect(item.activity == .thinking)
    }

    // MARK: Content

    @Test func theCardShowsTheFirstQuestionNumberedWithOtherLast() throws {
        let question = try #require(try card(asking([mapping, fruits])).question)
        #expect(question.header == "Mapping")
        #expect(question.multiSelectHint == nil)
        #expect(question.text == "Which mapping revision should the adapter read?")
        #expect(question.choices == [
            QuestionChoice(number: 1, label: .option("Revision 5"), detail: "The bundled one"),
            QuestionChoice(number: 2, label: .option("Revision 6"), detail: nil),
            QuestionChoice(number: 3, label: .other, detail: nil),
        ])
        #expect(en(QuestionChoice.otherText) == "Other")
        #expect(en(question.answerHint) == "Answer in Terminal: type a number or your own answer.")
    }

    @Test func anEmptyOptionDescriptionIsNoDetail() throws {
        let question = Question(text: "Tea or coffee?", options: [QuestionOption(label: "Tea", detail: ""), QuestionOption(label: "Coffee", detail: "Hot")])
        let prompt = try #require(QuestionPrompt([question]))
        #expect(prompt.choices.map(\.detail) == [nil, "Hot"])
    }

    @Test func aMultipleChoiceQuestionLetsTheUserChooseAny() throws {
        let question = try #require(try card(asking([fruits])).question)
        #expect(question.multiSelectHint.map(en) == "Choose any")
        #expect(question.choices.map(\.number) == [1, 2, 3, 4])
        #expect(question.choices.last?.label == .other)
        #expect(question.moreText == nil)
    }

    /// "Other" is the source's free-text entry: a tool without one gets
    /// neither it nor the hint to type an own answer.
    @Test func aQuestionWithoutAnOwnAnswerOffersOnlyItsOptions() throws {
        let closed = Question(text: "Tea or coffee?", options: [QuestionOption(label: "tea"), QuestionOption(label: "coffee")])
        let question = try #require(try card(asking([closed])).question)
        #expect(question.choices == [
            QuestionChoice(number: 1, label: .option("tea"), detail: nil),
            QuestionChoice(number: 2, label: .option("coffee"), detail: nil),
        ])
        #expect(en(question.answerHint) == "Answer in Terminal: type a number.")
        #expect(en(question.accessibilityText) == "Choose one: Tea or coffee? Options: 1 tea; 2 coffee. Answer in Terminal.")
    }

    /// Nothing to number: no "Other" alone.
    @Test func aQuestionWithoutOptionsShowsNoChoices() throws {
        let question = try #require(try card(asking([Question(text: "Anything else?")])).question)
        #expect(question.header == nil)
        #expect(question.choices.isEmpty)
        // Nothing to pick, so no "type a number" either.
        #expect(en(question.answerHint) == "Answer in Terminal.")
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsTheQuestionItsOptionsAndWhereToAnswer() throws {
        let one = try #require(try card(asking([mapping])).question)
        #expect(en(one.accessibilityText)
            == "Mapping, choose one: Which mapping revision should the adapter read? Options: 1 Revision 5, The bundled one; 2 Revision 6; 3 Other. Answer in Terminal.")

        let two = try #require(try card(asking([fruits, mapping])).question)
        #expect(en(two.accessibilityText)
            == "Fruits, choose any: Which fruits do you like? Options: 1 apple; 2 banana; 3 cherry; 4 Other. +1 more question. Answer in Terminal.")

        let bare = try #require(try card(asking([Question(text: "Anything else?")])).question)
        #expect(en(bare.accessibilityText) == "Choose one: Anything else? Answer in Terminal.")
    }

    // MARK: Agents

    /// Like a permission request, any agent's question makes the card; the
    /// orchestrator's comes first, else the subagent's that asked last.
    @Test func theOrchestratorsQuestionComesFirstThenTheNewestSubagents() throws {
        let spawned: [AgentEvent.Kind] = [
            .promptSubmitted("Go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", title: "A")),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec(type: "explore", title: "B")),
            .questionAsked(agent: .subagent("a"), [fruits]),
            .questionAsked(agent: .subagent("b"), [mapping]),
        ]
        let subagents = try #require(try card(spawned).question)
        #expect(subagents.header == "Mapping")
        #expect(subagents.count == 2)

        let all = try #require(try card(spawned + [.questionAsked(agent: .root, [Question(header: "Root", text: "Go on?")])]).question)
        #expect(all.header == "Root")
        #expect(all.count == 3)
        #expect(all.moreCount == 2)
    }

    /// Archiving an agent says the user has seen to it, as for the menu bar.
    @Test func anArchivedAgentsQuestionMakesNoQuestionCard() throws {
        var s = state(session("s1", [
            .promptSubmitted("Go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", title: "A")),
            .questionAsked(agent: .subagent("a"), [fruits]),
        ]))
        s.archive(.agent(key("s1"), .subagent("a")), at: t0.addingTimeInterval(10))
        let item = try #require(model(s).sessions.first)
        #expect(item.cardState == .working)
        #expect(item.question == nil)
    }

    // MARK: Idle

    /// An open question is a call to act: the session never goes idle.
    @Test func aSessionAskingStaysOutOfTheIdleGroup() throws {
        let asked = state(session("s1", [.promptSubmitted("Go"), .turnEnded(), .questionAsked(agent: .root, [mapping])]))
        let open = model(asked, at: 3_600, idleAfter: .fiveMinutes)
        #expect(open.idle.isEmpty)
        #expect(open.sessions.first?.cardState == .question)
        #expect(open.sessions.first?.rowStatus == .question(count: 1))

        let resting = state(session("s1", [.promptSubmitted("Go"), .turnEnded()]))
        #expect(model(resting, at: 3_600, idleAfter: .fiveMinutes).idle.count == 1)
    }

    /// A finished row has no surface, and no question either.
    @Test func onlyAnActiveCardShowsTheQuestion() throws {
        let ended = state(session("s1", asking([mapping]) + [.sessionEnded]))
        let row = try #require(model(ended).finished.first)
        #expect(row.cardState == nil)
        #expect(row.question == nil)
        #expect(row.rowStatus == .done)
    }
}

// MARK: - Captured run

private let s4 = Timeline("4-waiting-permission-question")

/// S4 (2.1.287): `AskUserQuestion` asked with 026 and again with 028, answered with 031.
@Suite struct PopoverModelQuestionFixtureTests {
    private func item(through n: Int) throws -> SessionItem {
        let state = try s4.replay(through: n)
        let now = s4.entry(n: n).at.addingTimeInterval(1)
        return try #require(PopoverModel(state: state, now: now, settings: PopoverSettings(idleAfter: .never)).sessions.first)
    }

    @Test func theCapturedQuestionMakesOneQuestionCardUntilAnswered() throws {
        for n in [26, 27, 28, 29] {
            let item = try item(through: n)
            #expect(item.cardState == .question, "S4 \(n)")
            #expect(item.rowStatus == .question(count: 1), "S4 \(n)")
        }
        let question = try #require(try item(through: 28).question)
        #expect(question.header == "Color preference")
        #expect(question.text == "Which color do you like?")
        #expect(question.choices.map(\.label) == [.option("Red"), .option("Blue"), .other])

        let answered = try item(through: 31)
        #expect(answered.cardState != .question)
        #expect(answered.question == nil)
    }
}
