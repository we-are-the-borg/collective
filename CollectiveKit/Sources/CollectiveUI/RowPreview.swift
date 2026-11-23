import CollectiveKit
import SwiftUI

/// A row's whole reply in a card over the list: "Last reply, 48 min ago",
/// the reply rendered from its Markdown as the open reply was, and for an
/// idle session its subagents at the foot. Replaces opening the reply in
/// the row, in all three tabs; "Show more" opens it. No tool logo in the popover.
struct SessionReplyCard: View {
    let item: SessionItem
    let reply: ReplyItem
    /// The window's height: the card never grows past it.
    let maxHeight: CGFloat

    var body: some View {
        ReplyCard(reply: reply, spacing: 4, maxHeight: maxHeight) {
            DurationClock(since: item.lastReplyAt) { now in
                if let text = item.lastReplyText(at: now) {
                    Text(text)
                        .font(.plexSans(10.5))
                        .foregroundStyle(.role(.textMuted))
                        .lineLimit(1)
                }
            }
            // The line keeps the text's height; the button stands out over it.
            .frame(maxWidth: .infinity, minHeight: PlexMetrics.naturalLineHeight(size: 10.5, mono: false), alignment: .leading)
            .padding(.trailing, ReplyCardCloseButton.reserve)
            .overlay(alignment: .trailing) { ReplyCardCloseButton().offset(x: ReplyCardCloseButton.overhang) }
        } footer: {
            if let subagents = item.idleSubagents { footer(subagents) }
        }
    }

    /// "4 subagents, all done · Sonnet 5, Haiku 5.5" under a hairline: the
    /// row stays one line, so the subagents show here only.
    private func footer(_ subagents: IdleSubagents) -> some View {
        let counts = subagents.statusParts.reduce(Text(subagents.title)) { $0 + Self.separator + Text($1) }
        let text = subagents.modelNames.isEmpty
            ? counts
            : counts + Self.separator + Text(verbatim: subagents.modelNames.joined(separator: ", "))
        return text
            .font(.plexSans(11))
            .foregroundStyle(.role(.textMuted))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .overlay(alignment: .top) { SubagentHairline() }
    }

    /// " · " between the footer's parts, quieter than the text.
    private static var separator: Text {
        Text(verbatim: " · ").foregroundStyle(.role(.textSubtle))
    }
}

/// A subagent's prompt and, once it is done, its whole result: what its row in
/// a session's list keeps out of the row. The same card as a session's reply;
/// the result without the tool's logo. Opened from the row's menu.
struct SubagentReplyCard: View {
    let row: SubagentRow
    /// The window's height: the card never grows past it.
    let maxHeight: CGFloat

    /// The prompt's line height.
    private static let lineHeight: CGFloat = 16

    var body: some View {
        ReplyCard(reply: row.reply, spacing: 6, maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    if let prompt = row.prompt {
                        LucideImage(.messageSquareText, size: 10)
                            .foregroundStyle(.role(.textSubtle))
                            .frame(height: Self.lineHeight)
                        Text(verbatim: prompt)
                            .font(.plexSans(12))
                            .foregroundStyle(.role(.textMuted))
                            .lineSpacing(max(0, Self.lineHeight - PlexMetrics.naturalLineHeight(size: 12, mono: false)))
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                }
                // Without a prompt the line stays for the button alone, which must not cover the result.
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight, alignment: .topLeading)
                // The prompt wraps before the button, which stands out over the first line.
                .padding(.trailing, ReplyCardCloseButton.reserve)
                .overlay(alignment: .topTrailing) {
                    ReplyCardCloseButton()
                        .offset(x: ReplyCardCloseButton.overhang, y: (Self.lineHeight - ReplyCardCloseButton.size) / 2)
                }
                // Outside the scroll area, so it stays put while the result scrolls.
                if row.prompt != nil, row.reply != nil { SubagentHairline() }
            }
        } footer: {
            EmptyView()
        }
    }
}

/// "×" at the card's top right: closes it as Esc does. Its 20 pt hit area stands out over the
/// line it sits on and into the card's padding, so the line keeps its height.
private struct ReplyCardCloseButton: View {
    @Environment(\.replyCard) private var replyCard

    static let size = ReplyCardLayout.closeButtonSize
    static let overhang = ReplyCardLayout.closeButtonOverhang
    /// The room the line's text leaves for the icon, with a gap of 6 as between icon and text elsewhere.
    static let reserve = ReplyCardLayout.closeIconSize + 6

    var body: some View {
        Button { replyCard?.close() } label: {
            LucideImage(.x, size: ReplyCardLayout.closeIconSize)
                .foregroundStyle(.role(.textMuted))
                .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(.popoverIcon)
        .help(Text("Close", bundle: .module))
        // The card is one element for VoiceOver; it closes through the card's "Close" action.
        .accessibilityHidden(true)
    }
}

/// The card both share: header and footer at their own height, the reply in
/// between taking what is left of the cap and scrolling past it.
private struct ReplyCard<Header: View, Footer: View>: View {
    let reply: ReplyItem?
    let spacing: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    var body: some View {
        ReplyCardStack(spacing: spacing, chrome: ReplyCardLayout.padding.top + ReplyCardLayout.padding.bottom, container: maxHeight) {
            header
            if let reply {
                ScrollingReplyText(reply: reply, style: .card)
                    .layoutValue(key: ReplyCardStack.Scrolls.self, value: true)
            }
            footer
        }
        .padding(ReplyCardLayout.padding)
        .frame(width: ReplyCardLayout.width, alignment: .leading)
        .background(.role(.surface))
        .overlay(Rectangle().strokeBorder(.role(.borderStrong), lineWidth: 1))
        // The popover's shadow, `0 10 30` black 30 %; CSS's blur 30 is a SwiftUI radius of 15.
        .shadow(color: .black.opacity(0.30), radius: 15, x: 0, y: 10)
    }
}

/// Stacks header, reply and footer, giving the reply what `textHeight` leaves.
/// Sized in the layout pass, so the card never shows at a wrong height for a
/// frame first, as a height read back from geometry would.
private struct ReplyCardStack: Layout {
    /// Marks the one subview that scrolls; the others keep their own height.
    struct Scrolls: LayoutValueKey {
        static let defaultValue = false
    }

    let spacing: CGFloat
    /// The card's vertical padding, which counts against the cap.
    let chrome: CGFloat
    let container: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heights = heights(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights.reduce(0, +) + gaps(subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(0, subviews.count - 1))
    }

    private func heights(width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        // Unbounded in height, a scroll view asks for the height of what it holds.
        let ideal = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let fixed = zip(subviews, ideal).filter { !$0.0[Scrolls.self] }.map(\.1).reduce(0, +) + gaps(subviews) + chrome
        return zip(subviews, ideal).map { subview, height in
            subview[Scrolls.self] ? ReplyCardLayout.textHeight(text: height, fixed: fixed, container: container) : height
        }
    }
}

/// The whole reply from its Markdown, scrolling once its box is smaller than
/// the text, with a fade at the bottom while more follows. The box's height
/// comes from outside; a click on the text does nothing, so it can be selected
/// for ⌘C, the only way to copy a reply. ↑ and ↓ scroll it from the list while it shows.
private struct ScrollingReplyText: View {
    let reply: ReplyItem
    let style: ReplyTextStyle

    @Environment(\.replyCardScroll) private var keyScroll
    @State private var overflows = false
    @State private var showsFade = false
    @State private var position = ScrollPosition(edge: .top)
    /// Where the text stands, read when a key scrolls it. A reference kept stable across updates
    /// on purpose: its values change with every frame of a scroll and nothing draws from them,
    /// so writing into it re-renders nothing.
    @State private var extent = ScrollExtent()

    var body: some View {
        ScrollView(.vertical) {
            ReplyMarkdownView(reply.text, rendersAsPlainText: reply.preview.rendersAsPlainText, style: style)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for a code fill at a line start, which reaches beyond
                // the text; the scroll view widens by as much, see below.
                .padding(.leading, InlineCodeFill.padding)
                // The last line never sits under the fade.
                .padding(.bottom, overflows ? ReplyCardLayout.fadeHeight : 0)
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicatorsFlash(onAppear: true)
        .onScrollGeometryChange(for: ScrollExtent.Values.self) { geometry in
            ScrollExtent.Values(
                offset: geometry.contentOffset.y, content: geometry.contentSize.height, viewport: geometry.containerSize.height
            )
        } action: { _, values in
            extent.values = values
        }
        .onChange(of: keyScroll) { _, scroll in
            guard let scroll else { return }
            let values = extent.values
            position.scrollTo(y: ReplyCardLayout.offset(
                after: scroll.step, from: values.offset, contentHeight: values.content, viewportHeight: values.viewport
            ))
        }
        .onScrollGeometryChange(for: [Bool].self) { geometry in
            [
                geometry.contentSize.height - geometry.containerSize.height > ReplyCardLayout.tolerance,
                ReplyCardLayout.showsFade(
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height,
                    offset: geometry.contentOffset.y
                ),
            ]
        } action: { _, flags in
            overflows = flags[0]
            showsFade = flags[1]
        }
        // A mask only takes opacity: its colors are never drawn.
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, showsFade ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: ReplyCardLayout.fadeHeight)
            }
        }
        // Scroll view and mask clip 3 pt further left, the text stays where it was.
        .padding(.leading, -InlineCodeFill.padding)
    }
}

/// The reply's scroll geometry as last seen.
@MainActor private final class ScrollExtent {
    struct Values: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var viewport: CGFloat = 0
    }

    var values = Values()
}

/// The reply card's rules, apart from SwiftUI so they can be tested.
enum ReplyCardLayout {
    static let width: CGFloat = 356
    /// Taller than this, the reply scrolls inside the card.
    static let maxHeight: CGFloat = 360
    static let padding = EdgeInsets(top: 8, leading: 10, bottom: 9, trailing: 10)
    static let fadeHeight: CGFloat = 13
    /// Layout rounding must neither cap a fitting reply nor show a fade at the very end.
    static let tolerance: CGFloat = 0.5
    /// The close button's hit area and its "×".
    static let closeButtonSize: CGFloat = 20
    static let closeIconSize: CGFloat = 12
    /// How far the close button's hit area reaches past the content's trailing edge, into the
    /// padding: the icon's edge sits on the content's.
    static let closeButtonOverhang = (closeButtonSize - closeIconSize) / 2

    /// As tall as its content up to `maxHeight`, and never taller than the
    /// window, which AppKit would clip.
    static func cardHeight(content: CGFloat, container: CGFloat) -> CGFloat {
        min(content, maxHeight, container)
    }

    /// The reply's box: its own height, or what the card's height leaves beside
    /// header, footer and padding (`fixed`), which never give way.
    static func textHeight(text: CGFloat, fixed: CGFloat, container: CGFloat) -> CGFloat {
        max(0, cardHeight(content: text + fixed, container: container) - fixed)
    }

    /// The fade hints at more below; at the end, or when all fits, it would
    /// only hide the last line.
    static func showsFade(contentHeight: CGFloat, viewportHeight: CGFloat, offset: CGFloat) -> Bool {
        contentHeight - viewportHeight - offset > tolerance
    }

    /// What one ↑ or ↓ scrolls a shown card by: a little over two lines.
    static let scrollStep: CGFloat = 40

    /// The reply's offset after `steps` presses of ↓ (negative: ↑), kept between its ends.
    static func offset(after steps: Int, from offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let end = max(0, contentHeight - viewportHeight)
        return min(end, max(0, offset + CGFloat(steps) * scrollStep))
    }
}

/// The row whose reply card shows, handed up to the popover's
/// root: a session row with its reply, in any tab, or a subagent in a card's
/// list. A row asks only while `ReplyCardController.shown` is its own.
struct RowPreviewRequest {
    enum Content {
        case session(SessionItem, ReplyItem)
        case subagent(SubagentRow, session: SessionKey)
    }

    /// Another row's preview fades in, rather than one moving there.
    enum ID: Hashable {
        case session(SessionKey)
        case subagent(SessionKey, AgentRef)

        /// Whether `next` replaces `current` when both reach the host. A subagent
        /// row sits inside its card, so under the pointer it is the more specific
        /// ask and beats the card's; this must not hang on the order SwiftUI
        /// merges the card's and its children's preferences in. Otherwise
        /// the first ask stays.
        static func takesOver(_ next: ID?, from current: ID?) -> Bool {
            guard let next else { return false }
            guard let current else { return true }
            return next.rank > current.rank
        }

        private var rank: Int {
            switch self {
            case .session: 0
            case .subagent: 1
            }
        }
    }

    let content: Content
    let row: Anchor<CGRect>
    /// The reply's text inside a session's card, nil for a subagent row: the
    /// preview hangs off the text rather than off the subagents and the meta
    /// line below it.
    var reply: Anchor<CGRect>? = nil
    let isLastOfSeveral: Bool

    var id: ID {
        switch content {
        case let .session(item, _): .session(item.key)
        case let .subagent(row, session): .subagent(session, row.id)
        }
    }

    var target: ReplyCardTarget {
        switch content {
        case let .session(item, _): .session(item.key)
        case let .subagent(row, session): .agent(session, row.ref)
        }
    }

    /// At most one row asks at a time: the one whose card the flow shows.
    /// The precedence lives in `ID.takesOver`, which `RowPreviewPrecedenceTests`
    /// covers: a request carries an `Anchor`, which a test cannot build.
    struct Key: PreferenceKey {
        static let defaultValue: RowPreviewRequest? = nil

        static func reduce(value: inout RowPreviewRequest?, nextValue: () -> RowPreviewRequest?) {
            let next = nextValue()
            if ID.takesOver(next?.id, from: value?.id) { value = next }
        }
    }

    /// The reply's text hands its bounds up as an anchor of its own, which the
    /// card folds into its request: an anchor resolves at the host, so it
    /// follows the list's scrolling, and no state changes on a geometry pass.
    /// Only the card's overlay reads it; a card whose reply card is closed
    /// emits it too, which is harmless.
    struct ReplyKey: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil

        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }
}

/// Where the preview goes inside the popover window, whose height is that of
/// its content: a preview hanging off the row on a fixed side would be cut off
/// by the window under a lone or last row. All values in the window's coordinates.
/// A subagent row's preview goes the same way as an idle row's.
enum IdlePreviewPlacement {
    /// From the row's leading edge.
    static let inset: CGFloat = 22
    /// Over the row's edge on the side it opens to.
    static let overlap: CGFloat = 2

    /// The preview's top edge: below the row if it fits there, else above it if
    /// it fits there, else on the roomier side, kept inside the window. Covering
    /// the row in that last case beats being cut off. The last of several rows
    /// tries above first, as the design draws it, so its preview covers the rows
    /// of its own group rather than what follows. For a session's card the rect passed
    /// as `row` is the band from `band(row:reply:)`, the reply text's vertical
    /// extent, so the preview hangs off the reply text while `leading` still
    /// measures against the card.
    static func top(row: CGRect, height: CGFloat, container: CGFloat, isLastOfSeveral: Bool) -> CGFloat {
        let below = row.maxY - overlap
        let above = row.minY + overlap - height
        if isLastOfSeveral, above >= 0 { return above }
        if below + height <= container { return below }
        if above >= 0 { return above }
        let preferred = container - row.maxY >= row.minY ? below : above
        return max(0, min(preferred, container - height))
    }

    /// What `top` places against: vertically the reply's text if there is one,
    /// horizontally always the row, so the preview keeps its indent from the card.
    static func band(row: CGRect, reply: CGRect?) -> CGRect {
        guard let reply else { return row }
        return CGRect(x: row.minX, y: reply.minY, width: row.width, height: reply.height)
    }

    static func leading(row: CGRect, width: CGFloat, container: CGFloat) -> CGFloat {
        max(0, min(row.minX + inset, container - width))
    }
}

extension View {
    /// Draws the reply card a session row or a subagent row asks for. Applied at
    /// the popover's root, so the card may cover the header and footer and is
    /// never clipped by the list's scroll views, and is kept inside the window,
    /// which AppKit would clip. The card is never taller than the window.
    func rowPreviewHost() -> some View {
        modifier(RowPreviewHost())
    }
}

/// The card takes the pointer, the wheel and clicks, the space around it none,
/// so the rows under it keep theirs; only the first click beside the card is the
/// click monitor's, which closes the card.
/// Above the list's scroll view rather than in it, the wheel scrolls the card and
/// stops at its ends.
/// The pointer neither opens nor closes it.
private struct RowPreviewHost: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.replyCard) private var replyCard
    /// VoiceOver's "Read Reply" lands in the card's text.
    @AccessibilityFocusState private var readsCard: Bool

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(RowPreviewRequest.Key.self) { request in
            GeometryReader { proxy in
                let container = proxy.size
                ZStack(alignment: .topLeading) {
                    // Spans the window: the preview's guides place it against this.
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if let request {
                        let row = proxy[request.row]
                        let band = IdlePreviewPlacement.band(row: row, reply: request.reply.map { proxy[$0] })
                        preview(request.content, maxHeight: container.height)
                            // Whether a click lands in it or beside it, which closes it.
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(ReplyCardController.clickSpace))
                            } action: { replyCard?.cardFrameChanged($0, for: request.target) }
                            .onDisappear { replyCard?.cardFrameChanged(nil, for: request.target) }
                            .environment(\.replyCardScroll, replyCard?.scroll)
                            // VoiceOver reads it as one.
                            .accessibilityElement(children: .combine)
                            .accessibilityAction(named: Text("Close", bundle: .module)) { replyCard?.close() }
                            .accessibilityFocused($readsCard)
                            .task(id: replyCard?.readRequest) {
                                guard let replyCard, replyCard.readRequest == request.target else { return }
                                replyCard.readRequest = nil
                                readsCard = true
                            }
                            .alignmentGuide(.leading) { -IdlePreviewPlacement.leading(row: row, width: $0.width, container: container.width) }
                            .alignmentGuide(.top) {
                                -IdlePreviewPlacement.top(
                                    row: band, height: $0.height, container: container.height, isLastOfSeveral: request.isLastOfSeveral
                                )
                            }
                            // Another row's preview fades in, rather than this one moving there.
                            .id(request.id)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: request?.id)
                .coordinateSpace(.named(ReplyCardController.clickSpace))
            }
        }
    }

    @ViewBuilder
    private func preview(_ content: RowPreviewRequest.Content, maxHeight: CGFloat) -> some View {
        switch content {
        case let .session(item, reply): SessionReplyCard(item: item, reply: reply, maxHeight: maxHeight)
        case let .subagent(row, _): SubagentReplyCard(row: row, maxHeight: maxHeight)
        }
    }
}

#if DEBUG
/// The cards "Show more" and the menu bring up, which a preview canvas cannot click:
/// a long Markdown reply that scrolls (also in a low window), state f's
/// short idle reply with its subagents at the foot, and a subagent row's prompt
/// and result, while working and once done.
private struct RowPreviewPreviews: View {
    private var idle: SessionItem { PreviewData.subagentBoard(.f) }
    private var unfolded: SessionItem { PreviewData.subagentBoard(.c, opensFold: true) }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 24) {
                if let reply = Self.longReplyItem.reply {
                    SessionReplyCard(item: Self.longReplyItem, reply: reply, maxHeight: 800)
                    SessionReplyCard(item: Self.longReplyItem, reply: reply, maxHeight: 200)
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                if let reply = idle.reply { SessionReplyCard(item: idle, reply: reply, maxHeight: 800) }
                let rows = unfolded.subagentToggle?.list.entries.compactMap(\.row) ?? []
                if let working = rows.first(where: { $0.status == .working }) {
                    SubagentReplyCard(row: working, maxHeight: 800)
                }
                if let done = rows.first(where: { $0.reply != nil }) {
                    SubagentReplyCard(row: done, maxHeight: 800)
                }
            }
        }
        .padding(24)
    }

    /// A finished turn whose reply is far taller than the card.
    private static let longReplyItem: SessionItem = {
        let key = SessionKey(source: PreviewData.source, sessionID: "long-reply")
        let steps: [(ago: TimeInterval, kind: AgentEvent.Kind)] = [
            (900, .sessionStarted(cwd: "/Users/user/Developer/long-reply", pid: nil)),
            (899, .promptSubmitted("Explain what changed in the reply view and why.")),
            (540, .replied(agent: .root, longReply)),
            (539, .turnEnded()),
        ]
        var state = CollectiveState()
        for step in steps {
            state.apply(AgentEvent(session: key, timestamp: PreviewData.now.addingTimeInterval(-step.ago), kind: step.kind))
        }
        let model = PopoverModel(
            state: state, now: PreviewData.now, settings: PreviewData.noIdle,
            sourceNames: PreviewData.sourceNames, lastEventAt: PreviewData.now.addingTimeInterval(-2)
        )
        return (model.sessions + model.idle + model.finished).first { $0.key == key }!
    }()

    private static let longReply = """
    ## What changed

    The reply no longer opens **in place**. Its whole text reads in a card over the list instead, \
    in all three tabs, so the list keeps its height while you read.

    - The card hangs off the reply's text, 22 pt in from the card's edge.
    - It is `356 pt` wide and at most `360 pt` high, never taller than the window.
    - Past that it scrolls, with a fade at the bottom while more follows.

    ### Why

    Opening a reply in place moved every row below it, and a long reply pushed the rest of the list out of the popover. \
    The card covers the list for a moment instead and leaves it where it was.

    ```swift
    let height = ReplyCardLayout.cardHeight(content: content, container: window)
    ```

    1. Click "Show more" under the reply.
    2. Scroll inside the card; the list stays put.
    3. Select a sentence and press ⌘C.

    That is all there is to it. Header and footer stay fixed while the reply scrolls between them.
    """
}

#Preview("Reply cards · long and scrolling, in a low window, idle with subagents, subagent working and done") {
    RowPreviewPreviews()
}
#Preview("Reply cards · dark") {
    RowPreviewPreviews().preferredColorScheme(.dark)
}
#endif
