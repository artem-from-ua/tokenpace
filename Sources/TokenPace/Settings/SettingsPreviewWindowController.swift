import AppKit
import TokenPaceKit

/// The **Dropdown live preview** that rides beside the Settings window (ADR-0083). The dropdown is
/// hosted in the status item's `NSMenu`, which cannot stay open while the user works in another
/// window — this window closes that gap by hosting a second ``PopupViewController`` fed the **same**
/// ``PopupLayout`` as the live dropdown.
///
/// A separate window, not a view inside the pane: Settings' width is pinned at 857 pt (ADR-0069),
/// and the popup is a fixed 390 pt — embedding it would crowd the detail column or force the pin open.
///
/// Lifetime bounded by the Settings window (``attach(to:)`` / ``detach()``), and within that, by
/// where the window is — visible only on `Appearance` and its surface pages
/// (``SettingsSection/showsDropdownPreview``).
///
/// Not an `NSWindowController`: the window is a borderless child with no independent life, so
/// `showWindow`/`close` would be the wrong contract.
@MainActor
final class SettingsPreviewWindowController {

    // MARK: - Metrics

    private enum Metrics {
        /// Gap between the Settings window's edge and the preview.
        static let gap: CGFloat = 12

        /// The margin the popup's card should show on every side of this window. The popup's own
        /// margins are tuned for life inside an `NSMenu` (trimmed top/bottom for the menu's own
        /// padding and separator), which don't exist in a plain window — these top the popup's own
        /// margins up to one even value.
        static let cardMargin: CGFloat = 14

        /// Measured to the *card*, so it matches the margin on the other three sides.
        static let headingToCard = cardMargin - 10   // popup's own `cardTopInset`

        static let belowCard = cardMargin - 4        // popup's own `cardBottomInset`

        static let aboveHeading: CGFloat = cardMargin

        /// The popup's own fixed width — read from ``PopupViewController/popupWidth`` rather than
        /// repeated as a literal (#396), so the preview cannot silently open at a different width.
        static let nominalWidth: CGFloat = PopupViewController.popupWidth

    }

    /// How much screen must stay clear to the right of Settings: the gap plus the preview's own
    /// width. `SettingsWindowController.keepPreviewRoomOnTheRight()` is expressed in terms of this,
    /// so the two cannot disagree about what "fits" means.
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
    /// of waiting for the next poll (up to 30 s away).
    private var lastLayout: PopupLayout?

    /// Local `.flagsChanged` monitor driving ``PopupViewController/optionHeld``. Live only while the
    /// preview is on screen.
    private var flagsMonitor: Any?

    /// The window's Vibrant appearance is forced, not inherited, so a light↔dark flip has to
    /// re-force it via this KVO — otherwise the preview stays frozen in the old theme.
    private var appearanceObservation: NSKeyValueObservation?

    /// The heading, retained so it can be dimmed in step with the parent window's focus.
    private weak var heading: TitlePlaqueView?

    /// The card's backing, retained so it can go opaque in step with the same focus change.
    private weak var backdrop: MenuMaterialBackdrop?

    /// Observers for the parent window becoming/resigning key.
    private var keyObservers: [NSObjectProtocol] = []

    /// Shared with the live surfaces so colour transitions stay in lockstep (ADR-0070) — a *separate*
    /// animator would mean a second 30 fps timer and desynchronised fades in two windows on screen.
    weak var colorAnimator: ColorAnimator? {
        didSet { previewVC.colorAnimator = colorAnimator }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// How much room the preview claims beside Settings, so the **pair** can be centred rather than
    /// the Settings window alone (which would list to one side, since AppKit doesn't know about the
    /// preview). Zero while the preview is hidden for the current pane.
    var occupiedWidth: CGFloat {
        guard isEnabledForCurrentPane else { return 0 }
        return (window?.frame.width ?? Metrics.nominalWidth) + Metrics.gap
    }

    // MARK: - Attach / detach

    /// Written by `SettingsWindowController` from the model's route; `attach(to:)` and this setter
    /// both funnel into the same show/hide.
    var isEnabledForCurrentPane = true {
        didSet {
            guard isEnabledForCurrentPane != oldValue, let parent = parentWindow else { return }
            if isEnabledForCurrentPane { attach(to: parent) } else { hide() }
        }
    }

    /// Build (once), park beside `parent`, and start tracking ⌥. Idempotent. The window is built
    /// lazily, so a session spent entirely on `About` never makes one.
    ///
    /// Call at the **end** of `show(section:)`: the parking maths reads the parent's final frame, and
    /// an `NSHostingController`-backed window is a zero-width sliver until its first layout pass.
    func attach(to parent: NSWindow) {
        parentWindow = parent
        guard isEnabledForCurrentPane else { return }
        let win = window ?? makeWindow()
        window = win

        // Re-force the Vibrant appearance on every show, not just on a flip `observeAppearance` sees:
        // the KVO is torn down in `detach()`, so a theme change while Settings is closed reaches
        // nobody and the window would keep the vibrancy it last latched.
        win.appearance = PreviewChrome.vibrantAppearance

        // Paint whatever the dropdown is showing right now, before ordering in, or an empty card
        // flashes until the next render.
        if let lastLayout { apply(lastLayout) }

        reposition()
        if win.parent == nil { parent.addChildWindow(win, ordered: .above) }
        win.orderFront(nil)
        startOptionTracking()
        observeAppearance()
        observeParentFocus(parent)
    }

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

    /// Same teardown as ``detach()``, but `parentWindow` survives — lets ``isEnabledForCurrentPane``
    /// bring it straight back on the next preview-bearing pane.
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

    /// Re-read the three dropdown knobs the popup VC does not read for itself (config-free by design
    /// — `AppDelegate` pushes them into the live instance the same way). Reading `PersistedConfig`
    /// directly is safe because `SettingsModel` persists *before* it fires its callback.
    private func syncPresentation() {
        previewVC.barStyle = PersistedConfig.dropdownStyle
        previewVC.modelLimitsVisibility = PersistedConfig.showPerModelLimits
        previewVC.extraUsageVisibility = PersistedConfig.showExtraUsage
    }

    // MARK: - ⌥ Option

    /// A plain window runs no modal tracking loop, so a local monitor works here — unlike the real
    /// dropdown's `NSMenu`, which starves event monitors and needs a timer instead (ADR-0020 §3).
    private func startOptionTracking() {
        guard flagsMonitor == nil else { return }
        // Seed from the modifiers already down — a monitor only ever reports *changes*.
        applyOption(NSEvent.modifierFlags.contains(.option))
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.applyOption(event.modifierFlags.contains(.option)) }
            // Never swallow: returning nil would eat .flagsChanged for the whole process and silently
            // break ⌥ in the real dropdown.
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
        // ⌥ reveals whole sections, so the height changes; the VC's didSet rebuilds the views but
        // nothing resizes the window.
        resizeToFit()
    }

    // MARK: - Appearance

    /// The window's forced appearance is a one-shot assignment, unlike the material backdrop and
    /// labels which re-resolve on their own — without this the preview keeps rendering its neutrals
    /// in the *previous* theme's vibrancy.
    private func observeAppearance() {
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.appearance = PreviewChrome.vibrantAppearance
                // An in-flight tween's endpoints describe the *old* appearance; blending across a
                // theme flip would fade through colors neither theme has (ADR-0070).
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

    /// Park to the **right** of the parent, top edges aligned. Always that side: hopping sides makes
    /// the preview hard to find again, and overlapping Settings hides the controls it previews. The
    /// side is fixed and the *parent* is constrained instead —
    /// `SettingsWindowController.keepPreviewRoomOnTheRight()` won't let Settings be dragged past the
    /// point where ``roomNeededOnTheRight`` stops fitting. The clamp below is a floor for cases that
    /// constraint can't reach (a screen change, a restored frame from a larger display).
    func reposition() {
        guard let win = window, let parent = parentWindow else { return }
        let parentFrame = parent.frame
        let size = win.frame.size
        // The parent's own screen, not `NSScreen.main`, which is whichever screen has focus.
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame

        var x = parentFrame.maxX + Metrics.gap
        if let visible { x = min(x, visible.maxX - size.width) }

        // No clamp to the screen's bottom: letting the preview run off screen keeps it locked to
        // Settings as it's dragged low, rather than drifting out of line with it.
        let y = parentFrame.maxY - size.height

        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Building

    private func makeWindow() -> NSWindow {
        previewVC.loadView()   // every knob's didSet is gated on isViewLoaded
        previewVC.colorAnimator = colorAnimator
        // No ⌥ caption (#475): it stands in for the real dropdown's action items, which this window
        // has none of — offering "more" that ⌥ cannot deliver is worse than no line. ⌥ still works in
        // the preview otherwise.
        previewVC.optionHintEnabled = false
        // This popup lives in a window, not a menu, so it keeps the trimmed bottom inset —
        // the window supplies the rest of the margin, and framing its own bottom too would double it.
        previewVC.hostedInMenu = false
        // `onToggleSubscription` is deliberately left nil: the preview is a mirror, not a second set
        // of controls. The subscribe row still draws; clicking it does nothing.
        syncPresentation()

        let win = NSWindow(contentRect: NSRect(origin: .zero,
                                               size: NSSize(width: Metrics.nominalWidth, height: 320)),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.hasShadow = true
        // Transparent so the card's rounded corners show, not square ones behind them.
        win.isOpaque = false
        win.backgroundColor = .clear
        win.appearance = PreviewChrome.vibrantAppearance
        win.contentView = buildContent()
        return win
    }

    /// The card: a heading and the popup itself, nothing else — no divider, no footer (the dev tuner
    /// has both, but here they'd be furniture the real dropdown lacks).
    private func buildContent() -> NSView {
        previewVC.view.translatesAutoresizingMaskIntoConstraints = false

        // `⌥` is the Unicode key glyph (U+2325), the same one the dropdown's own captions use — not
        // an SF Symbol, so it renders inline in a label.
        let heading = TitlePlaqueView(title: "Dropdown live preview",
                                      subtitle: "try alt view with the ⌥ Option key")
        heading.translatesAutoresizingMaskIntoConstraints = false
        self.heading = heading

        // The real menu material, not a flat fill — the popup's own card is translucent by design.
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
