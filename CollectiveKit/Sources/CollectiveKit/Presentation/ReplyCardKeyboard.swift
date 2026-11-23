import Foundation

// The session list's keys around the reply card: Space or Return
// opens the focused row's card while its reply does not fit, ↑ ↓ scroll a shown card instead of
// moving the list's focus, Esc closes it and gives ↑ ↓ back to the list. ⌘↩ stays "Show in <App>".
// The view reads the key press and carries out the action.

/// A key the session list may act on.
public enum ReplyCardKey: Sendable, Equatable {
    case space, `return`, commandReturn, upArrow, downArrow, escape
}

/// What a key does in the session list.
public enum ReplyCardKeyAction: Sendable, Equatable {
    /// Not the list's: the system's handling stands; Esc closes the popover.
    case pass
    /// Opens the row's card (`ReplyCardFlow.open(_:)`).
    case open(ReplyCardTarget)
    case scrollCardUp
    case scrollCardDown
    case moveFocusUp
    case moveFocusDown
    /// Closes the shown card (`ReplyCardFlow.escape()`).
    case closeCard
    /// Brings the focused row's session forward in its terminal.
    case showInApp
}

extension ReplyCardFlow {
    /// What `key` does with the list's focus on a row.
    /// - Parameter focusedReply: The focused row's target while its reply does not fit, as
    ///   "Show more" shows; nil for one that fits, without a reply, or without a focused row.
    public func action(for key: ReplyCardKey, focusedReply: ReplyCardTarget?) -> ReplyCardKeyAction {
        switch key {
        case .space, .return: focusedReply.map(ReplyCardKeyAction.open) ?? .pass
        case .commandReturn: .showInApp
        case .upArrow: shown == nil ? .moveFocusUp : .scrollCardUp
        case .downArrow: shown == nil ? .moveFocusDown : .scrollCardDown
        case .escape: shown == nil ? .pass : .closeCard
        }
    }
}
