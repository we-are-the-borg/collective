import Foundation
import Testing
@testable import CollectiveKit

@Suite struct LoadingIndicatorTests {
    let launch = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ offset: TimeInterval) -> Date { launch.addingTimeInterval(offset) }

    private func indicator(finishedAfter offset: TimeInterval?) -> LoadingIndicator {
        LoadingIndicator(launchedAt: launch, backlogFinishedAt: offset.map(at))
    }

    @Test func fastReadNeverShowsLoading() {
        let indicator = indicator(finishedAfter: 0.299)
        for offset in [0.1, 0.3, 1] {
            #expect(!indicator.isVisible(at: at(offset)))
        }
        #expect(indicator.nextChange(after: at(0)) == nil)
    }

    @Test func readFinishingExactlyAtTheDelayNeverShowsLoading() {
        let indicator = indicator(finishedAfter: 0.3)
        for offset in [0.1, 0.3, 0.5, 1] {
            #expect(!indicator.isVisible(at: at(offset)))
        }
        #expect(indicator.nextChange(after: at(0)) == nil)
    }

    @Test func readJustPastTheDelayShowsLoadingForTheMinimumDuration() {
        let indicator = indicator(finishedAfter: 0.301)
        #expect(!indicator.isVisible(at: at(0.299)))
        #expect(indicator.isVisible(at: at(0.3)))
        #expect(indicator.isVisible(at: at(0.799)))
        #expect(!indicator.isVisible(at: at(0.8)))
        #expect(indicator.nextChange(after: at(0.4)) == at(0.8))
    }

    @Test func slowReadHidesLoadingWhenItFinishes() {
        let indicator = indicator(finishedAfter: 2)
        #expect(!indicator.isVisible(at: at(0.299)))
        #expect(indicator.isVisible(at: at(0.3)))
        #expect(indicator.isVisible(at: at(1.999)))
        #expect(!indicator.isVisible(at: at(2)))
        #expect(indicator.nextChange(after: at(1)) == at(2))
    }

    @Test func unfinishedReadShowsLoadingAfterTheDelay() {
        let indicator = indicator(finishedAfter: nil)
        #expect(!indicator.isVisible(at: at(0.299)))
        #expect(indicator.isVisible(at: at(0.3)))
        #expect(indicator.isVisible(at: at(60)))
        #expect(indicator.nextChange(after: at(0)) == at(0.3))
        #expect(indicator.nextChange(after: at(1)) == nil)
    }
}
