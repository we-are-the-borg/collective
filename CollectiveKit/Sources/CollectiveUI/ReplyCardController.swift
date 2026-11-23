import AppKit
import CollectiveKit
import SwiftUI

/// The popover's one `ReplyCardFlow`, shared by everything that
/// feeds it: the rows' "Show more", menus and VoiceOver actions, the session list's keys and
/// rows leaving, the host at the popover's root the card's frame, the card's close button, and
/// a click monitor the clicks, which takes those beside the card. It lives at `PopoverView`
/// rather than in the list, as the host and a click anywhere in the popover sit there;
/// everything below reaches it through `\.replyCard`, so no callbacks travel in the preference
/// that carries the card.
@MainActor @Observable
final class ReplyCardController {
    private(set) var shown: ReplyCardTarget?
    /// ↑ ↓ on a shown card: the card scrolls a step with every new value.
    private(set) var scroll = ReplyCardScroll()
    /// VoiceOver's "Read Reply" or "Show Result" asked for this card; it takes VoiceOver's
    /// focus once it shows.
    var readRequest: ReplyCardTarget?

    @ObservationIgnored private var flow = ReplyCardFlow()
    /// Where each laid-out card lies in `clickSpace`, by its row: while another row's card
    /// fades in, the old one is still there and reports too.
    @ObservationIgnored private var cardFrames: [ReplyCardTarget: CGRect] = [:]
    /// The session rows whose reply does not fit its lines, as each row measures it: only
    /// they open a card from Space and Return. Read on a key press, so nothing draws from it.
    @ObservationIgnored private var cutReplies: Set<ReplyCardTarget> = []

    /// The space the host lays the card out in and the click monitor maps clicks into: the
    /// popover's root, top left at zero. Nonisolated: SwiftUI reads it in its geometry closures,
    /// which are Sendable.
    nonisolated static let clickSpace = "ReplyCardClickSpace"

    /// The card for `target` was laid out at `frame` in `clickSpace`; nil once it went.
    func cardFrameChanged(_ frame: CGRect?, for target: ReplyCardTarget) {
        cardFrames[target] = frame
    }

    /// The row measured its reply: cut at its lines or not.
    func replyCutChanged(_ isCut: Bool, for target: ReplyCardTarget) {
        if isCut { cutReplies.insert(target) } else { cutReplies.remove(target) }
    }

    /// `target` while its reply is cut, so a key may open its card; nil otherwise.
    func openable(_ target: ReplyCardTarget?) -> ReplyCardTarget? {
        target.flatMap { cutReplies.contains($0) ? $0 : nil }
    }

    func open(_ target: ReplyCardTarget) { change { $0.open(target) } }
    func toggle(_ target: ReplyCardTarget) { change { $0.toggle(target) } }

    /// VoiceOver's "Read Reply" or "Show Result": the card opens and VoiceOver moves into it.
    func read(_ target: ReplyCardTarget) {
        open(target)
        readRequest = target
    }

    /// - Returns: Whether a card closed; without one Esc is not taken.
    func escape() -> Bool {
        var closed = false
        change { closed = $0.escape() }
        return closed
    }

    /// The card's close button: closes it as Esc does.
    func close() { _ = escape() }

    /// A mouse button went down, in the popover at a point in `clickSpace` or in another window.
    /// - Returns: Whether the popover takes the click, which then reaches nothing under it.
    func mouseDown(at location: ReplyCardClickLocation) -> Bool {
        let frame = shown.flatMap { cardFrames[$0] }
        var taken = false
        change { taken = $0.mouseDown(at: location, cardFrame: frame) }
        return taken
    }

    func action(for key: ReplyCardKey, focusedReply: ReplyCardTarget?) -> ReplyCardKeyAction {
        flow.action(for: key, focusedReply: focusedReply)
    }

    func scrollCard(by step: Int) {
        scroll = ReplyCardScroll(step: step, count: scroll.count + 1)
    }

    /// The rows with a reply now; a card whose row went closes.
    func targetsChanged(from old: Set<ReplyCardTarget>, to new: Set<ReplyCardTarget>) {
        let gone = old.subtracting(new)
        guard !gone.isEmpty else { return }
        cutReplies.subtract(gone)
        change { flow in for target in gone { flow.targetDisappeared(target) } }
    }

    private func change(_ body: (inout ReplyCardFlow) -> Void) {
        body(&flow)
        if shown != flow.shown { shown = flow.shown }
    }
}

/// One ↑ or ↓ on a shown card: `count` tells a press from the one before.
struct ReplyCardScroll: Equatable {
    var step = 0
    var count = 0
}

extension EnvironmentValues {
    /// Set by `PopoverView`; nil in previews of single rows, which then open no card.
    @Entry var replyCard: ReplyCardController? = nil
    /// The shown card's last ↑ or ↓, for the card's scroll view.
    @Entry var replyCardScroll: ReplyCardScroll? = nil
}

extension View {
    /// What the flow needs beside the rows and the card: Esc while a card shows, and every
    /// click in the popover.
    func replyCardSupport(_ controller: ReplyCardController) -> some View {
        modifier(ReplyCardSupport(controller: controller))
    }
}

private struct ReplyCardSupport: ViewModifier {
    let controller: ReplyCardController
    @State private var monitor: Any?
    /// The popover's root as an AppKit view, to map a click's window location into `clickSpace`.
    @State private var clickSpace = ClickSpace()

    func body(content: Content) -> some View {
        content
            // Apart from the content, so a card opening or closing re-renders only this.
            .background { ReplyCardEscape(controller: controller) }
            .background { ClickSpaceView(space: clickSpace) }
            // A monitor rather than a gesture: it sees every click before a button or a menu
            // does, and takes only those the flow says, so the card's text stays selectable.
            // `PopoverController` builds the popover's view on every open and drops it on
            // close, and this with it.
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [controller, clickSpace] event in
                    let taken = MainActor.assumeIsolated {
                        controller.mouseDown(at: clickSpace.location(of: event))
                    }
                    return taken ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// Holds the AppKit view behind the popover's root; a reference, so the monitor's closure sees
/// the view once SwiftUI made it.
@MainActor private final class ClickSpace {
    weak var view: NSView?

    /// Where `event` went down: in the popover, in the root with the top left at zero like
    /// `ReplyCardController.clickSpace`, or in another window.
    func location(of event: NSEvent) -> ReplyCardClickLocation {
        guard let view, let window = event.window, window === view.window else { return .anotherWindow }
        return .popover(view.convert(event.locationInWindow, from: nil))
    }
}

/// Spans the popover's root behind its content and takes no clicks.
private struct ClickSpaceView: NSViewRepresentable {
    let space: ClickSpace

    func makeNSView(context: Context) -> NSView {
        let view = FlippedPassiveView()
        space.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { space.view = view }

    /// Flipped, so its coordinates run from the top left as SwiftUI's do.
    private final class FlippedPassiveView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Takes Esc while a card shows: as a key equivalent it works wherever the focus is, and without
/// a card it is not there, so Esc reaches the panel and closes the popover.
private struct ReplyCardEscape: View {
    let controller: ReplyCardController

    var body: some View {
        ZStack {
            if controller.shown != nil {
                Button {
                    if controller.action(for: .escape, focusedReply: nil) == .closeCard { _ = controller.escape() }
                } label: { EmptyView() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
