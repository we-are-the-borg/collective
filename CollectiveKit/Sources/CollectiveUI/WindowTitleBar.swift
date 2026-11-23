import AppKit
import CollectiveKit
import SwiftUI

/// The self-drawn title bar A of the settings and setup windows: 52 high on `--surface-sunken`
/// with a 1 px `--border` below and the title in the middle. The window stays the system's: its
/// scene hides the system title bar (`.windowStyle(.hiddenTitleBar)`), the real traffic lights
/// are moved to the middle of this bar, and the system's title bar area grows to its height, so
/// dragging and double-clicking anywhere in it behave as on any title bar, including the user's
/// "Double-click a window's title bar to" setting. The bar takes the system title bar's place
/// in the content, so the window gives the content no top safe area: a window sized to its
/// content (`.contentSize`) is exactly as tall as the bar and what follows it.
public struct WindowTitleBar: View {
    private let title: Text

    public static let height: CGFloat = 52
    /// The design's 0/16 insets: the first traffic light starts 16 from the edge.
    static let horizontalInset: CGFloat = 16

    public init(_ title: Text) {
        self.title = title
    }

    public var body: some View {
        title
            .font(.plexSans(13, weight: .semibold))
            .foregroundStyle(.role(.text))
            .lineLimit(1)
            // The window's own title says it; VoiceOver reads that one.
            .accessibilityHidden(true)
            .padding(.horizontal, Self.horizontalInset)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(.role(.surfaceSunken))
            .overlay(alignment: .bottom) {
                Rectangle().fill(.role(.border)).frame(height: 1)
            }
            .background(TrafficLightPlacement(barHeight: Self.height, leading: Self.horizontalInset))
    }
}

/// Moves the window's traffic lights into the bar and makes the system's title bar area as tall
/// as the bar. That area is where AppKit drags the window and takes a double-click as the user's
/// title bar action; a taller title bar container does not widen it, only the system's own title
/// bar plus its accessories count. So the placement adds an empty accessory below the
/// system's title bar, as tall as the bar has left. AppKit lays the title bar out again whenever
/// it sees fit (a resize, a change of key or main window, the end of full screen or
/// miniaturizing, another screen or backing scale, re-tiling), so the placement follows the
/// frames of the title bar's views rather than a list of window events.
///
/// It also takes the system title bar's safe area away from the content. SwiftUI sizes a
/// window as its content plus that area; compensating for it in the view, from the inset the
/// view measures, takes a second layout pass per change of size, and the window ends up at
/// whichever pass AppKit saw last.
///
/// It relies on AppKit's private view chain: button → title bar view → title bar container.
/// None of it is API, so where the chain is not as expected the placement does nothing (the
/// `guard`s) and the lights stay where the system puts them. Check it on each new macOS.
private struct TrafficLightPlacement: NSViewRepresentable {
    let barHeight: CGFloat
    let leading: CGFloat

    func makeNSView(context: Context) -> PlacementView {
        PlacementView(barHeight: barHeight, leading: leading)
    }

    func updateNSView(_ view: PlacementView, context: Context) {
        view.schedulePlacement()
    }

    final class PlacementView: NSView {
        private let barHeight: CGFloat
        private let leading: CGFloat
        private var observers: [NSObjectProtocol] = []
        /// The window's title bar area and the content's own insets; see `observeSafeArea()`.
        private var safeAreaObservations: [NSKeyValueObservation] = []
        private var observed: [ObjectIdentifier] = []
        private var isScheduled = false
        /// While `placeTitleBar()` moves the views, their frame notifications are its own and ask
        /// for nothing.
        private var isPlacing = false
        /// Where `placeTitleBar()` put each button last.
        private var placedX: [ObjectIdentifier: CGFloat] = [:]
        /// Where AppKit puts the close button.
        private var systemCloseX: CGFloat?
        /// Extends the system's title bar area to the bar's height (`extendTitleBar()`).
        private let titleBarExtension: NSTitlebarAccessoryViewController = {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .bottom
            accessory.view = NSView()
            return accessory
        }()

        init(barHeight: CGFloat, leading: CGFloat) {
            self.barHeight = barHeight
            self.leading = leading
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// The observers outlive the view in the notification center unless removed.
        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        /// Only a hook into the window: drags and double-clicks reach the title bar.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The accessory belongs to the window this view is in: a window it leaves would keep a
        /// title bar as tall as a bar it no longer shows, and the accessory would be in two
        /// windows at once once the view comes into another.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard let window, newWindow !== window,
                  let index = window.titlebarAccessoryViewControllers.firstIndex(of: titleBarExtension)
            else { return }
            window.removeTitlebarAccessoryViewController(at: index)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI sized the window with the system's area before the accessory came in.
            let sized = titleBarArea
            extendTitleBar()
            cancelTitleBarSafeArea()
            if sized > 0 { keepAtMinimum(sized) }
            observeSafeArea()
            observe(window.flatMap(TitleBarViews.init))
            schedulePlacement()
        }

        /// AppKit lays the title bar out within a change of the window's frame, and while the
        /// user drags an edge it commits that frame to the screen before the main queue's next
        /// turn: placed only from there, the lights show in the system's place on every frame
        /// of the drag. The layout pass in the same frame comes after AppKit has moved
        /// all three buttons and before the commit, so the lights move there. Not from the
        /// notification itself: AppKit moves the buttons one by one, the others still to come.
        private func titleBarMoved() {
            guard !isPlacing else { return }
            needsLayout = true
            schedulePlacement()
        }

        /// Only the title bar: a new safe area inside the layout pass would lay the content
        /// out again within it; the next turn cancels that (`place()`).
        override func layout() {
            super.layout()
            placeTitleBar()
        }

        /// Places on the next main-queue turn, outside the layout pass that moved the views,
        /// once for however many of them moved, and where no layout pass follows a move.
        func schedulePlacement() {
            guard !isPlacing, !isScheduled else { return }
            isScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isScheduled = false
                    self.place()
                }
            }
        }

        private func place() {
            extendTitleBar()
            cancelTitleBarSafeArea()
            placeTitleBar()
        }

        /// Makes the system's title bar area as tall as the bar: the accessory takes what the
        /// system's own title bar leaves of it. The area is the system's title bar plus the
        /// accessory, so its height comes out the same however often this runs, and follows a
        /// system title bar of another height. Full screen has its own title bar, left as it is.
        private func extendTitleBar() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            let accessory = titleBarExtension
            if !window.titlebarAccessoryViewControllers.contains(accessory) {
                window.addTitlebarAccessoryViewController(accessory)
            }
            let height = max(0, barHeight - (titleBarArea - accessory.view.frame.height))
            if accessory.view.frame.height != height { accessory.view.frame.size.height = height }
        }

        /// The buttons keep the system's size and spacing; only where the row sits changes. The
        /// title bar view is already as tall as the bar: AppKit sizes it and its container to the
        /// system's title bar plus the accessory. Full screen has its own title bar that slides in, which stays as it is.
        private func placeTitleBar() {
            guard let window, let views = TitleBarViews(window) else { return }
            // AppKit may build the title bar anew; follow the views it uses now.
            if views.identifiers != observed { observe(views) }
            guard !window.styleMask.contains(.fullScreen) else { return }
            isPlacing = true
            defer { isPlacing = false }
            // A button that is not where it was put last is where AppKit put it, in the
            // system's place, and moves by the shift from there; so it does not matter which
            // of them AppKit moved.
            let close = views.buttons[0]
            if close.frame.minX != placedX[ObjectIdentifier(close)] { systemCloseX = close.frame.minX }
            guard let systemCloseX else { return }
            let shift = leading - systemCloseX
            for button in views.buttons {
                let id = ObjectIdentifier(button)
                let x = button.frame.minX == placedX[id] ? button.frame.minX : button.frame.minX + shift
                let origin = NSPoint(x: x, y: ((views.titleBar.bounds.height - button.frame.height) / 2).rounded())
                placedX[id] = x
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        /// How tall the system's title bar area is: AppKit derives it from its own title bar
        /// height and the accessories, not from the container's frame.
        private var titleBarArea: CGFloat {
            window.map { max(0, $0.frame.height - $0.contentLayoutRect.maxY) } ?? 0
        }

        /// Offsets the system's top safe area with an equal negative one. The offset is set to a
        /// value computed from the window's title bar area, not adjusted by what is left over,
        /// so it comes out the same however often it runs and whatever SwiftUI set on the
        /// hosting view before.
        private func cancelTitleBarSafeArea() {
            guard let content = window?.contentView else { return }
            let area = titleBarArea
            if content.additionalSafeAreaInsets.top != -area { content.additionalSafeAreaInsets.top = -area }
        }

        /// The title bar's views need not move for the safe area to come back: SwiftUI may set
        /// the hosting view's insets anew, and AppKit may change its title bar area on its own.
        /// Both are KVO compliant (`contentLayoutRect` by its documentation, the insets as a
        /// plain property), so either change places again, which cancels the area again.
        private func observeSafeArea() {
            safeAreaObservations = []
            guard let window, let content = window.contentView else { return }
            let placeAgain: @Sendable () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.schedulePlacement() }
            }
            safeAreaObservations = [
                window.observe(\.contentLayoutRect) { _, _ in placeAgain() },
                content.observe(\.additionalSafeAreaInsets) { _, _ in placeAgain() },
            ]
        }

        /// SwiftUI sizes a new window before this view comes in: its content at the ideal height,
        /// which for these windows is the minimum, plus the system's area on top. A window that
        /// can grow keeps that height, so one that is just the area above its new minimum goes
        /// down to it. A window that opens at the height it was left at keeps it, even where
        /// that is the same height: AppKit has a saved frame for it under its autosave name
        /// (the user defaults key `NSWindow Frame <name>`, where `saveFrame(usingName:)` puts
        /// it). Runs outside the layout pass that brought the view in, after SwiftUI has taken
        /// the new minimum and restored the saved frame, still before the window first shows.
        private func keepAtMinimum(_ area: CGFloat) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let window = self?.window else { return }
                    let name = window.frameAutosaveName
                    guard name.isEmpty || UserDefaults.standard.object(forKey: "NSWindow Frame \(name)") == nil else { return }
                    let minimum = window.contentMinSize.height
                    guard minimum > 0, window.frame.height == minimum + area else { return }
                    var frame = window.frame
                    frame.origin.y += area
                    frame.size.height = minimum
                    window.setFrame(frame, display: false)
                }
            }
        }

        private func observe(_ views: TitleBarViews?) {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            observed = views?.identifiers ?? []
            // Only buttons still in use keep their positions: a replaced button's identifier
            // may come back for another object. A button AppKit only moved to a new title bar
            // stays where it was put, so its position still counts.
            let buttons = Set(views?.buttons.map(ObjectIdentifier.init) ?? [])
            placedX = placedX.filter { buttons.contains($0.key) }
            if let close = views?.buttons.first, placedX[ObjectIdentifier(close)] == nil { systemCloseX = nil }
            guard let views else { return }
            observers = views.watched.map { view in
                view.postsFrameChangedNotifications = true
                // Posted synchronously where AppKit moves the view, on the main thread.
                return NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.titleBarMoved() }
                }
            }
        }
    }
}

/// The views of the button chain the placement moves; nil where the chain is not as expected.
@MainActor
private struct TitleBarViews {
    let buttons: [NSButton]
    let titleBar: NSView
    let container: NSView

    init?(_ window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap(window.standardWindowButton)
        guard buttons.count == 3, let titleBar = buttons[0].superview,
              buttons.allSatisfy({ $0.superview === titleBar }),
              let container = titleBar.superview else { return nil }
        (self.buttons, self.titleBar, self.container) = (buttons, titleBar, container)
    }

    /// The views whose frames AppKit changes when it lays the title bar out again.
    var watched: [NSView] { buttons + [titleBar, container] }
    var identifiers: [ObjectIdentifier] { watched.map(ObjectIdentifier.init) }
}
