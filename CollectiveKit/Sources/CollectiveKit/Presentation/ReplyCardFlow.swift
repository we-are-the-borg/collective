import Foundation

// The popover's reply card: which row's card shows. Only a
// deliberate act opens one, "Show more", the menu, Space or Return, VoiceOver; nothing the
// pointer does by itself opens or closes it. It stays until Esc, its close button, a click
// beside it, another row's card, or its row going. A click beside it in the popover only
// closes it: nothing under the click acts, not even the row's own "Show more".

/// A row whose reply the card shows: a session's card, or a subagent row in it, which
/// shows the subagent's prompt and result.
public enum ReplyCardTarget: Hashable, Sendable {
    case session(SessionKey)
    case agent(SessionKey, AgentRef)
}

/// Where a mouse button went down, as the popover's click monitor sees it.
public enum ReplyCardClickLocation: Sendable, Equatable {
    /// In the popover's window, in the coordinates the host lays the card out in.
    case popover(CGPoint)
    /// In another of the app's windows, such as Settings.
    case anotherWindow
}

public struct ReplyCardFlow: Sendable, Equatable {
    /// The row whose card shows.
    public private(set) var shown: ReplyCardTarget?

    public init() {}

    /// A menu entry, Space or Return, or VoiceOver: the row's card shows, replacing any other.
    public mutating func open(_ target: ReplyCardTarget) {
        shown = target
    }

    /// The row's "Show more": opens its card, or closes it while it shows.
    public mutating func toggle(_ target: ReplyCardTarget) {
        if shown == target {
            shown = nil
        } else {
            open(target)
        }
    }

    /// Esc or the card's close button closes the card. Without one Esc is not taken, so the
    /// popover closes.
    /// - Returns: Whether a card closed.
    public mutating func escape() -> Bool {
        guard shown != nil else { return false }
        shown = nil
        return true
    }

    /// A mouse button went down. Inside the card, it selects text, scrolls or opens the text's
    /// own menu, and the card stays. Beside it in the popover it only closes the card: the
    /// popover takes it, so no row, button, menu or tab acts, the shown row's "Show more" no
    /// more than any other, and the next click acts again. In another window the card closes
    /// and the click is that window's. Without a card every click acts as it would.
    /// - Parameter cardFrame: Where the shown card lies now; nil while none is laid out.
    /// - Returns: Whether the popover takes the click, which then reaches nothing under it.
    public mutating func mouseDown(at location: ReplyCardClickLocation, cardFrame: CGRect?) -> Bool {
        guard shown != nil else { return false }
        switch location {
        case let .popover(point):
            if let cardFrame, cardFrame.contains(point) { return false }
            shown = nil
            return true
        case .anotherWindow:
            shown = nil
            return false
        }
    }

    /// The row went: a tab change, archived, or its reply is gone.
    public mutating func targetDisappeared(_ target: ReplyCardTarget) {
        if shown == target { shown = nil }
    }
}

extension SessionItem {
    /// The row while its detail shows a reply, in any tab; an undo row has none. Whether its
    /// card opens hangs on the reply not fitting its lines, which only the view can measure.
    public var replyCardTarget: ReplyCardTarget? {
        guard undo == nil, case .reply? = rowDetail else { return nil }
        return .session(key)
    }
}

extension SubagentRow {
    /// The row's card while it has a prompt or a result to show; an undo row has none.
    public func replyCardTarget(in session: SessionKey) -> ReplyCardTarget? {
        guard undo == nil, prompt != nil || reply != nil else { return nil }
        return .agent(session, ref)
    }
}

extension PopoverModel {
    /// The rows of the shown tab that have a card: a target that leaves this set went, and the
    /// view tells the flow (`ReplyCardFlow.targetDisappeared(_:)`). Nothing while the earlier
    /// sessions are folded under a warning; subagent rows only while their list shows open.
    public var replyCardTargets: Set<ReplyCardTarget> {
        if earlierSessions?.isExpanded == false { return [] }
        var targets: Set<ReplyCardTarget> = []
        for item in rows {
            if let target = item.replyCardTarget { targets.insert(target) }
            guard item.undo == nil, let toggle = item.subagentToggle, toggle.isOpen else { continue }
            for row in toggle.list.entries.compactMap(\.row) {
                if let target = row.replyCardTarget(in: toggle.list.session) { targets.insert(target) }
            }
        }
        return targets
    }
}
