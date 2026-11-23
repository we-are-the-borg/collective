import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The popover footer's update link and restart hint.

private let t0 = Date(timeIntervalSince1970: 1_000)

private func version(_ text: String) -> SubspaceVersion { SubspaceVersion(text)! }

private func tool(_ source: SourceID, _ plugin: IntegrationStatus.Plugin = .enabled(version: "1.0.1")) -> IntegrationStatus {
    IntegrationStatus(
        source: source, toolName: source.rawValue, cliName: "claude",
        cli: .found(path: "/usr/local/bin/claude", version: "2.1.285"), plugin: plugin,
        lastSessionStartAt: t0, commands: ClaudeCodeSubspace.commands
    )
}

private let available = UpdateAvailability.available(installed: version("1.0.1"), latest: version("1.3.0"))
private let required = UpdateAvailability.required(installed: version("1.0.1"), minimum: version("1.1.0"), latest: nil)

private func makeLink(
    _ statuses: [IntegrationStatus],
    _ availability: [SourceID: UpdateAvailability],
    checksForUpdates: Bool = true,
    app: String? = nil
) -> UpdateFooterLink? {
    UpdateFooterLink(statuses: statuses, availability: availability, checksForUpdates: checksForUpdates,
                     appUpdate: app.map(version))
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@Suite struct UpdateFooterLinkTests {
    @Test func availableUpdateLinksToItsSource() throws {
        let link = try #require(makeLink([tool("a")], ["a": available]))
        #expect(link.target == .source("a"))
        #expect(en(link.text) == "Update available")
        #expect(link.role == .info)
    }

    @Test func requiredBeatsAnEarlierAvailable() throws {
        let link = try #require(makeLink([tool("a"), tool("b")], ["a": available, "b": required]))
        #expect(link.target == .source("b"))
        #expect(en(link.text) == "Update required")
        #expect(link.role == .warning)
    }

    @Test func firstInOrderWinsAmongEquals() {
        #expect(makeLink([tool("b"), tool("a")], ["a": available, "b": available])?.target == .source("b"))
        #expect(makeLink([tool("b"), tool("a")], ["a": required, "b": required])?.target == .source("b"))
    }

    @Test func noLinkWithoutAnUpdate() {
        #expect(makeLink([tool("a")], [:]) == nil)
        #expect(makeLink([tool("a")], ["a": .upToDate]) == nil)
        // The pane offers nothing for a source that isn't installed either.
        #expect(makeLink([tool("a", .notInstalled)], ["a": required]) == nil)
    }

    /// An app update ranks between a required and an available subspace update, and opens the app's update window.
    @Test func anAppUpdateRanksBetweenRequiredAndAvailable() throws {
        let app = try #require(makeLink([tool("a")], ["a": available], app: "1.3.0"))
        #expect(app.target == .app)
        #expect(app.kind == .app(version("1.3.0")))
        #expect(en(app.text) == "App update available")
        #expect(en(app.help) == "The Collective 1.3.0 is available")
        #expect(app.role == .info)
        #expect(makeLink([tool("a")], ["a": required], app: "1.3.0")?.target == .source("a"))
        #expect(makeLink([tool("a")], [:], app: "1.3.0")?.target == .app)
    }

    /// A subspace link's tooltip is its text.
    @Test func aSourceLinksHelpIsItsText() throws {
        let link = try #require(makeLink([tool("a")], ["a": required]))
        #expect(en(link.help) == "Update required")
    }

    @Test func switchOffLeavesOnlyRequired() {
        #expect(makeLink([tool("a")], ["a": available], checksForUpdates: false) == nil)
        #expect(makeLink([tool("a"), tool("b")], ["a": available, "b": required], checksForUpdates: false)?.target == .source("b"))
    }
}

/// One working session started at t0.
private func state(_ sessions: [(SourceID, String, Date)] = [("a", "s1", t0)]) -> CollectiveState {
    var state = CollectiveState()
    for (source, id, startedAt) in sessions {
        state.apply(AgentEvent(session: SessionKey(source: source, sessionID: id), timestamp: startedAt,
                               kind: .sessionStarted(cwd: "/tmp/\(id)", pid: nil)))
    }
    return state
}

private func popover(
    _ state: CollectiveState = state(),
    connection: ConnectionStatus = .ok,
    updateLink: UpdateFooterLink? = nil,
    restartHints: SubspaceRestartHints = SubspaceRestartHints(),
    isLoading: Bool = false,
    now: Date = t0.addingTimeInterval(100)
) -> PopoverModel {
    PopoverModel(state: state, now: now, settings: PopoverSettings(), lastEventAt: t0, isLoading: isLoading,
                 connection: connection, updateLink: updateLink, restartHints: restartHints)
}

/// Each source rose from 1.0.1 to its version in a probe started at its date.
private func hints(_ rises: [(SourceID, String, Date)]) -> SubspaceRestartHints {
    var hints = SubspaceRestartHints()
    for (source, version, at) in rises {
        hints.observe([tool(source)], probeStartedAt: at.addingTimeInterval(-60))
        hints.observe([tool(source, .enabled(version: version))], probeStartedAt: at)
    }
    return hints
}

private let updatedAt = t0.addingTimeInterval(50)

@Suite struct PopoverUpdateLinkTests {
    @Test func footerShowsTheLink() {
        let link = UpdateFooterLink(statuses: [tool("a")], availability: ["a": available], checksForUpdates: true)
        #expect(link != nil)
        #expect(popover(updateLink: link).footerLink == link)
        #expect(popover().footerLink == nil)
    }

    /// The warning block comes first.
    @Test func noLinkWhileAWarningShows() {
        let link = UpdateFooterLink(statuses: [tool("a")], availability: ["a": required], checksForUpdates: true)
        for connection in [ConnectionStatus.missing(tool("a", .notInstalled)), .disabled(tool("a", .disabled(version: "1.0.1")))] {
            #expect(popover(connection: connection, updateLink: link).footerLink == nil)
        }
    }
}

@Suite struct PopoverRestartHintTests {
    private let now = t0.addingTimeInterval(100)

    @Test func olderRunningSessionAsksForARestart() {
        let popover = popover(restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "Restart sessions to use subspace 1.1.0"])
        #expect(popover.footerCountsFrom == nil)
    }

    @Test func sessionStartedAfterTheUpdateNeedsNoRestart() {
        let popover = popover(state([("a", "s1", updatedAt.addingTimeInterval(1))]), restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "last event 1 min ago"])
        #expect(popover.footerCountsFrom == t0)
    }

    @Test func onlySessionsOfTheUpdatedSourceCount() {
        let popover = popover(state([("b", "s1", t0)]), restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "last event 1 min ago"])
    }

    @Test func noRunningSessionNoHint() {
        let popover = popover(CollectiveState(), restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "listening"])
    }

    @Test func notWhileReading() {
        let popover = popover(restartHints: hints([("a", "1.1.0", updatedAt)]), isLoading: true)
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "reading events…"])
    }

    @Test func finishedSessionDoesNotCount() {
        var state = state()
        state.apply(AgentEvent(session: SessionKey(source: "a", sessionID: "s1"), timestamp: t0.addingTimeInterval(1), kind: .sessionEnded))
        let popover = popover(state, restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.finished.count == 1)
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "last event 1 min ago"])
    }

    @Test func idleSessionCounts() {
        var state = state()
        let key = SessionKey(source: "a", sessionID: "s1")
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(1), kind: .promptSubmitted("go")))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(2), kind: .turnEnded()))
        let popover = PopoverModel(state: state, now: t0.addingTimeInterval(400), settings: PopoverSettings(idleAfter: .fiveMinutes),
                                   lastEventAt: t0, restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.idle.count == 1)
        #expect(popover.footerParts(at: now).map(en) == ["Linked to subspace", "Restart sessions to use subspace 1.1.0"])
    }

    @Test func latestUpdateWinsAmongSources() {
        let state = state([("a", "s1", t0), ("b", "s2", t0)])
        let rises: [(SourceID, String, Date)] = [("a", "1.2.0", updatedAt), ("b", "1.1.0", updatedAt.addingTimeInterval(10))]
        #expect(popover(state, restartHints: hints(rises)).footerParts(at: now).map(en).last == "Restart sessions to use subspace 1.1.0")
    }

    /// The warning's own footer line stays.
    @Test func notWhileAWarningShows() {
        let popover = popover(connection: .missing(tool("a", .notInstalled)), restartHints: hints([("a", "1.1.0", updatedAt)]))
        #expect(popover.footerParts(at: now).map(en) == ["subspace not installed"])
    }
}
