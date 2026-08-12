import AppKit
import SwiftUI
import TokenPaceKit

// MARK: - SettingsWindowController

/// The "Settings…" window (#14, redesigned #131, rewritten on SwiftUI #168 / ADR-0042): a macOS
/// System Settings-style window reached from the popup menu — a sidebar of sections on the left, a
/// detail pane of grouped `Form` cards on the right, hosted in an `NSWindow` via `NSHostingController`.
///
/// The controller is a thin hosting wrapper. All state and behaviour live in `SettingsModel`
/// (`@Observable`), which the SwiftUI tree binds to. The controller keeps the exact public contract
/// the `AppDelegate` wires (`AppDelegate.openSettings`): the ten `on…Change`/provider callbacks plus
/// `updateAvailability(_:)` and `updateArchiveStatus()`. Those properties forward straight into the
/// model, so `App.swift` is unchanged.
///
/// Because the model is created in `init` and lives as long as the controller, the background poll
/// completions (`updateAvailability`/`updateArchiveStatus`, fired while the window is closed) mutate
/// model state rather than a view outlet — so the panes can build lazily and the old eager-build
/// invariant is gone (ADR-0042).
///
/// Opened from an accessory (menu-bar) app, so it uses `NSApp.activate` + a floating window level to
/// come to the front (ADR-0012 §6), rather than switching activation policy to `.regular`.
@MainActor
final class SettingsWindowController: NSWindowController {

    private enum Metrics {
        /// Fixed window content width, matching System Settings exactly (measured 857 pt, #156). Still
        /// pinned min == max: only the **height** resizes (ADR-0069). The sidebar/detail split is tuned
        /// to this width (sidebar 258, detail 599) and would reflow if the user could drag it.
        static let contentWidth: CGFloat = 857
        /// Content height the window **opens at** — a default since ADR-0069, a hard size before it.
        /// It was hand-bumped every time the Appearance pane grew an option: 480 → 520 (#199) → 560
        /// (#211) → 600 (#215) → 636 (the "Work harder" toggle) → 684 → 776 (#224 — "Bar style", the
        /// "Far behind pace interval" section, "Show ticks on bars"), trimmed to 720 (#224 — the Calm
        /// and Work-harder toggles merged into one segmented row), then 732 for the "Show reset
        /// countdown" row's Smart-explanation line (#224). The window is height-resizable now and the
        /// grouped `Form` scrolls, so a new option no longer *requires* a bump — bump this only to
        /// keep the opening size comfortable.
        static let defaultContentHeight: CGFloat = 732
        /// Smallest content height the user can drag to. Matches ``SettingsRootView``'s own floor
        /// (passed to it explicitly below, so the two cannot drift): below it SwiftUI stops shrinking
        /// and would clip the detail pane instead of letting the grouped `Form` scroll.
        static let minContentHeight: CGFloat = 480
    }

    /// The single observable state object, alive for the controller's lifetime (so background
    /// callbacks always have somewhere to write — see the type doc).
    private let model = SettingsModel()

    /// The window's toolbar — ‹ › plus the pane name, System Settings' own header (#156 §2).
    private let toolbarController = SettingsToolbarController()

    // MARK: Public callbacks (the AppDelegate contract — forwarded into the model, unchanged surface)

    /// Called when the user changes the monitored-services selection (#89), with the new config.
    var onMonitoredServicesChange: ((MonitoredServices) -> Void)? {
        get { model.onMonitoredServicesChange } set { model.onMonitoredServicesChange = newValue }
    }

    /// Called when the user clicks "Check now" (#37) — runs an immediate update check.
    var onCheckForUpdatesNow: (() -> Void)? {
        get { model.onCheckForUpdatesNow } set { model.onCheckForUpdatesNow = newValue }
    }

    /// Called when the user clicks "Update Now" (#221) — installs the known release immediately,
    /// bypassing the power/metered courtesy gates.
    var onInstallUpdateNow: (() -> Void)? {
        get { model.onInstallUpdateNow } set { model.onInstallUpdateNow = newValue }
    }

    /// Called when the user changes the calm-colours mode (#105, #224), with the new `CalmColorMode`.
    var onCalmColorModeChange: ((CalmColorMode) -> Void)? {
        get { model.onCalmColorModeChange } set { model.onCalmColorModeChange = newValue }
    }

    /// Called when the user changes the menu-bar "Reset countdown" mode (#103), with the new mode.
    var onResetCountdownModeMenuBarChange: ((ResetCountdownMode) -> Void)? {
        get { model.onResetCountdownModeMenuBarChange } set { model.onResetCountdownModeMenuBarChange = newValue }
    }

    /// Called when the user changes the **Menu Bar Widget** section's "Bar style" control (#224,
    /// #329), with the new style. Menu bar only — the dropdown has its own callback.
    var onMenuBarStyleChange: ((BarStyle) -> Void)? {
        get { model.onMenuBarStyleChange } set { model.onMenuBarStyleChange = newValue }
    }

    /// Called when the user changes the **Dropdown Widget** section's "Bar style" control (#329),
    /// with the new style. Popup only.
    var onDropdownStyleChange: ((BarStyle) -> Void)? {
        get { model.onDropdownStyleChange } set { model.onDropdownStyleChange = newValue }
    }

    /// Called when the user toggles "Show ticks on bars" (#224), with the new state. Popup-only.
    var onShowTicksChange: ((Bool) -> Void)? {
        get { model.onShowTicksChange } set { model.onShowTicksChange = newValue }
    }

    /// Called when the user toggles "Show service status dot on issues" (#31), with the new state.
    var onServiceDotChange: ((Bool) -> Void)? {
        get { model.onServiceDotChange } set { model.onServiceDotChange = newValue }
    }

    /// Called when the user toggles "Show extra-usage credits icon" (#146), with the new state.
    var onExtraUsageChange: ((Bool) -> Void)? {
        get { model.onExtraUsageChange } set { model.onExtraUsageChange = newValue }
    }

    /// Called when the user changes when "Show model & service limits" appears (#211), with the new mode.
    var onModelLimitsVisibilityChange: ((PopupSectionVisibility) -> Void)? {
        get { model.onModelLimitsVisibilityChange } set { model.onModelLimitsVisibilityChange = newValue }
    }

    /// Called when the user changes when the dropdown's "Extra usage" section appears, with the new mode.
    var onExtraUsageVisibilityChange: ((PopupSectionVisibility) -> Void)? {
        get { model.onExtraUsageVisibilityChange } set { model.onExtraUsageVisibilityChange = newValue }
    }

    /// Called when the user toggles "Hide 7-day bar when calm" (#94), with the new state.
    var onHideCalmSevenDayChange: ((Bool) -> Void)? {
        get { model.onHideCalmSevenDayChange } set { model.onHideCalmSevenDayChange = newValue }
    }

    /// Called when the user toggles "Pause icon hides bars" (#194, #227), with the new state — `true`
    /// hides the bars when fully blocked (pause icon only), `false` keeps them beside the icon.
    var onPauseHidesBarsChange: ((Bool) -> Void)? {
        get { model.onPauseHidesBarsChange } set { model.onPauseHidesBarsChange = newValue }
    }

    /// Called when the user toggles "Pause polling while the screen is locked" (#114).
    var onPausePollingChange: ((Bool) -> Void)? {
        get { model.onPausePollingChange } set { model.onPausePollingChange = newValue }
    }

    /// Called when the awaiting-input master toggle flips (#233) — start/stop the watcher + re-render.
    var onAwaitingInputEnabledChange: ((Bool) -> Void)? {
        get { model.onAwaitingInputEnabledChange } set { model.onAwaitingInputEnabledChange = newValue }
    }

    /// Called when an awaiting-input appearance option changes (#233) — re-render only.
    var onAwaitingInputAppearanceChange: (() -> Void)? {
        get { model.onAwaitingInputAppearanceChange } set { model.onAwaitingInputAppearanceChange = newValue }
    }

    /// Called when the user clicks "Archive now" (#110).
    var onArchiveNow: (() -> Void)? {
        get { model.onArchiveNow } set { model.onArchiveNow = newValue }
    }

    /// Called when the user turns the "Back to work" notification on (#160) — lazily requests
    /// notification authorization; the completion reports the resolved state so the pane refreshes.
    var onBackToWorkEnabled: ((@escaping @MainActor (BackToWorkNotifier.AuthState) -> Void) -> Void)? {
        get { model.onBackToWorkEnabled } set { model.onBackToWorkEnabled = newValue }
    }

    /// Fires the "Back to work!" notification on demand from the Settings "Try" button (#193).
    var onTryBackToWork: (() -> Void)? {
        get { model.onTryBackToWork } set { model.onTryBackToWork = newValue }
    }

    /// Fires the "Switching to Extra Usage" notification on demand from its Settings "Try" button.
    var onTryExtraUsage: (() -> Void)? {
        get { model.onTryExtraUsage } set { model.onTryExtraUsage = newValue }
    }

    /// Preview every incident banner at once (#279).
    var onPreviewIncidents: (() -> Void)? {
        get { model.onPreviewIncidents } set { model.onPreviewIncidents = newValue }
    }

    /// Provides the last archive summary for the status line (#110).
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)? {
        get { model.archiveSummaryProvider } set { model.archiveSummaryProvider = newValue }
    }

    /// Whether the window has been positioned yet — so the first `show()` of a session centres it, and
    /// later shows leave the user's position alone (#131).
    private var hasBeenPositioned = false

    convenience init() {
        // Width-pinned, height-resizable (ADR-0069). System Settings sizes itself to the current pane
        // and offers no resize at all (#156), which worked while our panes were small — but Appearance
        // outgrew every screen it was measured on, and its height had to be hand-bumped each time.
        // Letting the user set the height (and the grouped `Form` scroll below it) retires that ritual;
        // the width stays fixed because the sidebar/detail split is tuned to it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: Metrics.contentWidth, height: Metrics.defaultContentHeight),
            // `.fullSizeContentView` is what makes the transparent title bar actually read as System
            // Settings' rather than as a hole: without it the content stops below the bar, so the
            // strip above the sidebar draws the *window's* background (measured 40,40,40) while the
            // sidebar's vibrancy below it is 70,70,70 — a visible seam right where the traffic lights
            // sit. With it, the split view runs the full height and the sidebar material continues
            // behind them, exactly as in System Settings.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // System Settings' chrome: no text in the title bar, and the bar itself transparent so the
        // sidebar's material runs up behind the traffic lights instead of stopping at a separate grey
        // strip (#156 §2). The pane's name is not lost — it moves into the detail pane's toolbar, which
        // is where System Settings shows it too. `title` still carries the app name for the places
        // AppKit reads it without drawing it (the Window menu, Mission Control, Accessibility).
        window.title = "TokenPace Settings"
        window.titleVisibility = .hidden
        // NOT transparent any more. While the toolbar was empty, transparency was what let the
        // sidebar's material run up behind the traffic lights. Now the toolbar carries the ‹ › and the
        // pane name, and a transparent bar has no surface of its own — scrolled content passed
        // straight through it and collided with the header text. Opaque, the bar gets the system's own
        // toolbar material: content blurs *under* it rather than through it, which is what System
        // Settings does.
        window.titlebarAppearsTransparent = false
        window.level = .floating               // float above other apps from a menu-bar app (ADR-0012 §6)
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        // Zoom means "as tall as the screen" here, not "as large as the screen" — see
        // `windowWillUseStandardFrame`. Full screen is refused outright: a `.floating` window in its
        // own Space fights whatever app is actually full-screen (the conflict that made ADR-0020 drop
        // `.floating` from Troubleshoot; here we keep the level and drop full screen instead).
        window.collectionBehavior.insert(.fullScreenNone)
        // No `setFrameAutosaveName`, even though the frame *is* persisted now (ADR-0069): autosave
        // restores a frame before anything can check it against the current screen layout, which is
        // the off-screen failure ADR-0035 removed persistence over. `PersistedConfig.settingsWindowFrame`
        // plus `WindowFrameValidator` give us "read → validate → apply once" instead (see `show()`).
        self.init(window: window)
        window.delegate = self                 // zoom shape + frame persistence (below); `delegate` is weak
        // The toolbar carries the ‹ › history buttons and the pane's name, as System Settings' does
        // (verified over the Accessibility API — see `SettingsToolbarController`), and its height is
        // also what lifts the traffic lights onto the system's measured (25.75, 25.75) pt position.
        // Both jobs, one bar: while it stood empty, its reserved strip was dead space that the detail
        // column had to cancel out with negative offsets. Installed after `self.init` because the
        // callbacks capture `self`.
        toolbarController.onBack = { [weak self] in self?.model.goBack() }
        toolbarController.onForward = { [weak self] in self?.model.goForward() }
        toolbarController.install(on: window)
        let hosting = NSHostingController(
            rootView: SettingsRootView(model: model,
                                       minWidth: Metrics.contentWidth,
                                       minHeight: Metrics.minContentHeight))
        // Don't let the hosting controller drive the window size from SwiftUI's ideal — the width is
        // pinned and the height is the user's, and a NavigationSplitView's ideal would otherwise
        // collapse the window to a sliver.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // Bounds go on **after** the hosting controller: assigning a `contentViewController`
        // re-derives them from the SwiftUI tree and would overwrite anything set earlier. They are
        // re-applied on every `show()` for the same reason — see `pinSizeBounds()`.
        pinSizeBounds()
    }

    /// Merge the strip AppKit lays over the sidebar's titlebar area into the sidebar itself, so the
    /// two stop showing a seam between them (#312).
    ///
    /// `NavigationSplitView` puts a `.titlebar`-material `NSVisualEffectView` above **each** column —
    /// over the sidebar it measures exactly the sidebar's width by the titlebar's height, sitting on
    /// top of the column's own `.sidebar` material. Both follow the window's active state, but they
    /// are different materials, so they dim by different amounts: the moment the window stops being
    /// key — or is dragged, which repaints them — their boundary shows up as a horizontal line right
    /// under the traffic lights. System Settings has no such line.
    ///
    /// Every cheaper lever was measured and leaves the strip in place: `.unifiedCompact`,
    /// `titlebarAppearsTransparent`, `titlebarSeparatorStyle = .none`,
    /// `.ignoresSafeArea(.container, .top)`, `.toolbarBackground(.hidden)` — and it is still there
    /// with **no toolbar at all**, which is what proves `NavigationSplitView` creates it rather than
    /// our toolbar. Giving that strip the sidebar's own material is what removes the boundary, since
    /// there is then only one material to dim.
    ///
    /// Re-applied whenever the SwiftUI tree may have rebuilt it (see `show()`); a no-op once it holds.
    private func mergeSidebarTitlebarStrip() {
        guard let window, let themeFrame = window.contentView?.superview else { return }
        let sidebarWidth = model.sidebarIcons.sidebarWidth
        func merge(_ view: NSView) {
            if let effect = view as? NSVisualEffectView, effect.material == .titlebar {
                // Width identifies it: the sidebar's strip matches the column, the detail column's
                // strip is far wider and must keep its titlebar material.
                let widthInWindow = effect.convert(effect.bounds, to: nil).width
                if abs(widthInWindow - sidebarWidth) < 1 { effect.material = .sidebar }
            }
            view.subviews.forEach(merge)
        }
        merge(themeFrame)
    }

    /// Show or re-focus the window. Re-syncs every field from `PersistedConfig`/the system into the
    /// model, brings the app forward, and centres it on the first display of a session. Calling this
    /// while the window is already on screen just focuses it.
    ///
    /// Pass a non-nil `section` to force the window onto that pane (#210 — the update menu item opens
    /// straight to About). `nil` leaves the current selection alone: a fresh window is on About (the
    /// model default), a reused one keeps its last-viewed pane. The `TOKENPACE_SETTINGS_SECTION` dev
    /// hook is applied *after* this, so it still wins during verification.
    func show(section: SettingsSection? = nil) {
        model.syncFromConfig()
        if let section { model.selection = section }
        // Reflect the latest known update state whenever the window opens (#37) is already carried by
        // `updateAvailability`, called by `AppDelegate.openSettings` before `show()`.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        pinSizeBounds()
        // All geometry happens once per session, here. Every later show leaves the window exactly as
        // the user left it — it is theirs to resize now (ADR-0069), and re-applying a size on each
        // open would throw that away.
        if !hasBeenPositioned {
            hasBeenPositioned = true
            applyRestoredOrDefaultFrame()
        }
        window?.makeKeyAndOrderFront(nil)
        // Dev helper: `TOKENPACE_SETTINGS_SECTION=<index>` opens straight to a given pane (0-based).
        if let raw = ProcessInfo.processInfo.environment["TOKENPACE_SETTINGS_SECTION"],
           let idx = Int(raw), let section = SettingsSection(rawValue: idx) {
            model.selection = section
        }
        observeToolbarState()
        // After the tree is on screen: the strip does not exist until SwiftUI has laid the split view
        // out, and a reopened window may have rebuilt it. Once more on the next turn of the run loop,
        // because the first pass can land before the columns have their final width.
        mergeSidebarTitlebarStrip()
        DispatchQueue.main.async { [weak self] in
            self?.mergeSidebarTitlebarStrip()
        }
    }

    /// Keep the toolbar's title and ‹ › enablement in step with the model.
    ///
    /// `withObservationTracking` fires once per change, so the continuation re-arms itself: the
    /// selection moves whenever the user picks a sidebar row, which is SwiftUI's write, not ours —
    /// there is no single call site to hook instead.
    private func observeToolbarState() {
        withObservationTracking {
            toolbarController.update(title: model.currentPaneTitle,
                                     canGoBack: model.canGoBack,
                                     canGoForward: model.canGoForward)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeToolbarState() }
        }
    }

    // MARK: Geometry (ADR-0069)

    /// One-shot geometry for the first show of the session: restore the persisted frame when it still
    /// makes sense on the screens attached *right now*, otherwise open at the default size, centred.
    ///
    /// The ordering here is the whole point. `NSHostingController` content has no intrinsic size, so
    /// until something sizes it the window is a zero-width title-bar sliver — and `center()` computed
    /// at zero width puts the left edge at the screen's centre, after which growing to 857 pushes the
    /// right half off-screen. That was ADR-0035's off-screen bug. So: size first, position second, and
    /// in the restore path set both at once with `setFrame`, where no intermediate size exists at all.
    /// Re-assert the size bounds. They express the intent (fixed width, floored height) and stop most
    /// programmatic resizes, but they are **not** what enforces it — see `windowWillResize`.
    ///
    /// Re-applied rather than set once because `NSHostingController`, hosting a SwiftUI tree,
    /// overwrites *every* size bound — `contentMinSize`/`contentMaxSize` and the frame-level
    /// `minSize`/`maxSize` alike — during its first layout pass, some time after the window is shown,
    /// leaving `0×0` … `∞×∞`. Measured on this window, not assumed.
    private func pinSizeBounds() {
        guard let window else { return }
        window.contentMinSize = NSSize(width: Metrics.contentWidth, height: Metrics.minContentHeight)
        window.contentMaxSize = NSSize(width: Metrics.contentWidth, height: .greatestFiniteMagnitude)
    }

    private func applyRestoredOrDefaultFrame() {
        guard let window else { return }
        // What we persist is a *frame* (content plus title bar), while `Metrics` is stated in content
        // points, so convert the bounds into frame space before comparing. Mixing the two would let a
        // window be restored a title bar's worth shorter than `minContentHeight` allows.
        let decision = WindowFrameValidator.resolve(
            stored: PersistedConfig.settingsWindowFrame.map(WindowFrameBox.init(components:)),
            visibleFrames: NSScreen.screens.map { WindowFrameBox(cgRect: $0.visibleFrame) },
            defaultSize: frameSize(forContentHeight: Metrics.defaultContentHeight, of: window),
            minimumSize: frameSize(forContentHeight: Metrics.minContentHeight, of: window))

        switch decision {
        case .restore(let box):
            // A validated frame carries size *and* position, so one call and no sliver in between.
            window.setFrame(box.cgRect, display: false)
        case .centreDefault:
            // Size first, then position — `center()` on an unsized window is the off-screen bug.
            window.setContentSize(NSSize(width: Metrics.contentWidth,
                                         height: Metrics.defaultContentHeight))
            window.center()
        }
    }

    /// The full window size (content plus chrome) for a given **content** height at the pinned width —
    /// the unit the persisted frame is measured in.
    private func frameSize(forContentHeight height: CGFloat, of window: NSWindow)
        -> WindowFrameBox.Size {
        let frame = frameRect(forContentHeight: height, of: window)
        return .init(width: Double(frame.width), height: Double(frame.height))
    }

    /// Record the window's frame so the next launch can reopen at it. Cheap enough to do on every
    /// resize/move step: it is a four-number `UserDefaults` write.
    ///
    /// The `isVisible` gate drops the frames AppKit reports while the window is still being set up —
    /// before `makeKeyAndOrderFront` the window can still be the zero-sized sliver, and persisting
    /// that would hand the next launch a frame the validator has to throw away.
    private func persistFrame() {
        guard let window, window.isVisible else { return }
        PersistedConfig.settingsWindowFrame = WindowFrameBox(cgRect: window.frame).components
    }

    /// Reflect the current update state (#37). Safe to call while the window is closed — it mutates
    /// model state, which lives independent of any view (ADR-0042).
    func updateAvailability(_ release: GitHubRelease?) {
        model.updateAvailability(release)
    }

    /// Reflect why an available update is sitting unapplied (#221) — every currently-blocking
    /// environment gate, or `[]` when nothing blocks. Safe to call while the window is closed.
    func updateDeferral(_ reasons: [UpdateDeferralReason]) {
        model.updateDeferral(reasons)
    }

    /// Reflect the current archive state (#110). Safe to call while the window is closed.
    func updateArchiveStatus() {
        model.refreshArchiveStatus()
    }

    /// Reflect whether the last archive run refused for lack of free space (#306). Carries its
    /// payload, unlike ``updateArchiveStatus()`` — this state lives only in memory, so the model has
    /// nothing to pull it from. Safe to call while the window is closed.
    func updateArchiveBlock(_ verdict: ArchiveSpaceVerdict) {
        model.updateArchiveBlock(verdict)
    }

    /// Reflect the live data source after the dev-tools stub selector switches scenarios (#187), so the
    /// ⚠️ "Stubbed in this development build." hints appear/disappear without reopening the window.
    /// Safe to call while the window is closed.
    func updateStubState(active: Bool) {
        model.stubScenarioActive = active
    }
}

// MARK: - NSWindowDelegate (ADR-0069)

extension SettingsWindowController: NSWindowDelegate {

    /// Shape the green button's zoom: **taller, never wider**. The width is pinned, so AppKit's own
    /// proposal would only grow the height anyway — but it also re-origins x, sliding the window
    /// sideways on the way. Returning an explicit frame keeps the window where the user put it and
    /// only stretches it to the screen's usable height.
    ///
    /// `defaultFrame` is AppKit's proposal, already the target screen's visible frame (menu bar and
    /// Dock excluded), so its vertical extent is exactly what "as tall as the screen" means — no
    /// `NSScreen` lookup needed. Clicking again restores the previous size; `NSWindow.zoom(_:)`
    /// remembers it, so there is no toggle to implement here.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        NSRect(x: window.frame.origin.x,
               y: defaultFrame.origin.y,
               width: pinnedFrameWidth(of: window),
               height: defaultFrame.height)
    }

    /// Hold the width at 857 through every resize, and keep the height above its floor. **This is
    /// what actually enforces the pin** — AppKit asks here before every resize, whoever asked, so the
    /// answer is authoritative where the size bounds are not: `NSHostingController` wipes those
    /// during its first layout pass (see `pinSizeBounds()`), and AppKit applies them only to user
    /// drags anyway, letting anything programmatic (Accessibility, window managers) straight past.
    ///
    /// Known cosmetic flaw: the side edges still show the ↔ resize cursor, so the window offers a
    /// horizontal resize that this method then refuses. AppKit has no supported way to suppress that
    /// cursor for one axis — `resizeIncrements`, both size-bound pairs, and the style mask were each
    /// measured against it and none removes it, and Apple's own Settings window (which pins its width
    /// identically, verified via Accessibility) presumably uses something private. Tracked separately.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: pinnedFrameWidth(of: sender),
               height: max(frameSize.height, minimumFrameHeight(of: sender)))
    }

    /// The pinned width expressed as a *frame* width — `Metrics.contentWidth` plus whatever side
    /// chrome the window has (none, for a standard titled window, but derived rather than assumed).
    private func pinnedFrameWidth(of window: NSWindow) -> CGFloat {
        frameRect(forContentHeight: Metrics.defaultContentHeight, of: window).width
    }

    /// The height floor as a *frame* height — `Metrics.minContentHeight` plus the title bar.
    private func minimumFrameHeight(of window: NSWindow) -> CGFloat {
        frameRect(forContentHeight: Metrics.minContentHeight, of: window).height
    }

    private func frameRect(forContentHeight height: CGFloat, of window: NSWindow) -> NSRect {
        window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: Metrics.contentWidth, height: height))
    }

    /// SwiftUI's first layout pass wipes the size bounds; by the time the window takes key focus that
    /// pass has run, so this is where the pin reliably sticks. See `pinSizeBounds()`.
    func windowDidBecomeKey(_ notification: Notification) {
        pinSizeBounds()
        // No chevron re-tint here any more: the ‹ › are plain `NSToolbarItem`s now, so the toolbar
        // owns their buttons and dims them with the window itself (#312).
    }

    func windowDidResize(_ notification: Notification) { persistFrame() }

    func windowDidMove(_ notification: Notification) { persistFrame() }

    /// The state the window was in when it went away is the one to reopen at — a resize immediately
    /// followed by a close would otherwise be the one change that never got recorded.
    func windowWillClose(_ notification: Notification) { persistFrame() }
}

// MARK: - WindowFrameBox ↔ CoreGraphics

/// The kit's frame type is deliberately CoreGraphics-free (it has to stay portable to Phase 2), so the
/// conversion lives here, at the AppKit boundary.
extension WindowFrameBox {

    init(cgRect: CGRect) {
        self.init(x: Double(cgRect.origin.x), y: Double(cgRect.origin.y),
                  width: Double(cgRect.width), height: Double(cgRect.height))
    }

    /// Rebuild from the persisted `[x, y, width, height]`. The array's length is guaranteed by
    /// `PersistedConfig.settingsWindowFrame`, which rejects anything else.
    init(components: [Double]) {
        self.init(x: components[0], y: components[1], width: components[2], height: components[3])
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Flattened for storage — see `PersistedConfig.settingsWindowFrame` for why plain numbers.
    var components: [Double] { [x, y, width, height] }
}
