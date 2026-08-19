import AppKit
import ObjectiveC   // runtime class generation — see `claimDividerCursor`
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

    /// The window's pinned content width, readable from outside the controller.
    ///
    /// `Metrics` itself stays private — this is the one number anything else needs, and it needs it for
    /// one reason: the preview parks beside this window, so it has to know how much of the screen the
    /// pair will take (`SettingsPreviewWindowController.Metrics.pairWidth`). Exposed as a single
    /// constant rather than by opening the whole enum, so the rest of the geometry stays this type's
    /// own business.
    nonisolated static let pinnedContentWidth: CGFloat = 792

    private enum Metrics {
        /// Fixed window content width. Pinned min == max: only the **height** resizes (ADR-0069).
        ///
        /// **Was 857** — System Settings' own width, measured (#156), when the sidebar was 275. The
        /// sidebar has since been narrowed to 210 (`SidebarIconMetrics.sidebarWidth`), and this width
        /// tracks it exactly — 857 − (275 − 210) = 792 — so the **detail column keeps the width its
        /// panes were laid out against**. Giving the detail column the reclaimed space instead would
        /// reflow every pane; the split is tuned to this width, which is why it is not draggable.
        ///
        /// Change one of the two and the other must follow, or the detail column silently resizes.
        ///
        /// The number itself lives on ``SettingsWindowController/pinnedContentWidth``, which the
        /// preview reads to work out how wide the pair is; this alias keeps the rest of the file
        /// reading as `Metrics.contentWidth` while there is still only one copy of the value.
        static let contentWidth: CGFloat = SettingsWindowController.pinnedContentWidth
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
        /// (passed to it explicitly below, so the two cannot drift).
        ///
        /// **Was 480** — the app's first fixed window height, kept as the floor by ADR-0069 because it
        /// was already there, not because anything measured it, and taller than the system's own.
        ///
        /// 470 is System Settings' minimum, read off the window server (`CGWindowListCopyWindowInfo`)
        /// with that window dragged to its floor: **857 × 470**. The number is a *frame* height and is
        /// used here as a *content* height on purpose — both windows are `.fullSizeContentView`, so the
        /// title bar overlays the content instead of adding to it, and the two are the same measurement.
        /// (Deriving it from a screenshot first gave 443, because that subtracted a title bar which does
        /// not exist here; the live window measured 792 × 440 for a 440 content height, which is what
        /// proves the identity.)
        ///
        /// **Raised from 470 to 560 for the Legend page** (#261). Matching System Settings' own floor
        /// was right while every pane was a list of controls, which degrades gracefully: squeeze it and
        /// you scroll a row at a time. Legend is diagrams — a bar with captions pointing into it — and a
        /// window short enough to cut one in half turns the page from a reference into a puzzle. 560 is
        /// the height at which its tallest section (the two bar anatomies with their headings) is whole
        /// with the form's own padding, so a reader who drags the window down still meets complete
        /// figures. Every other pane keeps scrolling exactly as it did; the floor only stops them
        /// getting shorter than the one page that cannot take it.
        static let minContentHeight: CGFloat = 560
    }

    /// The single observable state object, alive for the controller's lifetime (so background
    /// callbacks always have somewhere to write — see the type doc).
    private let model = SettingsModel()

    /// The window's toolbar — ‹ › plus the pane name, System Settings' own header (#156 §2).
    private let toolbarController = SettingsToolbarController()

    /// The live dropdown preview riding beside this window (ADR-0083). Owned here, not by
    /// `AppDelegate`, because its lifetime is exactly this window's and its parking maths needs the
    /// move/resize callbacks this controller already receives.
    private let preview = SettingsPreviewWindowController()

    /// The hard width constraint pinning the sidebar column. Retained so repeated `pinSidebarSplit()`
    /// passes update the one constraint instead of stacking a new one on every window show.
    private var sidebarWidthConstraint: NSLayoutConstraint?

    /// Local mouse-down monitor over the sidebar column, so a click on the **already-selected** row can
    /// pop out of its child page (#374).
    ///
    /// SwiftUI cannot see that click. `List(selection:)` does not write the binding when the selection
    /// does not change, and — measured with a log line in the model — a `simultaneousGesture` on the row
    /// only ever fired for a row that was *not* already selected: once a row is current, the List
    /// consumes the event outright. A local monitor runs before the event reaches the view tree, so it
    /// sees every click regardless.
    private var sidebarClickMonitor: Any?

    /// Prefix for the runtime subclass that neutralises the sidebar divider (see `claimDividerCursor`).
    /// Also the marker that makes that pass idempotent.
    private static let fixedDividerClassPrefix = "TokenPaceFixedDivider_"

    /// The detail column's live scroll view and split item, plus the bounds observation driving the
    /// titlebar separator over that column (see `driveDetailTitlebarSeparator()`). Weak: both belong
    /// to the SwiftUI tree and are replaced wholesale on a pane switch.
    private weak var separatorScroll: NSScrollView?
    private weak var separatorItem: NSSplitViewItem?
    private var separatorObserver: NSObjectProtocol?


    // MARK: Public callbacks (the AppDelegate contract — forwarded into the model, unchanged surface)

    /// The shared colour animator, handed down so the preview's transitions stay in lockstep with the
    /// live surfaces instead of running their own timer (ADR-0070).
    var previewColorAnimator: ColorAnimator? {
        get { preview.colorAnimator } set { preview.colorAnimator = newValue }
    }

    /// Feed the preview the layout the live dropdown just received. Mirrors
    /// `DevToolsWindowController.updatePreview` — both are called from `AppDelegate.setPopupLayout`.
    func updatePreview(_ layout: PopupLayout) { preview.update(layout) }

    /// Called when the user changes what is monitored for a provider (#89, #341) — either the usage
    /// poll or the status-page services — with the new composite config.
    var onProviderMonitoringChange: ((ProviderMonitoring) -> Void)? {
        get { model.onProviderMonitoringChange } set { model.onProviderMonitoringChange = newValue }
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

    /// Called when the user changes the calm-colours mode (#105, #224), with the new `ColorAdvice`.
    var onColorAdviceChange: ((ColorAdvice) -> Void)? {
        get { model.onColorAdviceChange } set { model.onColorAdviceChange = newValue }
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

    /// Called when the user toggles "Show service status dot on issues" (#31), with the new state.
    var onServiceDotChange: ((Bool) -> Void)? {
        get { model.onServiceDotChange } set { model.onServiceDotChange = newValue }
    }

    /// Called when the user changes when "Show model & service limits" appears (#211), with the new mode.
    var onModelLimitsVisibilityChange: ((PopupSectionVisibility) -> Void)? {
        get { model.onModelLimitsVisibilityChange } set { model.onModelLimitsVisibilityChange = newValue }
    }

    /// Called when the user changes when the dropdown's "Extra usage" section appears, with the new mode.
    var onExtraUsageVisibilityChange: ((PopupSectionVisibility) -> Void)? {
        get { model.onExtraUsageVisibilityChange } set { model.onExtraUsageVisibilityChange = newValue }
    }

    /// Called when the user picks a "Hide the calm bar" segment (ADR-0086), with the new mode.
    var onTopBarHidingChange: ((TopBarHiding) -> Void)? {
        get { model.onTopBarHidingChange } set { model.onTopBarHidingChange = newValue }
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
        // **An ordinary window level, not `.floating`.** ADR-0012 §6 floated it so a menu-bar app's
        // Settings could be found again after clicking away — but the cost is that it then sits over
        // *everything*, including the editor or terminal the reader is comparing it against, and it
        // cannot be pushed behind them. A Settings window is somewhere you go, not something you
        // consult while working in another app; the widget's own menu reopens it in one click.
        //
        // The preview is unaffected: it is a **child** window, so it follows this one's ordering
        // whatever level that is.
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        // Zoom means "as tall as the screen" here, not "as large as the screen" — see
        // `windowWillUseStandardFrame`. Full screen stays refused: the window is a fixed-width form
        // with a companion parked beside it, and neither survives being blown up to a Space of its own.
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
        // And don't hand SwiftUI the window-chrome safe area either. The bridged
        // `NavigationSplitView` mis-propagates it (rdar://122947424, confirmed by an Apple Frameworks
        // Engineer): with the toolbar's 52 pt visible to SwiftUI, the split's platform view laid
        // itself out 26 pt taller than this view at every window height — measured directly on
        // `PlatformViewHost`, 496 pt in a 470 pt window — so every pane's tail and the scroller's
        // bottom end hung below the window edge, unreachable (#346). With the safe area cut off at
        // the hosting boundary the split sizes itself to the window exactly, and nothing is lost:
        // the columns' scroll views keep their 52 pt toolbar inset (measured after the change — the
        // bridge derives it from the window, not from this safe area), so content still rests below
        // the toolbar and scrolls under it.
        hosting.safeAreaRegions = []
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
    /// Pin the sidebar column width in AppKit, and make its divider inert.
    ///
    /// SwiftUI cannot do either job on this window. `.navigationSplitViewColumnWidth` is unreliable for
    /// a `.sidebar` List, and `.frame(width:)` does not scale the column at all — measured live, it
    /// snaps between a handful of fixed states (frame 200 → 307 pt, 240 → 243, 340 → 243: a *wider*
    /// frame giving a *narrower* column, see `SidebarIconMetrics`).
    ///
    /// The lever is the **`NSSplitViewItem`**, not the split view. Setting `NSSplitView.delegate` throws
    /// outright here — *"A SplitView managed by a SplitViewController cannot have its delegate
    /// modified"* — because SwiftUI drives the split through an `NSSplitViewController` that owns the
    /// delegate slot. The item exposes the same constraints as properties, which the controller honours:
    /// `canCollapse` off, and holding/minimum/maximum thickness collapsed onto one value so there is
    /// nothing for a drag to move.
    ///
    /// Without this the divider stays live: the sidebar does not visibly resize (the List holds its own
    /// width), but the seam moves and the detail column reflows under the cursor — a drag the window
    /// advertises and then refuses, the same complaint as the ↔ cursor on its side edges (#263).
    private func pinSidebarSplit() {
        guard let window else { return }
        let width = model.sidebarIcons.sidebarWidth
        // Walk the **view** tree, not the controller tree: SwiftUI's split lives inside the hosting
        // controller's views and is not exposed as a child view controller.
        func pin(_ view: NSView) {
            if let split = view as? NSSplitView, let sidebar = split.arrangedSubviews.first {
                // A hard width constraint on the sidebar view itself, held across rebuilds.
                //
                // Everything gentler was tried and measured on this window: `NSSplitViewItem`'s
                // min/max/canCollapse are re-applied by SwiftUI after our pass (the divider stayed
                // draggable and the sidebar could still be collapsed to nothing), and
                // `NSSplitView.delegate` throws outright — *"A SplitView managed by a
                // SplitViewController cannot have its delegate modified"*. A constraint outranks the
                // split's own layout, so the drag has nothing left to move.
                if let existing = self.sidebarWidthConstraint, existing.firstItem === sidebar {
                    existing.constant = width
                } else {
                    self.sidebarWidthConstraint?.isActive = false
                    let constraint = sidebar.widthAnchor.constraint(equalToConstant: width)
                    constraint.priority = .required
                    constraint.isActive = true
                    self.sidebarWidthConstraint = constraint
                }
                // Belt and braces: keep the item's own bounds in step, so AppKit does not fight the
                // constraint during a window resize.
                if let controller = self.splitController(for: split),
                   let item = controller.splitViewItems.first {
                    item.canCollapse = false
                    item.minimumThickness = width
                    item.maximumThickness = width
                }
                self.claimDividerCursor(on: split)
                self.watchSidebarClicks(in: sidebar)
                return
            }
            view.subviews.forEach(pin)
        }
        if let themeFrame = window.contentView?.superview { pin(themeFrame) }
    }

    /// Notice a click on the sidebar row that is **already** selected, and pop out of its child page.
    ///
    /// The whole reason this lives in AppKit: a click that does not change the selection never reaches
    /// SwiftUI's row. `List(selection:)` skips the binding write, and a `simultaneousGesture` on the row
    /// is not delivered either — instrumented with a log line in `SettingsModel.selectFromSidebar`, it
    /// fired exactly once, on the first click that *entered* the section, and never again for the row
    /// that was current. A local monitor runs ahead of the view tree, so it sees the click either way.
    ///
    /// The event is passed through untouched (`return event`), so ordinary selection keeps working; this
    /// only adds a side effect. Cheap to be wrong about: `popToRoot()` no-ops when no child page is
    /// open, so a click anywhere else in the column does nothing.
    ///
    /// The pop is deferred one runloop turn so it lands after the List has finished with the same
    /// event, whose own handling would otherwise re-enter the section on top of it.
    private func watchSidebarClicks(in sidebar: NSView) {
        guard sidebarClickMonitor == nil else { return }
        sidebarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak sidebar] event in
            guard let self, let sidebar, event.window === sidebar.window else { return event }
            let point = sidebar.convert(event.locationInWindow, from: nil)
            guard sidebar.bounds.contains(point) else { return event }
            // **Not the titlebar band.** The sidebar column runs to the very top of the window — its
            // strip is merged into the titlebar (`mergeSidebarTitlebarStrip`), which is what makes the
            // sidebar material continue behind the traffic lights. So the close button sits
            // geometrically *inside* this view, and without this guard closing the window counted as a
            // sidebar click: the deferred pop then ran, and the child page the user was reading was
            // gone when they opened Settings again. Found by logging every `childPage` write — the
            // reset arrived with `selection` unchanged, which ruled the binding out and left this.
            //
            // Measured against the window's own content-layout guide rather than a constant, so it
            // holds at whatever height AppKit gives the bar.
            if let window = sidebar.window {
                let titlebarHeight = window.frame.height - window.contentLayoutRect.height
                let inTitlebar = sidebar.isFlipped
                    ? point.y < titlebarHeight
                    : point.y > sidebar.bounds.height - titlebarHeight
                guard !inTitlebar else { return event }
            }
            // Captured now, checked later: the page that was open when the click landed.
            let openPage = MainActor.assumeIsolated { self.model.childPage }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.model.popFromSidebarClick(openAt: openPage) }
            }
            return event
        }
    }

    /// Stop the divider advertising a drag the pinned sidebar will refuse.
    ///
    /// **The mechanism, established by instrumenting AppKit rather than by guesswork:**
    /// `-[NSSplitView resetCursorRects]` installs a `resizeLeftRight` **cursor rect** — measured at
    /// `(sidebarWidth, 0, 5, height)`, a 5 pt band around the 1 pt divider. It derives that rect from
    /// the divider's *effective rect*, which the split view asks its delegate for via
    /// `splitView:effectiveRect:forDrawnRect:ofDividerAtIndex:`. Return `.zero` there and no cursor
    /// rect is added at all (verified: zero `addCursorRect` calls), taking the drag zone with it.
    ///
    /// This is why every lighter attempt failed. Cursor rects are geometry registered **with the
    /// window**; they do not consult `hitTest` and have no z-order, so an overlay on top cannot win one,
    /// and `cursorUpdate` never fires for a view that does not own the rect. `NSSplitViewItem`'s
    /// thickness limits constrain the *outcome* of a drag, never the divider's zone.
    ///
    /// The delegate is SwiftUI's own `NavigationSplitViewController` — a real `NSSplitViewController`
    /// subclass. It cannot be *replaced* (assigning throws *"A SplitView managed by a SplitViewController
    /// cannot have its delegate modified"*), but its method can be overridden by moving that one
    /// instance into a runtime-generated subclass. That is what this does.
    ///
    /// Deliberately an **isa-swizzle of a single instance**, not a method swizzle on `NSSplitView`:
    /// nothing outside this window is touched. Note the split view itself is already
    /// `NSKVONotifying_NSSplitView` — isa-swizzling *that* would break its KVO, so the controller is the
    /// right target. The private class name is never hard-coded (the class is read back from the live
    /// delegate), so if a future macOS renames it this degrades to the old cosmetic wart rather than
    /// breaking.
    private func claimDividerCursor(on split: NSSplitView) {
        guard let delegate = split.delegate as? NSSplitViewController else { return }
        let baseClass: AnyClass = object_getClass(delegate)!
        let baseName = NSStringFromClass(baseClass)
        guard !baseName.hasPrefix(Self.fixedDividerClassPrefix) else { return }   // already swizzled

        let subclassName = Self.fixedDividerClassPrefix + baseName
        let subclass: AnyClass
        if let existing = NSClassFromString(subclassName) {
            subclass = existing
        } else {
            let selector = NSSelectorFromString("splitView:effectiveRect:forDrawnRect:ofDividerAtIndex:")
            guard let allocated = objc_allocateClassPair(baseClass, subclassName, 0),
                  let method = class_getInstanceMethod(baseClass, selector) else { return }
            let override: @convention(block) (AnyObject, NSSplitView, NSRect, NSRect, Int) -> NSRect =
                { _, _, _, _, _ in .zero }
            class_addMethod(allocated, selector, imp_implementationWithBlock(override),
                            method_getTypeEncoding(method))
            objc_registerClassPair(allocated)
            subclass = allocated
        }
        object_setClass(delegate, subclass)
        // Cursor rects are cached per window; without this the old resize rect survives until some
        // unrelated event invalidates them.
        window?.invalidateCursorRects(for: split)
    }

    /// The `NSSplitViewController` driving `split`, if there is one. Found through the responder chain
    /// because SwiftUI does not expose it as a child of the window's content controller.
    private func splitController(for split: NSSplitView) -> NSSplitViewController? {
        var responder: NSResponder? = split.nextResponder
        while let current = responder {
            if let controller = current as? NSSplitViewController, controller.splitView === split {
                return controller
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// Drive the titlebar separator over the detail column by hand (#346).
    ///
    /// System behaviour: no line while the pane rests at its top, a hairline the moment content
    /// scrolls under the toolbar. AppKit's `.automatic` style cannot deliver it here — its tracking
    /// never binds to the SwiftUI-bridged scroll view, whether the bridge's manual insets are left
    /// alone or `automaticallyAdjustsContentInsets` is forced back on (both measured: the line just
    /// stays on). So the one thing the automatic mode would do is done explicitly: watch the clip
    /// view's origin and flip the detail `NSSplitViewItem` between `.none` and `.line`.
    ///
    /// Re-hooked on every pane change (a switch rebuilds the scroll view) — from `show()` and the
    /// toolbar-state observer, the same discipline as `pinSidebarSplit()`.
    private func driveDetailTitlebarSeparator() {
        guard let window, let themeFrame = window.contentView?.superview else { return }
        let sidebarWidth = model.sidebarIcons.sidebarWidth
        var detailScroll: NSScrollView?
        var splitView: NSSplitView?
        func walk(_ v: NSView) {
            if let split = v as? NSSplitView { splitView = split }
            if let scroll = v as? NSScrollView, scroll.frame.width > sidebarWidth {
                detailScroll = scroll
                return
            }
            v.subviews.forEach(walk)
        }
        walk(themeFrame)
        guard let scroll = detailScroll, let split = splitView,
              let controller = splitController(for: split),
              let item = controller.splitViewItems.last else { return }

        separatorScroll = scroll
        separatorItem = item
        if let separatorObserver { NotificationCenter.default.removeObserver(separatorObserver) }
        scroll.contentView.postsBoundsChangedNotifications = true
        separatorObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDetailSeparator() }
        }
        applyDetailSeparator()
    }

    /// The separator rule itself: at rest (content top sitting exactly at its inset) — no line;
    /// anything past it — the system hairline.
    private func applyDetailSeparator() {
        guard let scroll = separatorScroll, let item = separatorItem else { return }
        let atRest = scroll.contentView.bounds.origin.y <= -scroll.contentInsets.top + 0.5
        let style: NSTitlebarSeparatorStyle = atRest ? .none : .line
        if item.titlebarSeparatorStyle != style { item.titlebarSeparatorStyle = style }
    }

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
    /// model default), a reused one keeps its last-viewed page. The `TOKENPACE_SETTINGS_SECTION` dev
    /// hook is applied *after* this, so it still wins during verification — and unlike the `section:`
    /// argument it *seeds* the history rather than navigating (`openAtLaunch`), so a window opened
    /// straight onto a page has both chevrons dim, as a freshly opened window should.
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
        // Dev helper: `TOKENPACE_SETTINGS_SECTION=<index>` opens straight to a given pane — see
        // `SettingsSection` for the mapping (the raw values are stable identifiers, not row order).
        //
        // Since #341 the value may also carry a child page after a dot: `7.0` is Providers › its
        // first child. The dotted form indexes the section's children **in display order** rather
        // than by their raw value, so a recipe reads as "the first page under Providers" and does not
        // have to know `SettingsChildPage`'s numbering.
        if let raw = ProcessInfo.processInfo.environment["TOKENPACE_SETTINGS_SECTION"] {
            openAtLaunchFromHook(raw)
        }
        observeToolbarState()
        // After the tree is on screen: the strip does not exist until SwiftUI has laid the split view
        // out, and a reopened window may have rebuilt it. Once more on the next turn of the run loop,
        // because the first pass can land before the columns have their final width.
        mergeSidebarTitlebarStrip()
        pinSidebarSplit()
        driveDetailTitlebarSeparator()
        DispatchQueue.main.async { [weak self] in
            self?.mergeSidebarTitlebarStrip()
            self?.pinSidebarSplit()
            self?.driveDetailTitlebarSeparator()
        }
        // Last: the preview parks against the parent's *final* frame, and everything above can still
        // move it (restore, centre, the section hook). Attaching earlier would align it to the
        // zero-width sliver an unsized hosting window starts as.
        if let window { preview.attach(to: window) }
    }

    /// Seat the window from the `TOKENPACE_SETTINGS_SECTION` dev hook (#341).
    ///
    /// Accepts `<section>` or `<section>.<childIndex>`; the child index counts the section's pages in
    /// display order. Seating (rather than navigating) is what keeps **both** toolbar chevrons dimmed:
    /// the page is where the window opened, not somewhere the user went.
    ///
    /// An unrecognised value **logs** rather than silently doing nothing. A hook that no-ops looks
    /// exactly like a hook that worked and landed on the default pane, which is how a stale recipe
    /// survives unnoticed — and #341 retired one index (`4`), so stale recipes exist.
    private func openAtLaunchFromHook(_ raw: String) {
        let parts = raw.split(separator: ".", maxSplits: 1)
        guard let sectionRaw = parts.first.flatMap({ Int($0) }),
              let section = SettingsSection(rawValue: sectionRaw) else {
            AppLogger.lifecycle.notice(
                "settings hook: unknown section \(raw, privacy: .public) — ignored")
            return
        }
        guard parts.count == 2 else {
            model.openAtLaunch(section)
            return
        }
        let pages = SettingsChildPage.pages(of: section)
        guard let childIndex = Int(parts[1]), pages.indices.contains(childIndex) else {
            AppLogger.lifecycle.notice(
                "settings hook: unknown child \(raw, privacy: .public) — opening the section")
            model.openAtLaunch(section)
            return
        }
        model.openAtLaunch(pages[childIndex])
    }

    /// Keep the toolbar's title and ‹ › enablement — and the preview's visibility — in step with the
    /// model.
    ///
    /// `withObservationTracking` fires once per change, so the continuation re-arms itself: the
    /// selection moves whenever the user picks a sidebar row, which is SwiftUI's write, not ours —
    /// there is no single call site to hook instead.
    ///
    /// The preview rides here rather than on its own observer because it answers the same question
    /// this one already reads: *where is the window*. Both the section and the drilled-into page reach
    /// it through `model.selection`, so a section change and a drill-in are one notification.
    private func observeToolbarState() {
        withObservationTracking {
            toolbarController.update(title: model.currentPaneTitle,
                                     canGoBack: model.canGoBack,
                                     canGoForward: model.canGoForward)
            preview.isEnabledForCurrentPane = model.selection.showsDropdownPreview
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeToolbarState()
                // A pane change rebuilt the detail column's scroll view; re-bind the separator
                // driver to the new one (#346). One turn later, so SwiftUI has actually swapped the
                // view by the time the walk runs.
                DispatchQueue.main.async { self?.driveDetailTitlebarSeparator() }
            }
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
            centreWithPreview(window)
        }
    }

    /// Centre the window **and its preview as one unit**, so the pair sits centred rather than the
    /// Settings window alone with the preview hanging off to the right.
    ///
    /// `NSWindow.center()` knows only about this window, so with the preview attached the visual centre
    /// of what the user sees lands well right of the screen's. Shifting left by half the preview's
    /// footprint puts the pair's midpoint where `center()` would have put this window's.
    ///
    /// Falls back to plain `center()` when the shift would push the window off the left edge — a
    /// half-visible Settings window is a worse outcome than an off-centre pair.
    private func centreWithPreview(_ window: NSWindow) {
        window.center()
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let shifted = window.frame.origin.x - preview.occupiedWidth / 2
        guard shifted >= visible.minX else { return }
        window.setFrameOrigin(NSPoint(x: shifted, y: window.frame.origin.y))
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

    /// A child window follows its parent when *dragged*, but a resize moves only the bottom edge —
    /// the preview aligns to the **top**, so it has to re-park itself explicitly.
    func windowDidResize(_ notification: Notification) {
        persistFrame()
        preview.reposition()
    }

    func windowDidMove(_ notification: Notification) {
        keepPreviewRoomOnTheRight()
        persistFrame()
        preview.reposition()
    }

    /// Stop the window being dragged so far right that the preview has nowhere to sit.
    ///
    /// The preview lives to the **right**, always — a window that jumped sides mid-session made the
    /// reader hunt for it, and one that overlapped Settings hid the very controls it was previewing.
    /// Keeping the side fixed means the constraint has to go on the parent instead: it may not cross
    /// the point where the pair stops fitting on screen.
    ///
    /// Only while the preview is actually showing (`Appearance` and its pages, ADR-0083). Everywhere
    /// else the window is the user's to put where they like, and clamping it there would take space
    /// away for a companion that is not on screen.
    ///
    /// Nudged rather than refused: AppKit has no "you may not move there" for a user drag, so the frame
    /// is corrected after the fact. In practice the window slides along the invisible wall, which is
    /// what a maximum position should feel like.
    private func keepPreviewRoomOnTheRight() {
        guard preview.isEnabledForCurrentPane, let window,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let maxX = visible.maxX - SettingsPreviewWindowController.roomNeededOnTheRight
        guard window.frame.maxX > maxX else { return }
        window.setFrameOrigin(NSPoint(x: maxX - window.frame.width, y: window.frame.origin.y))
    }

    /// The state the window was in when it went away is the one to reopen at — a resize immediately
    /// followed by a close would otherwise be the one change that never got recorded.
    func windowWillClose(_ notification: Notification) {
        persistFrame()
        preview.detach()
    }

    /// A miniaturised window must not leave the preview floating on screen — and, whatever AppKit does
    /// with the child window itself, it will not remove the preview's ⌥ event monitor. `detach`/`attach`
    /// are idempotent, so this is safe even if the child is already hidden for us.
    func windowDidMiniaturize(_ notification: Notification) { preview.detach() }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let window { preview.attach(to: window) }
    }
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

