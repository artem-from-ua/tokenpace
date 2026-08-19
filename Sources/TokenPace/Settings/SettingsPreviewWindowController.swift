import AppKit
import TokenPaceKit

/// The **Dropdown live preview** that rides beside the Settings window (ADR-0083).
///
/// Every control on the UI panes changes what the dropdown draws — but the dropdown is hosted in the
/// status item's `NSMenu`, and a menu cannot stay open while the user works in another window. So the
/// one surface being configured is the one surface that cannot be seen. This window closes that gap:
/// it hosts a second ``PopupViewController`` fed the **same** ``PopupLayout`` as the live dropdown,
/// so it shows the real thing rather than a mock-up.
///
/// ## Why a separate window and not a view inside the pane
/// The Settings window's width is pinned at 857 pt (ADR-0069, enforced in `windowWillResize`), and the
/// popup is a fixed 390 pt wide. Embedding it would either crowd the 599-pt detail column or force the
/// width pin open — a regression of ADR-0069 for a preview. A borderless child window costs the layout
/// nothing and rides along for free.
///
/// ## Lifetime
/// Bounded by the Settings window — ``attach(to:)`` from `show(section:)`, ``detach()`` from
/// `windowWillClose` — and **within** that, by where the window is: it rides along on `Appearance` and
/// its two surface pages, and stays hidden everywhere else (``SettingsSection/showsDropdownPreview``).
///
/// It was unconditional until the surfaces became child pages of `Appearance`. The argument then was
/// that a registry of "sections that show a preview" is one more thing to keep in sync; what settled
/// it the other way is that the preview is a wide window claiming screen space beside Settings, and on
/// `About` or `Notifications` it claims that space to answer a question the user is not asking. The
/// registry is one computed property on the section, which each new pane answers as it is added.
///
/// Not an `NSWindowController`: the window is a borderless child with no independent life, so
/// `showWindow`/`close` would be the wrong contract.
@MainActor
final class SettingsPreviewWindowController {

    // MARK: - Metrics

    private enum Metrics {
        /// Gap between the Settings window's edge and the preview.
        static let gap: CGFloat = 12

        /// The margin the popup's card should show on every side of this window.
        ///
        /// The popup already carries its own outer margins, but they are tuned for life inside an
        /// `NSMenu`: `cardInset` 14 at the sides, a trimmed 10 on top (the menu adds its own padding
        /// above the hosted view) and just 4 at the bottom (a native separator follows it there). In a
        /// plain window neither of those neighbours exists, so the card would sit almost flush against
        /// the bottom edge. The insets below top the popup's own margins up to this single value, so the
        /// card is framed evenly.
        static let cardMargin: CGFloat = 14

        /// Gap between the heading and the popup content, measured to the *card*, so it matches the
        /// margin on the other three sides.
        static let headingToCard = cardMargin - 10   // popup's own `cardTopInset`

        /// Bottom gap, likewise topped up from the popup's trimmed `cardBottomInset`.
        static let belowCard = cardMargin - 4        // popup's own `cardBottomInset`

        /// Space above the heading text. Equal to the card margin so the window is framed evenly.
        static let aboveHeading: CGFloat = cardMargin

        /// The window's width before Auto Layout measures it: the popup's own fixed width. Only the
        /// height is ever in question, so this is exact rather than a guess — it is used to size the
        /// initial frame and to reserve room when centring the pair.
        ///
        /// Read from ``PopupViewController/popupWidth`` rather than repeated as a literal (#396): a
        /// second copy of the number would let the preview open at a different width than the popup it
        /// previews, and nothing would flag it.
        static let nominalWidth: CGFloat = PopupViewController.popupWidth

    }

    /// How much screen must stay clear to the right of Settings for the preview to sit there: the gap
    /// plus the preview's own width.
    ///
    /// The constraint that keeps the preview on one side
    /// (`SettingsWindowController.keepPreviewRoomOnTheRight()`) is expressed in terms of this, so the
    /// two cannot disagree about what "fits" means.
    ///
    /// A sum rather than a measured number, because every term has already moved once — Settings'
    /// width, this window's (312 → 380 with the dropdown, #396), and the gap. A literal would have gone
    /// quietly stale each time while the layout it describes changed underneath it.
    nonisolated static var roomNeededOnTheRight: CGFloat { Metrics.gap + Metrics.nominalWidth }

    /// How much screen the pair needs side by side — Settings plus ``roomNeededOnTheRight``.
    nonisolated static var pairWidth: CGFloat {
        SettingsWindowController.pinnedContentWidth + roomNeededOnTheRight
    }

    // MARK: - State

    /// The preview's own popup controller — a second instance, never the live `AppDelegate.popupVC`.
    /// Sharing one would mean one view in two window hierarchies.
    private let previewVC = PopupViewController()

    private var window: NSWindow?
    private weak var parentWindow: NSWindow?

    /// The most recent layout, retained so a window shown *between* renders paints immediately instead
    /// of waiting for the next poll (up to 30 s away via the age timer).
    private var lastLayout: PopupLayout?

    /// Local `.flagsChanged` monitor driving ``PopupViewController/optionHeld``. Live only while the
    /// preview is on screen.
    private var flagsMonitor: Any?

    /// KVO on the app's effective appearance. The window's Vibrant appearance is forced, not inherited,
    /// so a light↔dark flip has to re-force it — otherwise the preview stays frozen in the old theme.
    private var appearanceObservation: NSKeyValueObservation?

    /// The heading, retained so it can be dimmed in step with the parent window's focus.
    private weak var heading: TitlePlaqueView?

    /// The card's backing, retained so it can go opaque in step with the same focus change.
    private weak var backdrop: MenuMaterialBackdrop?

    /// Observers for the parent window becoming/resigning key.
    private var keyObservers: [NSObjectProtocol] = []

    /// Shared with the live surfaces so colour transitions stay in lockstep (ADR-0070). Assigning a
    /// *separate* animator would mean a second 30 fps timer and visibly desynchronised fades in two
    /// windows on the same screen.
    weak var colorAnimator: ColorAnimator? {
        didSet { previewVC.colorAnimator = colorAnimator }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// How much room the preview claims beside the Settings window — its own width plus the gap.
    ///
    /// Used to centre the **pair** rather than the Settings window alone: centring the parent by itself
    /// leaves the two of them visibly listing to one side, because the preview is not part of the frame
    /// AppKit is centring.
    ///
    /// Measured from the built window when there is one; before that it falls back to the nominal
    /// width, which is what the window settles at anyway — the popup is fixed-width and only its
    /// height moves.
    ///
    /// Zero while the preview is hidden for the current pane: centring the pair when there is no pair
    /// would push the Settings window off-centre by half a preview it cannot see.
    var occupiedWidth: CGFloat {
        guard isEnabledForCurrentPane else { return 0 }
        return (window?.frame.width ?? Metrics.nominalWidth) + Metrics.gap
    }

    // MARK: - Attach / detach

    /// Whether the pane currently showing in Settings is one the preview belongs beside. Written by
    /// `SettingsWindowController` from the model's route; `attach(to:)` and this setter both funnel
    /// into the same show/hide, so arriving on a preview-less pane and navigating to one behave alike.
    var isEnabledForCurrentPane = true {
        didSet {
            guard isEnabledForCurrentPane != oldValue, let parent = parentWindow else { return }
            if isEnabledForCurrentPane { attach(to: parent) } else { hide() }
        }
    }

    /// Build (once), park beside `parent`, and start tracking ⌥. Idempotent — a second call on an
    /// already-attached preview just re-parks it.
    ///
    /// A no-op beyond remembering the parent while the current pane is not one the preview belongs
    /// beside: the window is built lazily, so a session spent entirely on `About` never makes one.
    ///
    /// Call at the **end** of `show(section:)`: the parking maths reads the parent's final frame, and
    /// an `NSHostingController`-backed window is a zero-width sliver until its first layout pass.
    func attach(to parent: NSWindow) {
        parentWindow = parent
        guard isEnabledForCurrentPane else { return }
        let win = window ?? makeWindow()
        window = win

        // Re-force the Vibrant appearance on every show, not just when `observeAppearance` sees a flip.
        // The window outlives its visibility (`isReleasedWhenClosed = false`) while the KVO does not:
        // it is installed here and torn down in `detach()`. So a theme change that happens *while
        // Settings is closed* reaches nobody, and the window keeps the vibrancy it latched the last
        // time it was on screen — a preview built at night still rendering dark the next morning.
        win.appearance = PreviewChrome.vibrantAppearance

        // Paint whatever the dropdown is showing right now, before the window is ordered in — a frame
        // of empty card would otherwise flash until the next render.
        if let lastLayout { apply(lastLayout) }

        reposition()
        if win.parent == nil { parent.addChildWindow(win, ordered: .above) }
        win.orderFront(nil)
        startOptionTracking()
        observeAppearance()
        observeParentFocus(parent)
    }

    /// Dim the heading whenever the Settings window is not the active one, so it fades in step with
    /// that window's own toolbar title instead of staying at full strength beside a dimmed one.
    ///
    /// Keyed off the **parent**: this window is borderless and never becomes key itself, so its own
    /// key notifications would never fire.
    private func observeParentFocus(_ parent: NSWindow) {
        guard keyObservers.isEmpty else { return }
        applyActive(parent.isKeyWindow)
        let centre = NotificationCenter.default
        for (name, active) in [(NSWindow.didBecomeKeyNotification, true),
                               (NSWindow.didResignKeyNotification, false)] {
            let token = centre.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyActive(active) }
            }
            keyObservers.append(token)
        }
    }

    /// Both the heading and the card's backing follow the parent window's focus: the title dims, and
    /// the material settles to an opaque tone so an unfocused preview stops showing the desktop through
    /// itself.
    private func applyActive(_ active: Bool) {
        heading?.isWindowActive = active
        backdrop?.isWindowActive = active
    }

    /// Take the preview off screen because the pane showing in Settings is not one it belongs beside.
    ///
    /// The same teardown as ``detach()`` — the distinction is only in why, and `parentWindow` survives
    /// both, which is what lets ``isEnabledForCurrentPane`` bring it straight back on the next
    /// preview-bearing pane without `show(section:)` running again.
    private func hide() { detach() }

    /// Order out, drop the child relationship, and stop tracking. Idempotent: `windowWillClose` can
    /// arrive for a preview that was already detached (e.g. after a miniaturise).
    func detach() {
        stopOptionTracking()
        appearanceObservation = nil
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers.removeAll()
        guard let win = window else { return }
        win.parent?.removeChildWindow(win)
        win.orderOut(nil)
    }

    // MARK: - Feeding

    /// Mirror of `AppDelegate.setPopupLayout`. Called on **every** render — poll, animation frame,
    /// settings callback, preset application — because that is the single point all of them pass
    /// through. No-op while hidden, so a closed Settings window costs one nil check per poll.
    func update(_ layout: PopupLayout) {
        lastLayout = layout
        guard isVisible else { return }
        apply(layout)
    }

    private func apply(_ layout: PopupLayout) {
        syncPresentation()
        previewVC.layout = layout
        resizeToFit()
    }

    /// Re-read the three dropdown knobs the popup VC does not read for itself (it is deliberately
    /// config-free — `AppDelegate` pushes them into the live instance the same way).
    ///
    /// Reading `PersistedConfig` rather than taking three more callbacks is safe because `SettingsModel`
    /// persists *before* it fires (`persist first, then callback`), so by the time a change has
    /// travelled to a re-render the stored value is already the new one.
    ///
    /// `calmColorMode` is absent on purpose: it is a menu-bar concern, and reaches the popup already
    /// baked into `PopupLayout`. Adding it here would change nothing.
    private func syncPresentation() {
        previewVC.barStyle = PersistedConfig.dropdownStyle
        previewVC.modelLimitsVisibility = PersistedConfig.showPerModelLimits
        previewVC.extraUsageVisibility = PersistedConfig.showExtraUsage
    }

    // MARK: - ⌥ Option

    /// Track ⌥ with a local event monitor.
    ///
    /// The dropdown itself cannot do this — `NSMenu` tracking runs a modal `NSEventTrackingRunLoopMode`
    /// that starves event monitors, which is why `AppDelegate` polls with a timer there (ADR-0020 §3).
    /// A plain window runs no such mode, so a monitor is the right tool here. The two ⌥ states are
    /// independent: they drive two different `PopupViewController`s, and the menu cannot be open while
    /// Settings is being used.
    private func startOptionTracking() {
        guard flagsMonitor == nil else { return }
        // Seed from the modifiers already down — a monitor only ever reports *changes*, and the user
        // may well arrive with ⌥ held.
        applyOption(NSEvent.modifierFlags.contains(.option))
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.applyOption(event.modifierFlags.contains(.option)) }
            // Never swallow: returning nil would eat .flagsChanged for the whole process and silently
            // break ⌥ in the real dropdown — a bug that would read as an ADR-0020 regression.
            return event
        }
    }

    private func stopOptionTracking() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        previewVC.optionHeld = false   // next show starts clean, mirroring `menuDidClose`
    }

    private func applyOption(_ held: Bool) {
        guard previewVC.optionHeld != held else { return }
        previewVC.optionHeld = held
        // ⌥ reveals whole sections, so the height changes. The VC's didSet rebuilds the views but
        // nothing resizes the window — the same re-fit the live popup needs after an ⌥ swap.
        resizeToFit()
    }

    // MARK: - Appearance

    /// Re-force the Vibrant appearance when the system theme flips.
    ///
    /// The material backdrop and the labels re-resolve on their own, but the window's forced appearance
    /// is a one-shot assignment — without this the preview keeps rendering its neutrals in the
    /// *previous* theme's vibrancy.
    private func observeAppearance() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.appearance = PreviewChrome.vibrantAppearance
                // Endpoints of an in-flight tween describe the *old* appearance; blending across a
                // theme flip would fade through colours neither theme has (ADR-0070).
                self.colorAnimator?.finishAll()
            }
        }
    }

    // MARK: - Geometry

    /// Size the window to its content and re-park it. The popup's width is fixed; its height moves with
    /// the section composition (and jumps under ⌥).
    private func resizeToFit() {
        guard let win = window, let container = win.contentView else { return }
        win.setContentSize(container.fittingSize)
        win.layoutIfNeeded()
        reposition()
    }

    /// Park to the **right** of the parent, top edges aligned. Always that side.
    ///
    /// It used to hop to the left when the right ran out, and to sit on top of Settings when neither
    /// side fitted. Both were worse than they sounded: a preview that changes sides between sessions
    /// has to be found again each time, and one that overlaps hides the controls it exists to preview.
    ///
    /// So the side is fixed and the *parent* is constrained instead —
    /// `SettingsWindowController.keepPreviewRoomOnTheRight()` will not let the window be dragged past
    /// the point where ``roomNeededOnTheRight`` stops fitting. The clamp below is a floor for the cases
    /// that constraint cannot reach: a screen change, a restored frame from a larger display.
    func reposition() {
        guard let win = window, let parent = parentWindow else { return }
        let parentFrame = parent.frame
        let size = win.frame.size
        // The parent's own screen, not `NSScreen.main`: main is the screen with focus, which on a
        // multi-display setup is often not the one the window sits on.
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame

        var x = parentFrame.maxX + Metrics.gap
        if let visible { x = min(x, visible.maxX - size.width) }

        // Top edges aligned, and **left** aligned — no clamp to the screen's bottom.
        //
        // The clamp used to lift the preview whenever it would have hung below the visible frame,
        // which is what happens as soon as Settings is dragged low. The result was a preview that
        // stopped following its parent and drifted upward out of line with it, breaking the one
        // relationship this placement is for. Letting the bottom run off screen keeps the two locked
        // together: what is lost is the tail of a card whose interesting end is its top, and the fix is
        // to move the window the reader is already holding.
        let y = parentFrame.maxY - size.height

        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Building

    private func makeWindow() -> NSWindow {
        previewVC.loadView()   // every knob's didSet is gated on isViewLoaded
        previewVC.colorAnimator = colorAnimator
        // `onToggleSubscription` is deliberately left nil: the preview is a mirror, not a second set of
        // controls. The subscribe row still draws (it is part of the layout); clicking it does nothing.
        syncPresentation()

        let win = NSWindow(contentRect: NSRect(origin: .zero,
                                               size: NSSize(width: Metrics.nominalWidth, height: 320)),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.hasShadow = true
        // Transparent so the card's rounded corners show; an opaque frame would sit behind them as
        // square corners. No explicit level: as a child window it rides the parent's.
        win.isOpaque = false
        win.backgroundColor = .clear
        win.appearance = PreviewChrome.vibrantAppearance
        win.contentView = buildContent()
        return win
    }

    /// The card: a heading and the popup itself, nothing else.
    ///
    /// No divider under the heading and no footer. The dev tuner has both — mock "update available"
    /// rows to expose those two colours for tuning, and a rule to fence them off — but here each would
    /// be furniture the real dropdown does not have, and the mock rows would read as a live
    /// notification. The heading floats over the same material as the card, so the window stays one
    /// surface with a label on it.
    private func buildContent() -> NSView {
        previewVC.view.translatesAutoresizingMaskIntoConstraints = false

        // The second line advertises ⌥, which is otherwise a feature only a user who happens to hold
        // the key will ever find: the modifier reveals whole sections here exactly as it does in the
        // real dropdown. `⌥` is the Unicode key glyph (U+2325), the same one the visibility segments
        // and the dropdown's own captions use — not an SF Symbol, so it renders inline in a label.
        let heading = TitlePlaqueView(title: "Dropdown live preview",
                                      subtitle: "try alt view with the ⌥ Option key")
        heading.translatesAutoresizingMaskIntoConstraints = false
        self.heading = heading

        // The real menu material, not a flat fill: the popup's own card is translucent by design and
        // expects something to show through it. See `PreviewChrome.makeMenuMaterialBackdrop`.
        let container = PreviewChrome.makeMenuMaterialBackdrop()
        self.backdrop = container

        container.addSubview(heading)
        container.addSubview(previewVC.view)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.aboveHeading),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // The popup view spans the full width — its own `cardInset` provides the side margins.
            previewVC.view.topAnchor.constraint(equalTo: heading.bottomAnchor,
                                                constant: Metrics.headingToCard),
            previewVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: previewVC.view.bottomAnchor,
                                              constant: Metrics.belowCard),
        ])
        return container
    }
}
