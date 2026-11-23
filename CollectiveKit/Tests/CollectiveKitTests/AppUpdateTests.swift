import Foundation
import Testing
@testable import CollectiveKit

// The app's own update state and About's status line.

private let gmt = TimeZone(identifier: "GMT")!
/// Thursday, 14 November 2024, 14:02 GMT.
private let now = Date(timeIntervalSince1970: 1_731_592_920)
private let minute: TimeInterval = 60
private let day: TimeInterval = 24 * 3600

private func en(_ resource: LocalizedStringResource?) -> String? {
    guard var resource else { return nil }
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@MainActor
private func line(_ state: AppUpdateState, automatic: Bool = true, at date: Date = now) -> AppUpdateStatusLine {
    AppUpdateStatusLine(state, checksAutomatically: automatic, now: date, timeZone: gmt)
}

@MainActor @Suite struct AppUpdateStateTests {
    @Test func aNewerVersionIsAvailableUntilACheckFindsNone() {
        let state = AppUpdateState(installed: "1.2.0")
        state.checkStarted(.automatic)
        state.found("1.3.0", at: now)
        #expect(state.available == SubspaceVersion("1.3.0"))
        #expect(state.lastCheck == now)
        #expect(state.checking == nil)
        state.checkStarted(.automatic)
        state.foundNothing(at: now + minute)
        #expect(state.available == nil)
        #expect(state.lastCheck == now + minute)
    }

    /// The updater only reports newer versions, but the state doesn't rely on it.
    @Test func theSameOrAnOlderOrAnUnreadableVersionOffersNothing() {
        for version in ["1.2.0", "1.1.9", "1.3", "1.3.0-beta.1"] {
            let state = AppUpdateState(installed: "1.2.0")
            state.found(version, at: now)
            #expect(state.available == nil, "\(version)")
        }
        let unknown = AppUpdateState(installed: nil)
        unknown.found("1.3.0", at: now)
        #expect(unknown.available == nil)
    }

    /// Only `Check Now` reports a failure; either way the last result stays.
    @Test func onlyAFailedCheckNowShowsAndTheLastResultStays() {
        let state = AppUpdateState(installed: "1.2.0", lastCheck: now - day)
        state.found("1.3.0", at: now - day)
        state.checkStarted(.automatic)
        state.checkFailed()
        #expect(!state.failed)
        #expect(state.available == SubspaceVersion("1.3.0"))
        #expect(state.lastCheck == now - day)
        state.checkStarted(.manual)
        state.checkFailed()
        #expect(state.failed)
        #expect(state.available == SubspaceVersion("1.3.0"))
        state.checkStarted(.automatic)
        #expect(!state.failed)
    }

    @Test func skippingRemovesTheOffer() {
        let state = AppUpdateState(installed: "1.2.0")
        state.found("1.3.0", at: now)
        state.skipped()
        #expect(state.available == nil)
    }
}

@MainActor @Suite struct AppUpdateStatusLineTests {
    @Test func upToDateTellsWhenItLastChecked() {
        let state = AppUpdateState(installed: "1.2.0")
        state.foundNothing(at: now)
        let status = line(state)
        #expect(status.mark == SourceStatusMark(shape: .dot, role: .success))
        #expect(en(status.status) == "Up to date")
        #expect(en(status.detail) == "· checked today at 2:02\u{202F}PM")
        #expect(status.explanation == nil)
        #expect(status.button == .checkNow(enabled: true))
    }

    @Test(arguments: [
        (now - day, "· checked yesterday at 2:02\u{202F}PM"),
        // Just after midnight it is already today's check.
        (now - 14 * 3600, "· checked today at 12:02\u{202F}AM"),
        (now - 15 * 3600, "· checked yesterday at 11:02\u{202F}PM"),
        (now - 2 * day, "· checked on Nov 12"),
        (now - 365 * day, "· checked on Nov 15, 2023"),
        // A clock set back.
        (now + day, "· checked today at 2:02\u{202F}PM"),
    ])
    func anOlderCheckReadsRelative(lastCheck: Date, text: String) {
        let state = AppUpdateState(installed: "1.2.0")
        state.foundNothing(at: lastCheck)
        #expect(en(line(state).detail) == text)
    }

    @Test func beforeTheFirstCheckOnlyTheStatusShows() {
        let status = line(AppUpdateState(installed: "1.2.0"))
        #expect(en(status.status) == "Up to date")
        #expect(status.detail == nil)
    }

    @Test func automaticChecksOffReplacesTheTime() {
        let state = AppUpdateState(installed: "1.2.0")
        state.foundNothing(at: now)
        #expect(en(line(state, automatic: false).detail) == "· automatic checks are off")
    }

    @Test func checkingDisablesCheckNow() {
        let state = AppUpdateState(installed: "1.2.0")
        state.found("1.3.0", at: now)
        state.checkStarted(.manual)
        let status = line(state)
        #expect(status.mark == SourceStatusMark(shape: .hollowRing, role: .textSubtle))
        #expect(en(status.status) == "Checking for updates…")
        #expect(status.detail == nil)
        #expect(status.button == .checkNow(enabled: false))
    }

    /// `Check Now` also looks up the subspace plugins; the line waits for them too.
    @Test func thePluginLookupKeepsTheLineChecking() {
        let state = AppUpdateState(installed: "1.2.0")
        state.foundNothing(at: now)
        let status = AppUpdateStatusLine(state, checksAutomatically: true, pluginsChecking: true, now: now, timeZone: gmt)
        #expect(en(status.status) == "Checking for updates…")
        #expect(status.button == .checkNow(enabled: false))
    }

    @Test func anAvailableUpdateLeadsWithUpdate() {
        let state = AppUpdateState(installed: "1.2.0")
        state.found("1.3.0", at: now)
        let status = line(state)
        #expect(status.mark == SourceStatusMark(shape: .circleArrowUp, role: .info))
        #expect(en(status.status) == "1.3.0 is available")
        #expect(en(status.detail) == "· you have 1.2.0")
        #expect(status.button == .update)
    }

    @Test func aFailedCheckNowExplainsItself() {
        let state = AppUpdateState(installed: "1.2.0")
        state.checkStarted(.manual)
        state.checkFailed()
        let status = line(state)
        #expect(status.mark == SourceStatusMark(shape: .circleX, role: .danger))
        #expect(en(status.status) == "Couldn’t check for updates")
        #expect(status.detail == nil)
        #expect(en(status.explanation) == "GitHub didn’t answer. Check your connection, then try again.")
        #expect(status.button == .checkNow(enabled: true))
    }
}
