import Foundation
import Testing
@testable import CollectiveKit

@Suite struct MenuBarAnimationPreferenceTests {
    @Test func theDefaultIsTodaysMotion() {
        let animation = MenuBarAnimation()
        #expect(animation.level == .always)
        #expect(animation.frameRate == .smooth)
    }

    @Test(arguments: MenuBarAnimation.Level.allCases, MenuBarAnimation.FrameRate.allCases)
    func aStoredChoiceLoadsBack(level: MenuBarAnimation.Level, frameRate: MenuBarAnimation.FrameRate) {
        let animation = MenuBarAnimation(level: level, frameRate: frameRate)
        #expect(MenuBarAnimation(fromStored: animation.stored) == animation)
    }

    @Test func theStoredFormNamesBothChoices() {
        let stored = MenuBarAnimation(level: .whenNeeded, frameRate: .low).stored
        #expect(stored["level"] as? String == "whenNeeded")
        #expect(stored["frameRate"] as? String == "low")
    }

    @Test func missingOrDamagedValuesFallBackToTheDefault() {
        #expect(MenuBarAnimation(fromStored: nil) == MenuBarAnimation())
        #expect(MenuBarAnimation(fromStored: "always") == MenuBarAnimation())
        #expect(MenuBarAnimation(fromStored: ["level": 3, "frameRate": true]) == MenuBarAnimation())
        #expect(MenuBarAnimation(fromStored: ["level": "sometimes", "frameRate": "ultra"]) == MenuBarAnimation())
        // Each choice falls back on its own.
        #expect(MenuBarAnimation(fromStored: ["level": "never"]) == MenuBarAnimation(level: .never, frameRate: .smooth))
        #expect(MenuBarAnimation(fromStored: ["frameRate": "balanced", "level": "?"]) == MenuBarAnimation(level: .always, frameRate: .balanced))
    }

    @Test func theFrameRatesAreTwelveEightAndFour() {
        #expect(MenuBarAnimation.FrameRate.allCases == [.smooth, .balanced, .low])
        #expect(MenuBarAnimation.FrameRate.allCases.map(\.framesPerSecond) == [12, 8, 4])
        #expect(MenuBarAnimation.Level.allCases == [.always, .whenNeeded, .never])
    }
}

private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

private let everyAnimation = MenuBarAnimation.Level.allCases.flatMap { level in
    MenuBarAnimation.FrameRate.allCases.map { MenuBarAnimation(level: level, frameRate: $0) }
}

/// Which icon moves under which setting.
@Suite struct MenuBarAnimationRuleTests {
    private static let moving: [MenuBarIcon] = [.working(count: 2), .needsPermission, .question, .backgroundShell]
    private static let still: [MenuBarIcon] = [.idle, .warning, .working(count: 0)]

    @Test(arguments: MenuBarAnimation.FrameRate.allCases)
    func alwaysMovesEveryDrawnState(rate: MenuBarAnimation.FrameRate) {
        let animation = MenuBarAnimation(level: .always, frameRate: rate)
        for icon in Self.moving {
            #expect(icon.moves(animation: animation, reduceMotion: false), "\(icon)")
            #expect(icon.nextSceneChange(after: at(5), animation: animation, reduceMotion: false) != nil, "\(icon)")
        }
    }

    @Test(arguments: MenuBarAnimation.FrameRate.allCases)
    func whenNeededMovesOnlyPermissionAndQuestion(rate: MenuBarAnimation.FrameRate) {
        let animation = MenuBarAnimation(level: .whenNeeded, frameRate: rate)
        for icon in [MenuBarIcon.needsPermission, .question] {
            #expect(icon.moves(animation: animation, reduceMotion: false), "\(icon)")
            #expect(icon.nextSceneChange(after: at(5), animation: animation, reduceMotion: false) != nil, "\(icon)")
        }
        for icon in [MenuBarIcon.working(count: 2), .backgroundShell] {
            #expect(!icon.moves(animation: animation, reduceMotion: false), "\(icon)")
            #expect(icon.nextSceneChange(after: at(5), animation: animation, reduceMotion: false) == nil, "\(icon)")
        }
    }

    @Test(arguments: MenuBarAnimation.FrameRate.allCases)
    func neverMovesNothing(rate: MenuBarAnimation.FrameRate) {
        let animation = MenuBarAnimation(level: .never, frameRate: rate)
        for icon in Self.moving + Self.still {
            #expect(!icon.moves(animation: animation, reduceMotion: false), "\(icon)")
            #expect(icon.nextSceneChange(after: at(5), animation: animation, reduceMotion: false) == nil, "\(icon)")
        }
    }

    @Test(arguments: everyAnimation)
    func reduceMotionWinsAtEveryLevel(animation: MenuBarAnimation) {
        for icon in Self.moving + Self.still {
            #expect(!icon.moves(animation: animation, reduceMotion: true), "\(icon)")
            #expect(icon.nextSceneChange(after: at(5), animation: animation, reduceMotion: true) == nil, "\(icon)")
        }
    }

    @Test(arguments: everyAnimation)
    func idleAndWarningNeverMove(animation: MenuBarAnimation) {
        for icon in Self.still {
            #expect(!icon.moves(animation: animation, reduceMotion: false), "\(icon)")
            #expect(icon.nextSceneChange(after: at(5), animation: animation, reduceMotion: false) == nil, "\(icon)")
        }
    }
}

/// How a moving icon is sampled at each frame rate, and what a still one shows.
@Suite struct MenuBarAnimationTimingTests {
    private static let pairs: [(MenuBarIcon, MenuBarAnimation.Level)] = [
        (.working(count: 3), .always), (.needsPermission, .always), (.question, .always), (.backgroundShell, .always),
        (.needsPermission, .whenNeeded), (.question, .whenNeeded),
    ]

    private func scene(_ icon: MenuBarIcon, _ seconds: Double, _ rate: MenuBarAnimation.FrameRate, level: MenuBarAnimation.Level = .always) throws -> MenuBarScene {
        try #require(icon.scene(at: at(seconds), appearance: .light, animation: MenuBarAnimation(level: level, frameRate: rate), reduceMotion: false))
    }

    /// Every rate's slots start on whole ticks of the scene clock.
    @Test func everyRateDividesTheSceneClock() {
        #expect(MenuBarScene.ticksPerSecond == 24)
        for rate in MenuBarAnimation.FrameRate.allCases {
            #expect(MenuBarScene.ticksPerSecond % rate.framesPerSecond == 0, "\(rate)")
        }
    }

    /// The app sleeps until the returned date and draws that date: one frame
    /// later each time, already inside the new frame.
    @Test(arguments: MenuBarAnimation.FrameRate.allCases)
    func consecutiveChangesAreOneFrameApart(rate: MenuBarAnimation.FrameRate) throws {
        let f = Double(rate.framesPerSecond)
        for (icon, level) in Self.pairs {
            let animation = MenuBarAnimation(level: level, frameRate: rate)
            for base in [0.0, 0.04, 1.0 / 3, 1_000, 781_000_000.123, -12_345.678] {
                var date = at(base)
                var frame = (base * f).rounded(.down)
                for _ in 0..<30 {
                    let next = try #require(icon.nextSceneChange(after: date, animation: animation, reduceMotion: false))
                    #expect(next > date)
                    #expect(abs(next.timeIntervalSinceReferenceDate - (frame + 1) / f) < 1e-6, "\(icon) \(rate) after \(base)")
                    #expect((next.timeIntervalSinceReferenceDate * f).rounded(.down) == frame + 1, "\(icon) \(rate) after \(base)")
                    date = next
                    frame += 1
                }
            }
        }
    }

    /// 8 fps steps every 1/8 s: after 1 s comes 1.125 s, halfway between two ticks of 12 fps.
    @Test func eightFramesPerSecondStepEveryEighthOfASecond() throws {
        let animation = MenuBarAnimation(level: .always, frameRate: .balanced)
        let next = try #require(MenuBarIcon.working(count: 1).nextSceneChange(after: at(1.0), animation: animation, reduceMotion: false))
        #expect(abs(next.timeIntervalSinceReferenceDate - 1.125) < 1e-9)
    }

    /// A frame shows the scene at the start of its slot, so a lower rate shows
    /// what 12 fps shows at the same moment, only less often.
    @Test(arguments: [MenuBarIcon.working(count: 3), .needsPermission, .backgroundShell])
    func everyRateShowsTheSameSceneWhereTheirFramesMeet(icon: MenuBarIcon) throws {
        for seconds in [0.0, 0.25, 0.5, 1.75, 3.0, 7.25, 1_000.5, 781_000_000.25] {
            let smooth = try scene(icon, seconds, .smooth)
            #expect(try scene(icon, seconds, .balanced) == smooth, "t = \(seconds)")
            #expect(try scene(icon, seconds, .low) == smooth, "t = \(seconds)")
        }
        // 4 fps holds the frame of 0.25 s until 0.5 s.
        #expect(try scene(icon, 0.3, .low) == scene(icon, 0.25, .smooth))
        #expect(try scene(icon, 0.49, .low) == scene(icon, 0.25, .smooth))
        #expect(try scene(icon, 0.5, .low) != scene(icon, 0.25, .smooth))
    }

    /// Frames that fall between 12 fps ticks still show the motion at full
    /// speed: 1.2 s at 8 fps shows 1.125 s, 0.13 s shows 0.125 s, 0.4 s shows 0.375 s.
    @Test func framesBetweenTheTicksOfTwelveFramesPerSecondKeepTheSpeed() throws {
        // Drift: 45 + 90 · (0.5 − 0.5 · cos(π · 1.125 / 4)).
        #expect(close(try scene(.working(count: 3), 1.2, .balanced).yawDegrees, 61.452302212635956))
        // Pulse: 0.5 + 0.5 · (0.5 + 0.5 · cos(2π · 0.125 / 1.4)).
        #expect(close(try scene(.needsPermission, 0.13, .balanced).intensity, 0.961681049807071))
        #expect(close(try scene(.needsPermission, 0.13, .balanced, level: .whenNeeded).intensity, 0.961681049807071))
        // Glimmer: 0.2 + 0.2 · cos(2π · 0.375 / 3.2).
        #expect(close(try scene(.backgroundShell, 0.4, .balanced).intensity, 0.34819022507099184))
    }

    /// The design's values of the drift: a quarter turn in 4 s at every rate.
    @Test(arguments: MenuBarAnimation.FrameRate.allCases)
    func theDriftTakesFourSecondsPerQuarterTurnAtEveryRate(rate: MenuBarAnimation.FrameRate) throws {
        let expected: [(Double, Double)] = [(0, 45), (1, 58.180195), (2, 90), (3, 121.819805), (4, 45), (781_000_000, 45)]
        for (seconds, yaw) in expected {
            #expect(close(try scene(.working(count: 3), seconds, rate).yawDegrees, yaw, 1e-6), "\(rate) t = \(seconds)")
        }
    }

    /// A still icon shows the frame Reduce Motion shows, at every moment.
    @Test(arguments: everyAnimation)
    func aStillIconShowsTheReduceMotionFrame(animation: MenuBarAnimation) throws {
        for icon in [MenuBarIcon.working(count: 3), .needsPermission, .question, .backgroundShell]
        where !icon.moves(animation: animation, reduceMotion: false) {
            let reduced = try #require(icon.scene(at: at(2), appearance: .dark, animation: MenuBarAnimation(), reduceMotion: true))
            for seconds in [0.0, 0.75, 1.6, 3.0, 781_000_000.123] {
                #expect(icon.scene(at: at(seconds), appearance: .dark, animation: animation, reduceMotion: false) == reduced, "\(icon) t = \(seconds)")
                #expect(icon.scene(at: at(seconds), appearance: .dark, animation: animation, reduceMotion: true) == reduced, "\(icon) t = \(seconds)")
            }
            #expect(reduced.yawDegrees == 45 && reduced.sparkles.isEmpty && reduced.glitter.isEmpty)
            #expect(reduced.intensity == (icon == .backgroundShell ? 0.3 : 1))
        }
    }
}

private func close(_ a: Double, _ b: Double, _ within: Double = 1e-9) -> Bool { abs(a - b) <= within }

/// The Menu Bar pane of the settings window.
@Suite struct MenuBarAnimationSettingsTests {
    private func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    @Test func eachLevelSaysWhatMoves() {
        #expect(MenuBarAnimation.Level.allCases.map { text($0.title) } == ["Always", "Only when an agent needs me", "Never"])
        #expect(MenuBarAnimation.Level.allCases.map { text($0.explanation) } == [
            "Moves while agents work, glows for background shells and pulses when one needs you.",
            "Pulses for permissions and questions. Working and shells show a still icon in their color.",
            "Every state shows a still icon in its color. The icon uses no CPU.",
        ])
    }

    @Test func eachFrameRateNamesItsCost() {
        #expect(MenuBarAnimation.FrameRate.allCases.map { text($0.optionText) } == ["Smooth (12 fps)", "Balanced (8 fps)", "Low (4 fps)"])
        #expect(MenuBarAnimation.FrameRate.allCases.map { text($0.hint) } == [
            "Today’s motion. Uses the most CPU while the icon moves.",
            "A little less fluid, with about two thirds of the CPU.",
            "Visibly stepped, with about a third of the CPU.",
        ])
    }

    /// The hint under "Frame rate" follows the chosen rate, except at Never.
    @Test func theFrameRateHintFollowsTheChoice() {
        #expect(text(MenuBarAnimation(level: .always, frameRate: .smooth).frameRateHint) == "Today’s motion. Uses the most CPU while the icon moves.")
        #expect(text(MenuBarAnimation(level: .whenNeeded, frameRate: .balanced).frameRateHint) == "A little less fluid, with about two thirds of the CPU.")
        #expect(text(MenuBarAnimation(level: .always, frameRate: .low).frameRateHint) == "Visibly stepped, with about a third of the CPU.")
        for rate in MenuBarAnimation.FrameRate.allCases {
            #expect(text(MenuBarAnimation(level: .never, frameRate: rate).frameRateHint) == "Not used while the icon stands still.")
        }
    }

    /// Never greys out the frame rate; Reduce Motion greys out both, and the choice stays.
    @Test(arguments: MenuBarAnimation.FrameRate.allCases)
    func whatCanBeChosen(rate: MenuBarAnimation.FrameRate) {
        for level in MenuBarAnimation.Level.allCases {
            let animation = MenuBarAnimation(level: level, frameRate: rate)
            #expect(MenuBarAnimation.canChooseLevel(reduceMotion: false))
            #expect(!MenuBarAnimation.canChooseLevel(reduceMotion: true))
            #expect(animation.canChooseFrameRate(reduceMotion: false) == (level != .never), "\(level)")
            #expect(!animation.canChooseFrameRate(reduceMotion: true))
        }
    }

    @Test func thePaneIsLabelled() {
        #expect(text(SettingsText.menuBar) == "Menu Bar")
        #expect(text(SettingsText.animateTheIcon) == "Animate the icon")
        #expect(text(SettingsText.frameRate) == "Frame rate")
        #expect(text(SettingsText.menuBarFootnote)
            == "The app draws the cube frame by frame while it moves, which costs some CPU; a still icon costs nothing. Idle and warnings never move, and every state keeps its color.")
        #expect(text(SettingsText.reduceMotionIsOn) == "Reduce Motion is on")
        #expect(text(SettingsText.reduceMotionNote)
            == "The icon stays still in its color. Your choice below applies again when you turn Reduce Motion off.")
        #expect(text(SettingsText.openDisplaySettings) == "Open System Settings…")
        // Its own key: the Notifications pane's button keeps its text without the ellipsis.
        #expect(text(SettingsText.openSystemSettings) == "Open System Settings")
    }

    @Test func theMenuBarPaneComesBetweenNotificationsAndTheSources() {
        #expect(SettingsPane(rawValue: "menuBar") == .menuBar)
        #expect(SettingsPane.menuBar.rawValue == "menuBar")
        #expect(SettingsPane.restoring("menuBar", sources: []) == .menuBar)
        #expect(SettingsModel(sources: []).panes == [.general, .appearance, .sessions, .notifications, .menuBar, .about])
    }

    /// Reduce Motion lives in Accessibility › Display, the anchor Apple's own
    /// code opens it with.
    @Test func reduceMotionOpensAccessibilityDisplay() {
        #expect(SettingsModel.reduceMotionSettingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")
    }
}
