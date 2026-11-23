import Foundation

/// What the right-click menu on the status item shows, as data; the app turns
/// it into an `NSMenu`.
public struct StatusMenuModel: Sendable, Equatable {
    public let items: [StatusMenuItem]

    /// "Set Up…" appears only while the warning does, so the menu is the
    /// shortest way into the setup window exactly when it is needed.
    public init(connection: ConnectionStatus) {
        switch connection {
        case .ok: items = [.settings, .separator, .quit]
        case .missing, .disabled: items = [.settings, .setUp, .separator, .quit]
        }
    }
}

public enum StatusMenuItem: Sendable, Equatable {
    case settings
    case setUp
    case separator
    case quit

    /// A shortcut as data: the app maps `key` and `command` to `keyEquivalent`
    /// and `keyEquivalentModifierMask`.
    public struct KeyEquivalent: Sendable, Equatable {
        public let key: String
        public let command: Bool

        public init(key: String, command: Bool) {
            self.key = key
            self.command = command
        }
    }

    /// Nil for the separator.
    public var title: LocalizedStringResource? {
        switch self {
        case .settings: .kit("Settings…", defaultValue: "Settings…")
        case .setUp: .kit("Set Up…", defaultValue: "Set Up…")
        case .separator: nil
        case .quit: .kit("Quit The Collective", defaultValue: "Quit The Collective")
        }
    }

    public var keyEquivalent: KeyEquivalent? {
        switch self {
        case .settings: KeyEquivalent(key: ",", command: true)
        case .quit: KeyEquivalent(key: "q", command: true)
        case .setUp, .separator: nil
        }
    }

    /// SF Symbol shown beside the title, if any.
    public var symbolName: String? {
        switch self {
        case .setUp: "exclamationmark.triangle.fill"
        case .settings, .separator, .quit: nil
        }
    }

    /// The symbol is drawn as a warning (the app picks the color).
    public var isWarning: Bool { self == .setUp }
}
