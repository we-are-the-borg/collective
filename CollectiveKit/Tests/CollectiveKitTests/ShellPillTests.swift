import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Events of one session, one second apart.
private func session(_ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key("s1"), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind)
    }
}

private func card(_ kinds: [AgentEvent.Kind]) throws -> SessionItem {
    var state = CollectiveState()
    for event in session(kinds) { state.apply(event) }
    let model = PopoverModel(state: state, now: t0.addingTimeInterval(60), settings: PopoverSettings(idleAfter: .never))
    return try #require(model.sessions.first)
}

/// A turn that ends listing `shells`, then the live report of a shell.
private func shellCard(_ shells: [BackgroundShell], before: [AgentEvent.Kind] = []) throws -> SessionItem {
    try card([.promptSubmitted("Go")] + before + [.turnEnded(), .backgroundShellsListed(shells), .activityReported(.backgroundShell)])
}

/// The listing's time in `shellCard`: the third event without `before`.
private let listedAt = t0.addingTimeInterval(2)

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// The short time as the English tooltip writes it, in the current time zone.
private func enTime(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en")))
}

/// The tooltip as its lines, head and foot resolved in English.
private func lines(_ pill: ShellPill) -> [String]? {
    pill.tooltip.map { tip in [en(tip.head)] + tip.shells + (tip.foot.map { [en($0)] } ?? []) }
}

private let build = BackgroundShell(id: "b1", command: "make build", description: "Build the app")
private let watch = BackgroundShell(id: "b2", command: "npm run watch")
private let described = BackgroundShell(id: "b3", description: "Tail the server log")
private let bare = BackgroundShell(id: "b4")

/// The shell pill names what the last turn end listed.
@Suite struct ShellPillTests {
    @Test func oneListedShellIsNamedByItsCommand() throws {
        let item = try shellCard([build])
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shell running, make build")
        #expect(pill.shellText == "make build")
        #expect(lines(pill) == ["As of last turn end · \(enTime(listedAt))", "make build"])
    }

    @Test func withoutACommandTheDescriptionNamesIt() throws {
        let pill = try #require(try shellCard([described]).shellPill)
        #expect(pill.shellText == "Tail the server log")
        #expect(lines(pill) == ["As of last turn end · \(enTime(listedAt))", "Tail the server log"])
    }

    /// Listed, but with nothing to say: the head alone tells when.
    @Test func aListedShellWithNeitherHasNoText() throws {
        let item = try shellCard([bare])
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shell running")
        #expect(pill.shellText == nil)
        #expect(lines(pill) == ["As of last turn end · \(enTime(listedAt))"])
    }

    /// No number and no description: the listing may be stale.
    @Test func twoListedShellsAreNamedOnlyInTheTooltip() throws {
        let item = try shellCard([build, bare, described])
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shells running")
        #expect(pill.shellText == nil)
        #expect(lines(pill) == [
            "As of last turn end · \(enTime(listedAt))", "make build", "Tail the server log", "Some may have finished since.",
        ])
    }

    @Test func noListedShellHasNoTextAndNoTooltip() throws {
        let item = try card([.promptSubmitted("Go"), .turnEnded(), .activityReported(.backgroundShell)])
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shell running")
        #expect(pill.shellText == nil)
        #expect(pill.tooltip == nil)
    }

    /// An empty listing is a listing of none.
    @Test func anEmptyListingHasNoTooltip() throws {
        let item = try shellCard([])
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shell running")
        #expect(pill.tooltip == nil)
    }

    /// Next to background agents the shell keeps its listing.
    @Test func nextToBackgroundAgentsTheShellKeepsItsListing() throws {
        let spawn = AgentEvent.Kind.agentSpawned(id: "bg", parent: .root, spec: AgentSpec(type: "explore", title: "BG", isBackground: true))
        let item = try shellCard([build], before: [spawn])
        let pill = try #require(item.shellPill)
        #expect(item.cardState == .working)
        #expect(pill.shellText == "make build")
        #expect(lines(pill) == ["As of last turn end · \(enTime(listedAt.addingTimeInterval(1)))", "make build"])
    }

    /// A new turn keeps the pill and what it says until the next turn end lists anew.
    @Test func aNewTurnKeepsTheNamedPill() throws {
        let item = try card([
            .promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed([build]), .activityReported(.backgroundShell),
            .promptSubmitted("And now?"),
        ])
        #expect(item.cardState == .working)
        let pill = try #require(item.shellPill)
        #expect(pill.shellText == "make build")
    }

    /// The source reports the new turn working, not the shell: the pill stays.
    @Test func aWorkingReportKeepsTheNamedPill() throws {
        let item = try card([
            .promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed([build]), .activityReported(.backgroundShell),
            .activityReported(.working), .promptSubmitted("And now?"),
        ])
        #expect(item.cardState == .working)
        #expect(try #require(item.shellPill).shellText == "make build")
    }

    /// A working row keeps the orchestrator's tool as its detail next to the shell pill.
    @Test func aWorkingRowWithAShellKeepsItsToolDetail() throws {
        let read = ToolActivity(name: "Read", detail: "Package.swift")
        let item = try card([.promptSubmitted("Go"), .backgroundShellStarted(id: "b1"), .toolStarted(agent: .root, read)])
        #expect(item.shellPill != nil)
        #expect(item.rowStatus == .working)
        #expect(item.rowDetail == .tool(read))
    }

    /// Started during the turn, before any listing: only that a shell runs is certain.
    @Test func aShellStartedInTheTurnHasNoTextAndNoTooltip() throws {
        let item = try card([.promptSubmitted("Go"), .backgroundShellStarted(id: "b1")])
        #expect(item.cardState == .working)
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "working, shell running")
        #expect(pill.shellText == nil)
        #expect(pill.tooltip == nil)
    }

    /// A listing from before the start names other shells than run now,
    /// until the turn's end lists them all.
    @Test func aShellStartedAfterTheListingHidesItUntilTheNextOne() throws {
        let before: [AgentEvent.Kind] = [
            .promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed([build]), .activityReported(.backgroundShell),
            .promptSubmitted("And now?"), .backgroundShellStarted(id: "b2"),
        ]
        let startedItem = try card(before)
        let started = try #require(startedItem.shellPill)
        #expect(startedItem.statusAccessibilityText.map(en) == "working, shell running")
        #expect(started.shellText == nil)
        #expect(started.tooltip == nil)

        let listedItem = try card(before + [.turnEnded(), .backgroundShellsListed([build, watch])])
        let listed = try #require(listedItem.shellPill)
        #expect(listedItem.statusAccessibilityText.map(en) == "shells running")
        #expect(listed.tooltip?.shells == ["make build", "npm run watch"])
    }

    /// Hook times are whole seconds: a start in the listing's second may
    /// come after it, so the listing can't be said to name it.
    @Test func aShellStartedInTheListingsSecondHidesIt() throws {
        var state = CollectiveState()
        let kinds: [(TimeInterval, AgentEvent.Kind)] = [
            (0, .promptSubmitted("Go")), (1, .turnEnded()), (1, .backgroundShellsListed([build])),
            (2, .promptSubmitted("And now?")), (3, .backgroundShellStarted(id: "b2")),
            (3, .turnEnded()), (3, .backgroundShellsListed([build])),
        ]
        for (offset, kind) in kinds {
            state.apply(AgentEvent(session: key("s1"), timestamp: t0.addingTimeInterval(offset), kind: kind))
        }
        let model = PopoverModel(state: state, now: t0.addingTimeInterval(60), settings: PopoverSettings(idleAfter: .never))
        let item = try #require(model.sessions.first)
        let pill = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shell running")
        #expect(pill.shellText == nil)
        #expect(pill.tooltip == nil)
    }

    // MARK: VoiceOver

    /// The status word once, then what the row's shell line names, as the row reads.
    @Test func theShellRowsLabelSaysTheStatusWordThenTheShell() throws {
        #expect(try shellCard([build]).statusAccessibilityText.map(en) == "shell running, make build")
        #expect(try shellCard([described]).statusAccessibilityText.map(en) == "shell running, Tail the server log")
        #expect(try shellCard([bare]).statusAccessibilityText.map(en) == "shell running")
        #expect(try shellCard([build, watch]).statusAccessibilityText.map(en) == "shells running")
    }

    /// A working row draws no shell line, yet its label still names the
    /// shell as the shell's row would, after the status word: today's label
    /// said "Background shell running" there too.
    @Test func aWorkingRowsLabelNamesTheShellAfterTheStatusWord() throws {
        let item = try card([
            .promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed([build]), .activityReported(.backgroundShell),
            .promptSubmitted("And now?"),
        ])
        #expect(item.shellPill != nil)
        #expect(item.statusAccessibilityText.map(en) == "working, shell running, make build")

        let several = try card([
            .promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed([build, watch]), .activityReported(.backgroundShell),
            .promptSubmitted("And now?"),
        ])
        #expect(several.statusAccessibilityText.map(en) == "working, shells running")
    }
}
