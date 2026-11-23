import Foundation

/// How the menu bar cube moves: the user picks when it
/// animates and how many frames it draws per second. The setting only decides
/// whether the shown image moves, never which image or its color; Reduce
/// Motion overrides it (`MenuBarIcon.moves(animation:reduceMotion:)`).
public struct MenuBarAnimation: Sendable, Equatable {
    /// When the cube animates. The raw value is what the app persists.
    public enum Level: String, CaseIterable, Sendable, Equatable {
        /// Working, permission, question and background shell move, as before the setting existed.
        case always
        /// Only permission and question move; working and shells stand still.
        case whenNeeded
        /// Every state stands still, so no timer runs for the icon.
        case never

        /// The radio button's title.
        public var title: LocalizedStringResource {
            switch self {
            case .always: .kit("Always", defaultValue: "Always")
            case .whenNeeded: .kit("Only when an agent needs me", defaultValue: "Only when an agent needs me")
            case .never: .kit("Never", defaultValue: "Never")
            }
        }

        /// The sentence under the radio button: what moves, and what it costs.
        public var explanation: LocalizedStringResource {
            switch self {
            case .always:
                .kit(
                    "Moves while agents work, glows for background shells and pulses when one needs you.",
                    defaultValue: "Moves while agents work, glows for background shells and pulses when one needs you."
                )
            case .whenNeeded:
                .kit(
                    "Pulses for permissions and questions. Working and shells show a still icon in their color.",
                    defaultValue: "Pulses for permissions and questions. Working and shells show a still icon in their color."
                )
            case .never:
                .kit(
                    "Every state shows a still icon in its color. The icon uses no CPU.",
                    defaultValue: "Every state shows a still icon in its color. The icon uses no CPU."
                )
            }
        }
    }

    /// How often a moving cube is drawn; the motion keeps its speed at every
    /// rate. The raw value is what the app persists.
    public enum FrameRate: String, CaseIterable, Sendable, Equatable {
        case smooth
        case balanced
        case low

        public var framesPerSecond: Int {
            switch self {
            case .smooth: 12
            case .balanced: 8
            case .low: 4
            }
        }

        /// The entry in the "Frame rate" popup.
        public var optionText: LocalizedStringResource {
            switch self {
            case .smooth: .kit("Smooth (12 fps)", defaultValue: "Smooth (12 fps)")
            case .balanced: .kit("Balanced (8 fps)", defaultValue: "Balanced (8 fps)")
            case .low: .kit("Low (4 fps)", defaultValue: "Low (4 fps)")
            }
        }

        /// The cost of the rate, under "Frame rate"; `MenuBarAnimation.frameRateHint` picks it.
        public var hint: LocalizedStringResource {
            switch self {
            case .smooth:
                .kit("Today’s motion. Uses the most CPU while the icon moves.", defaultValue: "Today’s motion. Uses the most CPU while the icon moves.")
            case .balanced:
                .kit("A little less fluid, with about two thirds of the CPU.", defaultValue: "A little less fluid, with about two thirds of the CPU.")
            case .low:
                .kit("Visibly stepped, with about a third of the CPU.", defaultValue: "Visibly stepped, with about a third of the CPU.")
            }
        }
    }

    public var level: Level
    public var frameRate: FrameRate

    public init(level: Level = .always, frameRate: FrameRate = .smooth) {
        self.level = level
        self.frameRate = frameRate
    }

    /// The sentence under "Frame rate": the chosen rate's cost, or at `never`
    /// that no rate applies; the popup keeps its value either way.
    public var frameRateHint: LocalizedStringResource {
        guard level != .never else {
            return .kit("Not used while the icon stands still.", defaultValue: "Not used while the icon stands still.")
        }
        return frameRate.hint
    }

    /// Reduce Motion stills the icon whatever is chosen, so the radio group is
    /// greyed out while it is on; the choice stays and applies again after.
    /// Static because only the system setting locks the level, never the other
    /// choice (unlike the frame rate, which "Never" greys out).
    public static func canChooseLevel(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    /// The popup is greyed out where no rate applies: at `never` and under Reduce Motion.
    public func canChooseFrameRate(reduceMotion: Bool) -> Bool {
        level != .never && !reduceMotion
    }

    private enum Key {
        static let level = "level"
        static let frameRate = "frameRate"
    }

    /// The setting as the app persists it; a missing or damaged choice falls
    /// back to its default on its own.
    public init(fromStored stored: Any?) {
        let dictionary = stored as? [String: Any] ?? [:]
        let defaults = MenuBarAnimation()
        self.init(
            level: (dictionary[Key.level] as? String).flatMap(Level.init(rawValue:)) ?? defaults.level,
            frameRate: (dictionary[Key.frameRate] as? String).flatMap(FrameRate.init(rawValue:)) ?? defaults.frameRate
        )
    }

    /// A property list for `UserDefaults`.
    public var stored: [String: Any] {
        [Key.level: level.rawValue, Key.frameRate: frameRate.rawValue]
    }
}
