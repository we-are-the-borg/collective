import Foundation

/// Which menu bar icon to show: idle and warning are template images
/// from the asset catalog, working, needs permission and question a colored
/// cube the app draws from `scene(at:appearance:animation:reduceMotion:)`, a background
/// shell a template cube drawn the same way.
public enum MenuBarIcon: Sendable, Equatable {
    case idle
    case working(count: Int)
    /// An agent waits for the user to allow a tool call. Its badge says
    /// "?" rather than a count. Not a turn that ended and waits for a prompt.
    case needsPermission
    /// An agent waits for the user to answer its questions. Drawn like
    /// `needsPermission`; only VoiceOver tells them apart.
    case question
    /// subspace is missing or disabled; shown without a count and never animated.
    case warning
    /// No agent works, but a shell one started runs on in the background;
    /// the cube glimmers. Without a number: the number counts agents.
    case backgroundShell

    /// Size in points of every image, template or drawn, so the status item
    /// keeps its width in every state.
    public static let canvasWidth: Double = 22
    public static let canvasHeight: Double = 18

    public init(activeAgentCount: Int) {
        self = activeAgentCount > 0 ? .working(count: activeAgentCount) : .idle
    }

    /// A permission request wins over the count: working goes on without the
    /// user, the request doesn't. A question likewise, after a permission
    /// request, which VoiceOver names first. A background shell shows only
    /// while no agent works. The warning wins over all: the
    /// count may be incomplete while subspace records nothing.
    init(
        activeAgentCount: Int, awaitsPermission: Bool, awaitsAnswer: Bool = false,
        runsBackgroundShell: Bool = false, connection: ConnectionStatus
    ) {
        switch connection {
        case .ok where awaitsPermission: self = .needsPermission
        case .ok where awaitsAnswer: self = .question
        case .ok where activeAgentCount <= 0 && runsBackgroundShell: self = .backgroundShell
        case .ok: self.init(activeAgentCount: activeAgentCount)
        case .missing, .disabled: self = .warning
        }
    }

    public init(state: CollectiveState, connection: ConnectionStatus) {
        self.init(
            activeAgentCount: state.activeAgentCount, awaitsPermission: state.awaitsPermission,
            awaitsAnswer: state.awaitsAnswer, runsBackgroundShell: state.runsBackgroundShell, connection: connection
        )
    }

    /// `.working` is a public case, so a caller can build it with no agents;
    /// that is idle, same as `init(activeAgentCount:)`.
    private var normalized: MenuBarIcon {
        if case .working(let count) = self, count <= 0 { return .idle }
        return self
    }

    /// The colored cube for this date: nebula with the count for
    /// working, amber with "?" for a permission request or a question; the
    /// glimmering template cube for a background shell. Nil for idle and
    /// warning, which stay template images (`templateImageName`). Phase comes
    /// from the wall clock, not from a counter, so the animation stays in
    /// phase across redraws and needs no state. An icon that doesn't move
    /// under the setting shows its still frame, the one Reduce Motion shows.
    public func scene(
        at date: Date, appearance: MenuBarScene.Appearance, animation: MenuBarAnimation, reduceMotion: Bool
    ) -> MenuBarScene? {
        let tick = framesPerSecond(animation: animation, reduceMotion: reduceMotion).map { Self.sceneTick(at: date, framesPerSecond: $0) }
        switch normalized {
        case .working(let count):
            return MenuBarScene(look: .nebula, badgeText: count >= 10 ? "9+" : "\(count)", tick: tick, appearance: appearance)
        case .needsPermission, .question:
            return MenuBarScene(look: .amber, badgeText: "?", tick: tick, appearance: appearance)
        case .backgroundShell:
            return MenuBarScene(look: .glimmer, badgeText: nil, tick: tick, appearance: appearance)
        case .idle, .warning:
            return nil
        }
    }

    /// When the scene changes next, strictly after `date`: drift, pulse and
    /// glimmer never rest, so that is the next frame. Nil while nothing moves, so the
    /// app runs no timer for idle, warning, a still setting or Reduce Motion.
    public func nextSceneChange(after date: Date, animation: MenuBarAnimation, reduceMotion: Bool) -> Date? {
        guard let fps = framesPerSecond(animation: animation, reduceMotion: reduceMotion) else { return nil }
        let nextFrame = Self.frame(atSeconds: date.timeIntervalSinceReferenceDate, framesPerSecond: fps) + 1
        var seconds = Double(nextFrame) / Double(fps)
        // The division may round just below the boundary; the returned date must
        // already fall in the new frame, or the app would draw the old frame again.
        while Self.frame(atSeconds: seconds, framesPerSecond: fps) < nextFrame { seconds = seconds.nextUp }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Whether the cube moves under the user's setting:
    /// permission and question at `always` and `whenNeeded`, working and a
    /// background shell only at `always`. Reduce Motion stills every state;
    /// idle and warning never move.
    public func moves(animation: MenuBarAnimation, reduceMotion: Bool) -> Bool {
        framesPerSecond(animation: animation, reduceMotion: reduceMotion) != nil
    }

    /// Nil while the icon stands still.
    private func framesPerSecond(animation: MenuBarAnimation, reduceMotion: Bool) -> Int? {
        guard !reduceMotion else { return nil }
        switch (normalized, animation.level) {
        case (.idle, _), (.warning, _), (_, .never), (.working, .whenNeeded), (.backgroundShell, .whenNeeded):
            return nil
        case (.needsPermission, _), (.question, _), (.working, .always), (.backgroundShell, .always):
            return animation.frameRate.framesPerSecond
        }
    }

    /// A frame shows the scene at the start of its slot, so the motion keeps
    /// its speed at every rate. The scene clock's 24 ticks a second are the
    /// least common multiple of 12, 8 and 4, so every slot starts on a whole tick.
    private static func sceneTick(at date: Date, framesPerSecond fps: Int) -> Int {
        frame(atSeconds: date.timeIntervalSinceReferenceDate, framesPerSecond: fps) * (MenuBarScene.ticksPerSecond / fps)
    }

    private static func frame(atSeconds seconds: Double, framesPerSecond fps: Int) -> Int {
        Int((seconds * Double(fps)).rounded(.down))
    }

    /// The asset for idle and warning, nil for the drawn states.
    public var templateImageName: String? {
        switch normalized {
        case .idle: "MenuBarIdle"
        case .warning: "MenuBarWarning"
        case .working, .needsPermission, .question, .backgroundShell: nil
        }
    }

    /// VoiceOver names the app, then the state (`accessibilityValue`).
    public static var accessibilityLabel: LocalizedStringResource {
        .kit("The Collective", defaultValue: "The Collective")
    }

    /// The state in the words of the popover: its header's counts, the
    /// warning block's title while subspace is missing or disabled.
    public static func accessibilityValue(state: CollectiveState, connection: ConnectionStatus) -> LocalizedStringResource {
        accessibilityValue(icon: MenuBarIcon(state: state, connection: connection), connection: connection)
    }

    /// The same words from the already derived icon, so the app need not walk
    /// the state again. The connection stays a parameter: missing and disabled
    /// both show `.warning` but name different problems.
    public static func accessibilityValue(icon: MenuBarIcon, connection: ConnectionStatus) -> LocalizedStringResource {
        if let warning = WarningBlock(connection) { return warning.title }
        switch icon {
        case .needsPermission:
            return .kit("An agent needs your permission", defaultValue: "An agent needs your permission")
        case .question:
            return .kit("An agent asks you a question", defaultValue: "An agent asks you a question")
        case .backgroundShell:
            return .kit("A background shell is running", defaultValue: "A background shell is running")
        case .working(let count) where count > 0:
            return .kit("%lld agents working", defaultValue: "\(count) agents working")
        case .idle, .working, .warning:
            return .kit("No agents working", defaultValue: "No agents working")
        }
    }
}
