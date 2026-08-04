import AppKit
import TokenPaceKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu-bar item. Held strongly for the process lifetime — releasing it removes the item.
    private var statusItem: NSStatusItem?

    /// The custom view that renders the menu-bar image. Held so the image can be re-rendered when the
    /// data changes. The image is a single non-template `NSImage` (semantic colours resolved in the
    /// button's appearance); the KVO below re-snapshots it on a theme flip.
    private var statusView: StatusItemView?

    /// KVO on the button's `effectiveAppearance`. The menu-bar image is **non-template**, so it does not
    /// re-resolve its semantic colours on a theme flip by itself — this re-snapshots it when the bar
    /// flips light/dark. This is the standard technique for a custom-drawn menu-bar widget (Stats/iStat).
    private var appearanceObservation: NSKeyValueObservation?

    /// The detail popup's content controller (issue #11). Hosted inside a menu item so the popup
    /// gets the native menu-bar look — a rounded panel with **no arrow**, and the status button is
    /// highlighted while it is open (both come free with `NSMenu`, unlike `NSPopover`).
    private let popupVC = PopupViewController()

    /// The "Settings…" window (#14), created lazily on first use and kept alive so a
    /// second click focuses the existing window rather than opening a duplicate (single-instance).
    private var settingsWC: SettingsWindowController?

    /// The "Insights" window (#242, ADR-0067) — the separate data-visualisation surface reached from
    /// the first menu item. Lazily created and kept alive (single-instance), like `settingsWC`.
    private var insightsWC: InsightsWindowController?

    /// The hidden Troubleshoot window (ADR-0020), reached via ⌥ Option on "Settings…". Lazily
    /// created and kept alive; while open it re-renders on every poll (see `apply(_:)`).
    private var troubleshootWC: TroubleshootWindowController?

    /// The optional "Troubleshoot…" item (ADR-0020), hidden by default and revealed **below** the
    /// always-visible "Settings…" while ⌥ Option is held. `NSMenuItem.isHidden` is flipped live by
    /// `updateTroubleshootVisibility(_:)`, driven by `optionPollTimer` — the native `isAlternate`
    /// swap does not work in a status-item menu. "Settings…" is a plain, always-shown item beside it.
    private var troubleshootItem: NSMenuItem?

    /// The dev-only colour tuner window (#185). Lazily created and kept alive.
    private var devToolsWC: DevToolsWindowController?

    /// The optional "Development tools…" item (#185), shown just below "Troubleshoot…" but **only**
    /// when the `devToolsEnabled` defaults key is set (`ColorStore.devToolsEnabled`) **and** ⌥ Option is held — so it
    /// stays invisible on a normal run regardless of build type. Visibility is flipped alongside
    /// `troubleshootItem` in `updateTroubleshootVisibility(_:)`.
    private var devToolsItem: NSMenuItem?

    /// The "Quit TokenPace" item. Its title carries a build/stub tag — "(dev build)", "(dev build – error)",
    /// or "(stub – error)" — but **only** while ⌥ Option is held; the plain "Quit TokenPace" shows otherwise.
    /// Held so `updateTroubleshootVisibility` can swap the two in lockstep with the other ⌥-driven items.
    /// The tag appears whenever this is a dev build **or** a stub is active — including a **signed `.app`**
    /// running a stub (a real notification build must be an `.app`); a plain `.app` on the real network has
    /// no tag and stays "Quit TokenPace" regardless of Option.
    private var quitItem: NSMenuItem?

    /// The tag title shown on `quitItem` while ⌥ Option is held, or nil when there is none (a plain `.app`
    /// on the real network). Computed by ``updateQuitDevTitle()`` at menu-build time and re-computed on
    /// every live stub switch (#187), so the ⌥ swap is a cheap string assignment that always names the
    /// stub actually running.
    private var quitDevTitle: String?


    /// Polls the ⌥ Option state while the dropdown is open, showing/hiding `troubleshootItem` when it
    /// changes (ADR-0020). A timer — not an event monitor — because NSMenu tracking runs a modal
    /// `NSEventTrackingRunLoopMode` that starves `addLocalMonitorForEvents(.flagsChanged)` (verified:
    /// the monitor never fired mid-tracking), while `isAlternate` is inert in a status-item menu. The
    /// timer is scheduled in `.common` modes so it *does* fire during tracking, reading the live
    /// `NSEvent.modifierFlags`. Live only between `menuWillOpen` and `menuDidClose`.
    private var optionPollTimer: Timer?
    /// The last ⌥ state pushed to the menu, so the poll only re-toggles the item on a real change.
    private var lastOptionHeld = false

    // MARK: live polling (#13)

    /// Fan-in of sleep/wake (`NSWorkspace`) and network (`NWPathMonitor`) signals into the loop.
    private let signals = SignalHub()
    /// System sleep/wake observers, feeding `.sleep`/`.wake` into `signals`.
    private var sleepWake: WorkspaceSleepWake?
    /// Screen lock / screensaver / display-sleep observers, feeding `.sleep`/`.wake` into `signals`
    /// when `PersistedConfig.pausePollingWhenScreenLocked` is on (#114).
    private var screenLock: ScreenLockObserver?
    /// Connectivity monitor, feeding `.networkRestored` into `signals`.
    private let network = NetworkMonitor()
    /// The running poll loop's consumer task — cancelled on terminate.
    private var pollTask: Task<Void, Never>?

    /// The most recent poll result, retained so the popup's "Last update …" line can be re-aged
    /// between polls (the data is unchanged; only `now` advances).
    private var lastOutput: PollOutput?

    // MARK: Awaiting-input indicator (#233, ADR-0066)

    /// Watches `~/.claude/sessions` + `jobs` for sessions awaiting user input, or `nil` while the
    /// feature is off. Created/destroyed by ``updateAwaitingInputWatcher()``.
    private var awaitingInputWatcher: AwaitingInputWatcher?
    /// The latest awaiting-input result from the watcher (count, urgency, per-project). Read by
    /// ``awaitingInputForDisplay`` at render time.
    private var awaitingInput: AwaitingSessions = .none
    /// Verification stub: `TOKENPACE_AWAITING=N` synthesizes `N` awaiting sessions, bypassing the
    /// watcher. `TOKENPACE_AWAITING_DAYS=d1,d2,…` sets each session's days-until-deletion (to drive the
    /// urgency tint / red/orange buckets); missing days default to 20 (neutral). `TOKENPACE_AWAITING_
    /// PROJECTS=a,b,…` names the sessions' projects (round-robin) for the per-project popover. See
    /// docs/guides/ui-verification.md. Verification only — no such env var in a real build.
    private let awaitingInputStub: AwaitingSessions? = {
        let env = ProcessInfo.processInfo.environment
        guard let n = env["TOKENPACE_AWAITING"].flatMap(Int.init), n >= 0 else { return nil }
        let days = (env["TOKENPACE_AWAITING_DAYS"] ?? "").split(separator: ",").compactMap { Double($0) }
        let projects = (env["TOKENPACE_AWAITING_PROJECTS"] ?? "app").split(separator: ",").map(String.init)
        let sessions = (0..<n).map { i in
            AwaitingSession(
                project: projects.isEmpty ? "app" : projects[i % projects.count],
                daysUntilDeletion: i < days.count ? days[i] : 20)
        }
        return AwaitingSessions(sessions)
    }()

    /// The awaiting-input result to render, or `nil` to hide the indicator. `nil` unless the feature is
    /// enabled **and** at least one session is waiting.
    ///
    /// The `TOKENPACE_AWAITING` stub forces the result **and** treats the feature as enabled, so the
    /// indicator can be verified with a plain `swift run` without toggling settings or running live
    /// Claude sessions (verification-only; a real build has no such env var). See ui-verification.md.
    private var awaitingInputForDisplay: AwaitingSessions? {
        if let stub = awaitingInputStub { return stub.count >= 1 ? stub : nil }
        guard PersistedConfig.awaitingInputEnabled else { return nil }
        return awaitingInput.count >= 1 ? awaitingInput : nil
    }

    // MARK: Claude service status (#31)

    /// The transport used for status polls — the same seam as the usage transport (real
    /// `URLSession.shared`, or the stub under `TOKENPACE_STUB=1`). Set in `startPolling`.
    private var statusTransport: UsageTransport = URLSession.shared
    /// The latest mapped service status, or `nil` until the first status poll lands (cold start →
    /// no status lines in the popup).
    private var lastStatusHealth: StatusHealth?
    /// Instant of the last **successful** status poll, driving `StatusCadence.isDue`. A failed poll
    /// does not advance it, so the next usage tick retries.
    private var lastStatusSuccess: Date?
    /// The in-flight status fetch, if any — held so a new tick can cancel a slow one rather than
    /// overlap (the status loop hangs off the usage poll's heartbeat, it owns no timer).
    private var statusTask: Task<Void, Never>?

    // MARK: update check (#37)

    /// The single update menu item (#130), sitting just above Quit behind its own separator. Hidden
    /// unless `UpdateMenuState` says otherwise; its colour/label/visibility are set by
    /// `refreshUpdateMenuItem`.
    private var updateAvailableItem: NSMenuItem?
    /// The separator above ``updateAvailableItem``, hidden/shown in lockstep with it so an absent
    /// update leaves no dangling rule above Quit.
    private var updateSeparatorItem: NSMenuItem?
    /// The update item state last applied by `refreshUpdateMenuItem` (#130), read by `openReleasesPage`
    /// to know whether opening it should clear the pending "what's new".
    private var currentUpdateItem: UpdateMenuState.Item = .hidden
    /// Whether the last auto-install verdict was a `defer…` (battery / metered / low disk) — drives the
    /// blue "Update pending" item (#130). Set in `evaluateAutoInstall`, read by `refreshUpdateMenuItem`.
    private var installDeferred = false
    /// The newest release found so far, or `nil` if none/up-to-date. Drives the update menu item state
    /// and the Settings "Update available" line.
    private var lastKnownRelease: GitHubRelease?
    /// The in-flight update fetch, if any — cancelled before a new check and on terminate.
    private var updateTask: Task<Void, Never>?
    /// The in-flight auto-install (dry-run in Phase 2, #123), if any — cancelled before a new one and
    /// on terminate.
    private var installTask: Task<Void, Never>?
    /// The in-flight archive sync, if any (#110) — cancelled before a new sync and on terminate.
    private var archiveTask: Task<Void, Never>?
    /// The usage-journal writer (#242). An `actor`, so appends are dispatched to it off the main
    /// actor; it never blocks a poll and swallows any write error. Only writes on the live
    /// `.realNetwork` scenario and when the journal is enabled — both gates are checked at the seam.
    private let usageJournal = UsageJournal()
    /// The result of the last archive sync, retained so the Settings status line can show
    /// "Last archived: … · N files" between runs (#110). `nil` until the first sync completes.
    private(set) var lastArchiveSummary: LogArchiver.Summary?
    /// Whether the `gh` path is enabled, resolved once (lazily) from `TOKENPACE_GH_AUTH`. Checked in
    /// `ProcessInfo` first (terminal / `launchctl setenv` launches), then — since a login-launched app
    /// sees no shell env — from the login shell's `~/.zshrc`/`~/.zprofile` via `ShellEnvironment`. The
    /// shell probe is memoised so it runs at most once, not on every heartbeat.
    private lazy var ghAuthEnabled: Bool = Self.resolveGHAuth()

    /// Which logical services to monitor on the status page (#89) — loaded from `PersistedConfig`
    /// on launch, updated live when the user changes it in Settings (`monitoredServicesChanged`).
    /// `Claude API` is always monitored regardless of this; the two toggleable services and the
    /// WEB/Desktop mode come from here. Seeded to `.default` until `applicationDidFinishLaunching`
    /// reads the stored value.
    private var monitoredServices: MonitoredServices = .default

    /// Re-renders the popup/menu bar from `lastOutput` on a fixed cadence so the "Last update" age
    /// grows ("just now" → "1m ago") without waiting for the next 180 s poll. **Never** fetches — it
    /// only recomputes the view models against the current time.
    private var ageTimer: Timer?

    /// One-shot timer firing exactly at the nearest window `resets_at` to apply a local optimistic
    /// reset + force a refresh (#36), so the menu bar rolls straight from a live countdown to a fresh
    /// window without ever showing the stale ⏰. Rescheduled on every `apply(_:)` against the latest
    /// `resets_at`, invalidated on sleep, and recomputed on wake so a long sleep never fires a stale
    /// in-the-past reset. Unlike `ageTimer` this is non-repeating and fires at a variable instant.
    private var resetTimer: Timer?

    /// The `TOKENPACE_STUB` scenario the app launched with, or `.realNetwork` for a normal run. Read
    /// once from the environment and mapped through the shared ``StubScenario`` registry (unknown /
    /// absent value → `.realNetwork`). Seeds ``currentScenario`` and the dropdown's initial selection.
    private static let launchScenario =
        StubScenario(rawValue: ProcessInfo.processInfo.environment["TOKENPACE_STUB"] ?? "") ?? .realNetwork

    /// The scenario currently driving the data source. Starts at ``launchScenario`` and changes only
    /// via the dev-tools live selector (#187), which tears down and rebuilds the polling engine. Read
    /// by the Quit dev-build tag and the dropdown preselection so both agree on what's live.
    private var currentScenario: StubScenario = AppDelegate.launchScenario

    /// The clock the **visible** render reads. Normally the wall clock, but a date-decoupled stub
    /// (`StubScenario.stubClock`) pins it to a fixed instant so a stubbed frame is reproducible and,
    /// crucially, agrees with the stub transport's `resets_at` (both are built from this same clock).
    /// Only the visible path (layouts, reset countdowns, optimistic-reset overlay) uses this — service
    /// cadence (status/update/archive polls, quiet-hours) stays on the real `Date()`.
    private func currentDate() -> Date { currentScenario.stubClock ?? Date() }

    /// A forced update menu-item state from `TOKENPACE_UPDATE_STATE` (#130), or `nil` for the real,
    /// version-derived state. Lets a maintainer verify each of the four dropdown states on a dev build
    /// without a real newer release or a failed install — `failed` (red), `available` (blue, auto off),
    /// `pending` (blue, deferred), `whatsnew` (blue, post-update). Never set in normal use.
    private static let forcedUpdateItem: UpdateMenuState.Item? = {
        switch ProcessInfo.processInfo.environment["TOKENPACE_UPDATE_STATE"] {
        case "failed":    return .updateFailed
        case "available": return .updateAvailable
        case "pending":   return .updatePending
        case "whatsnew":  return .whatsNew
        default:          return nil
        }
    }()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon, no main menu — belt-and-suspenders with LSUIElement
        // so the bare `swift run` binary (which has no Info.plist) is also dockless.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run config migrations first — before any UI or polling reads persisted settings — so a
        // future migration can rename keys or clean up stale system state (e.g. old login items)
        // before the rest of launch depends on it (#71, ADR-0023). Phase 1 is a no-op scaffold that
        // only records the running version.
        runConfigMigrationsIfNeeded()

        // Dev hook (#242): `TOKENPACE_GENERATE_JOURNAL=<days>` writes a synthetic multi-day journal and
        // exits, so a downstream reader can be pointed at it via `TOKENPACE_JOURNAL_FILE`. Bypasses the
        // live-only poll path on purpose — this is generated fixture data, not a real poll.
        if let daysRaw = ProcessInfo.processInfo.environment["TOKENPACE_GENERATE_JOURNAL"],
           let days = Int(daysRaw) {
            generateJournalFixture(days: days)
            return
        }

        // Load the persisted monitored-services choice (#89) before the first status poll, so it
        // resolves the right logical services from the start. Falls back to `.default` when absent.
        monitoredServices = PersistedConfig.monitoredServices

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Cold start: no data yet — render the structure (idle/empty), not fake bars. The first
        // poll replaces this within a moment.
        let now = currentDate()
        let coldHealth = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil)
        let view = StatusItemView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 22)))
        view.layout = MenuBarLayout.make(from: nil, health: coldHealth, now: now)
        view.calmColorMode = PersistedConfig.calmColorMode     // apply the saved calm-colours mode from launch (#105, #224)
        view.barStyle = PersistedConfig.barStyle               // apply the saved bar style from launch (#224)
        self.statusView = view
        self.statusItem = item

        // Hand the button a ready image. (Hosting the custom NSView as a button subview is unreliable —
        // the system button paints over it; see StatusItemView.snapshotImage.) The image is non-template,
        // so it must be re-snapshotted on a theme flip — the KVO below does that.
        refreshStatusImage()
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshStatusImage() }
        }

        popupVC.loadView()   // realise the view so it can be sized before the menu measures it
        popupVC.barStyle = PersistedConfig.barStyle   // apply the saved bar style from launch (#224)
        popupVC.showTicks = PersistedConfig.showTicks   // apply the saved tick-ruler choice from launch (#224)
        setPopupLayout(PopupLayout.make(
            from: nil, health: coldHealth, now: now, interval: PollingBackoff.defaultInterval))

        // Host the content in a menu item. Attaching the menu to the status item gives the native
        // menu-bar behaviour: clicking opens it (no target/action needed), there is no popover
        // arrow, and the button highlights while open.
        let menu = NSMenu()
        menu.delegate = self   // drives the ⌥-swap of the Settings/Troubleshoot item (below)
        let popupItem = NSMenuItem()
        popupItem.view = popupVC.view
        menu.addItem(popupItem)

        // "Insights…" is the first action item (#242, ADR-0067) — opens the separate usage-history
        // visualisation window — followed by a divider that separates it from the standard app items.
        let insightsItem = NSMenuItem(title: "", action: #selector(openInsights), keyEquivalent: "")
        insightsItem.attributedTitle = Self.dropdownMenuItemText("Insights…")
        insightsItem.target = self
        menu.addItem(insightsItem)
        menu.addItem(.separator())

        // Action items at the bottom of the same menu (#14). `keyEquivalent: ""` keeps a shortcut
        // glyph off the right edge — none is wanted, and there is no main menu to host a default ⌘Q.
        // No separator before "Settings…": the Claude section now sits on its own inset card (#188
        // follow-up), which already visually detaches it from the native items below.
        // "Settings…" is always visible. Directly below it sits the optional "Troubleshoot…" item
        // (ADR-0020), hidden by default and revealed only while ⌥ Option is held. The native
        // `isAlternate` mechanism does NOT work in a status-item menu, so the reveal is driven by a
        // modifier-polling timer set in `menuWillOpen` — see `updateTroubleshootVisibility(_:)`. Each
        // item carries its own fixed selector; empty keyEquivalent keeps the menu glyph-free.
        let settingsItem = NSMenuItem(title: "", action: #selector(openSettings as () -> Void), keyEquivalent: "")
        settingsItem.attributedTitle = Self.dropdownMenuItemText("Settings…")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let troubleshootItem = NSMenuItem(title: "", action: #selector(openTroubleshoot), keyEquivalent: "")
        troubleshootItem.attributedTitle = Self.dropdownMenuItemText("Troubleshoot…")
        troubleshootItem.target = self
        troubleshootItem.isHidden = true
        menu.addItem(troubleshootItem)
        self.troubleshootItem = troubleshootItem

        // "Development tools…" (#185): the dev colour tuner, sitting just below "Troubleshoot…". Only
        // ever visible when the `devToolsEnabled` defaults key is set AND ⌥ Option is held (both gates
        // applied in `updateTroubleshootVisibility`), so a normal run never shows it — regardless of
        // build type. The item is created unconditionally but starts hidden: the gate is re-checked on
        // every menu open, so toggling the defaults key takes effect on the next open — no menu rebuild.
        let devItem = NSMenuItem(title: "", action: #selector(openDevTools), keyEquivalent: "")
        devItem.attributedTitle = Self.dropdownMenuItemText("Development tools…")
        devItem.target = self
        devItem.isHidden = true
        menu.addItem(devItem)
        self.devToolsItem = devItem

        // "New version available" (#37): sits just above Quit, behind its own separator, with a blue
        // The single update item (#130): one dropdown line carrying every non-critical update signal,
        // sitting just above Quit behind its own separator, with a status-coloured dot (same tinted
        // `circle.fill` attachment the popup uses for service dots). Both the separator and the item
        // start hidden and are driven entirely by `refreshUpdateMenuItem` (colour, label, visibility);
        // click always opens the releases page.
        let updateSeparator = NSMenuItem.separator()
        updateSeparator.isHidden = true
        menu.addItem(updateSeparator)
        self.updateSeparatorItem = updateSeparator

        let updateItem = NSMenuItem(title: "", action: #selector(openReleasesPage), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        self.updateAvailableItem = updateItem

        // Separate Quit from the items above so the terminating action sits in its own group (standard
        // macOS menu grouping). The Quit item grows a tag under ⌥ Option so the running process reads
        // apart at a glance (#69):
        //   • a bare `swift run` binary is tagged "(dev build)" — quitting the right process is
        //     unambiguous when a dev build and the installed `.app` run side by side;
        //   • whenever a **stub** is active the scenario is named too — so a stubbed run is identifiable
        //     even in a **signed `.app`** (which a real notification build must be): "(stub – credits-onset)"
        //     on an `.app`, "(dev build – credits-onset)" on a dev binary.
        // A plain `.app` on the real network shows no tag. The tag is noise on an ordinary open, so it
        // is revealed only while ⌥ Option is held (swapped in `updateTroubleshootVisibility`): the item
        // reads a plain "Quit TokenPace" by default and grows the suffix under Option.
        menu.addItem(.separator())
        updateQuitDevTitle()
        let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "")
        quitItem.attributedTitle = Self.dropdownMenuItemText("Quit TokenPace")
        quitItem.target = self
        menu.addItem(quitItem)
        self.quitItem = quitItem

        item.menu = menu

        startPolling()

        // #233: start the awaiting-input watcher if the feature is already on from a prior launch.
        // No-op (and no file watching) while the feature is off — it's opt-in.
        updateAwaitingInputWatcher()

        // Opt-out auto-registration of launch-at-login (#14): register on the first launch only,
        // log the outcome, never crash on an unsigned build.
        registerLaunchAtLoginIfNeeded()

        // Update check (#37): there are no system notifications (#130 removed the banner) — the sole
        // signal is the single dropdown item (`refreshUpdateMenuItem`). Surface a "what's new" left
        // pending by a prior auto-update relaunch right away, then check for a newer release.
        refreshUpdateMenuItem()
        if PersistedConfig.automaticUpdateChecks {
            // Always check once on launch, bypassing the 12 h cadence: a build the user just
            // installed/relaunched should surface a pending update immediately, not up to half a day
            // later. The cadence still governs re-checks during a long-running session
            // (`pollUpdateIfDue`).
            performUpdateCheck(userInitiated: false)
        }

        AppLogger.lifecycle.info(
            "TokenPace status item attached (\(TokenPaceKit.version, privacy: .public)); live polling started"
        )

        // Dev helper: `TOKENPACE_OPEN_SETTINGS=1 swift run` auto-opens the Settings window on launch, so
        // a settings change can be inspected without an AX menu-bar click — which is unsafe when the
        // installed `.app` and a dev build run side by side (the click can land on the wrong instance).
        // Opt-in via env (not gated on dev-build) so a plain `swift run` still starts quietly.
        if ProcessInfo.processInfo.environment["TOKENPACE_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openSettings() }
        }
        // Same for the Troubleshoot window, normally reached only via the ⌥-revealed menu item — an even
        // more awkward AX interaction to script (it needs the modifier held during menu tracking).
        if ProcessInfo.processInfo.environment["TOKENPACE_OPEN_TROUBLESHOOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openTroubleshoot() }
        }
        // Same for the dev colour tuner (#185), normally reached only via ⌥ on the (flag-gated)
        // "Development tools…" item — doubly awkward to script. Requires the `devToolsEnabled`
        // defaults key set too (`ColorStore.devToolsEnabled`).
        if ColorStore.devToolsEnabled,
           ProcessInfo.processInfo.environment["TOKENPACE_OPEN_DEVTOOLS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openDevTools() }
        }
    }

    // MARK: - Menu actions (#14)

    /// Open (or focus) the Settings… window from the "Settings…" menu item. Leaves the section alone —
    /// a fresh window lands on About (the model's default); a reused one keeps its last-viewed pane.
    @objc private func openSettings() {
        openSettings(section: nil)
    }

    /// Open (or focus) the Insights window from the first menu item (#242, ADR-0067). Lazily creates the
    /// single instance and keeps it alive, mirroring the Settings window's single-instance pattern.
    @objc private func openInsights() {
        if insightsWC == nil { insightsWC = InsightsWindowController() }
        insightsWC?.show()
    }

    /// Open (or focus) the Settings… window, optionally forcing a specific `section` (#210 — the update
    /// menu item opens straight to About). Lazily creates the single instance and wires the
    /// monitored-services change callback (#89) so a toggle there re-polls the status immediately.
    private func openSettings(section: SettingsSection?) {
        if settingsWC == nil {
            let wc = SettingsWindowController()
            wc.onMonitoredServicesChange = { [weak self] config in self?.monitoredServicesChanged(config) }
            wc.onCheckForUpdatesNow = { [weak self] in self?.performUpdateCheck(userInitiated: true) }
            wc.onCalmColorModeChange = { [weak self] mode in
                self?.statusView?.calmColorMode = mode
                self?.refreshStatusImage()   // pure colour change — no layout/width rebuild needed
            }
            wc.onResetCountdownModeMenuBarChange = { [weak self] _ in
                // The mode changes the layout (which countdown to draw), not just a colour — rebuild
                // the menu-bar layout from the last poll (render reads PersistedConfig for the mode).
                self?.reRenderForCurrentTime()
            }
            wc.onBarStyleChange = { [weak self] style in
                // Render-only, both surfaces (#224). The menu-bar bar occupies the same rect (no width
                // rebuild), so a re-snapshot suffices; the popup rebuilds its child bars via its own
                // `barStyle` didSet so the new style reaches each `PopupBarView`.
                self?.statusView?.barStyle = style
                self?.popupVC.barStyle = style
                self?.refreshStatusImage()
                self?.reRenderForCurrentTime()   // also push the new style into the dev-tuner preview
            }
            wc.onShowTicksChange = { [weak self] on in
                // Popup-only (#224): the tick ruler lives in `PopupBarView`; the VC's `showTicks` didSet
                // rebuilds so each child bar picks up the new value. No menu-bar change.
                self?.popupVC.showTicks = on
                self?.reRenderForCurrentTime()   // also push the tick-ruler change into the preview
            }
            wc.onFarBehindIntervalChange = { [weak self] _ in
                // The green→blue threshold changes each bar's `behindMultiplier` (#224), which is baked
                // into the layout — rebuild both surfaces from the last poll (render reads
                // PersistedConfig.farBehindInterval for the multiplier).
                self?.reRenderForCurrentTime()
            }
            wc.onServiceDotChange = { [weak self] _ in
                // The dot changes the layout (drawn + item width), not just a colour — rebuild the
                // menu-bar layout from the last poll (render reads PersistedConfig for the toggle).
                self?.reRenderForCurrentTime()
            }
            wc.onExtraUsageChange = { [weak self] _ in
                // The credits icon changes the layout (drawn + item width), not just a colour — rebuild
                // from the last poll (render reads PersistedConfig.showExtraUsage for the gate).
                self?.reRenderForCurrentTime()
            }
            wc.onShowModelSpecificLimitsChange = { [weak self] _ in
                // Toggling this adds/removes the popup's per-model rows — rebuild from the last poll
                // (render reads PersistedConfig.showModelSpecificLimits for the gate). #211.
                self?.reRenderForCurrentTime()
            }
            wc.onHideCalmSevenDayChange = { [weak self] _ in
                // Toggling this changes the layout (7-day bar drawn or not, 5h vertical centring),
                // not just a colour — rebuild from the last poll (render reads PersistedConfig).
                self?.reRenderForCurrentTime()
            }
            wc.onPauseHidesBarsChange = { [weak self] _ in
                // Toggling this swaps the whole mode when blocked (pause icon alone vs. pause icon + bars),
                // not just a colour — rebuild from the last poll (render reads PersistedConfig.pauseHidesBars).
                self?.reRenderForCurrentTime()
            }
            wc.onPausePollingChange = { [weak self] on in
                // Turning the pause OFF must un-stick a loop already parked by a screen lock: send a
                // `.wake` so it resumes immediately. Turning it ON changes nothing now — the next lock
                // will park it (the observer reads the pref live). No render impact either way.
                if !on { self?.signals.send(.wake) }
            }
            wc.onAwaitingInputEnabledChange = { [weak self] _ in
                // #233: the master toggle flipped — start/stop the watcher (which reads the pref) and
                // re-render so the indicator appears/disappears from the last poll.
                self?.updateAwaitingInputWatcher()
                self?.reRenderForCurrentTime()
            }
            wc.onAwaitingInputAppearanceChange = { [weak self] in
                // #233: an awaiting-input appearance option changed (left-of-pause placement) — just
                // re-render from the last poll; no watcher restart needed.
                self?.reRenderForCurrentTime()
            }
            wc.onArchiveNow = { [weak self] in self?.performArchiveSync(userInitiated: true) }
            wc.archiveSummaryProvider = { [weak self] in self?.lastArchiveSummary }
            wc.onBackToWorkEnabled = { completion in
                // Lazily request notification authorization the first time the user enables the
                // feature (#160) — never at launch, since this is opt-in.
                BackToWorkNotifier.requestAuthorizationIfNeeded(completion: completion)
            }
            // The Settings "Try" button (#193): fire the banner on demand, bypassing edge-detection
            // and quiet hours (postBackToWork itself only checks support + authorization).
            wc.onTryBackToWork = { BackToWorkNotifier.postBackToWork() }
            // "Try" for the Extra-Usage banner: build the body from the latest snapshot's spend so the
            // preview shows real amount/limit when available; an empty SpendInfo degrades to the generic
            // line. Bypasses edge-detection and quiet hours, same as back-to-work's Try.
            wc.onTryExtraUsage = { [weak self] in
                let spend = self?.lastOutput?.snapshot?.spend ?? SpendInfo()
                BackToWorkNotifier.postExtraUsage(body: ExtraUsageOnset.bannerBody(for: spend))
            }
            settingsWC = wc
        }
        // Reflect the latest known update state whenever the window opens (#37).
        settingsWC?.updateAvailability(lastKnownRelease)
        // Same for the live data source: the model seeds itself from `launchScenario`, but the dev-tools
        // selector may have switched scenarios since — and any push from `switchScenario` before the
        // window first opened went to a nil controller. Pull the current value on every open so the
        // "Stubbed in this development build." hints can never outlive the stub.
        settingsWC?.updateStubState(active: currentScenario != .realNetwork)
        settingsWC?.show(section: section)
    }

    /// Open (or focus) the hidden Troubleshoot window (ADR-0020), seeded with the latest poll
    /// result. Reached via the optional "Troubleshoot…" item, revealed while ⌥ Option is held. Lazily
    /// creates the single instance; while open it re-renders on every poll. Its force-refresh button
    /// routes back to `forceRefresh()`.
    @objc private func openTroubleshoot() {
        if troubleshootWC == nil {
            let wc = TroubleshootWindowController()
            wc.onForceRefresh = { [weak self] in self?.forceRefresh() }
            troubleshootWC = wc
        }
        troubleshootWC?.show(lastOutput)
    }

    /// Open (or focus) the dev colour tuner (#185). Lazily creates the single instance and wires its
    /// change callback to re-render both surfaces, so a colour edit repaints the menu-bar icon and the
    /// popup live. Reachable only when the `devToolsEnabled` defaults key is set (the item is gated in the menu).
    @objc private func openDevTools() {
        if devToolsWC == nil {
            devToolsWC = DevToolsWindowController()
            ColorStore.shared.onChange = { [weak self] in self?.reRenderForCurrentTime() }
            // Live stub selector (#187): the dropdown reports its pick back here to swap the data source
            // without a restart. Mirrors the ColorStore.onChange bridge — the window holds no model ref.
            devToolsWC?.onStubChange = { [weak self] in self?.switchScenario($0) }
        }
        devToolsWC?.setCurrentScenario(currentScenario)   // preselect the active stub (incl. env-set)
        devToolsWC?.show()
        reRenderForCurrentTime()   // seed the tuner's popup preview with the current layout right away
    }

    /// Force an immediate refresh of both data streams (the Troubleshoot window's button, ADR-0020):
    /// send `.manualRefresh` so the usage loop polls now and clears any 429 backoff to the base
    /// interval, and clear `lastStatusSuccess` so the status poll — which rides the usage heartbeat —
    /// is due again and re-fetches on that same immediate tick.
    private func forceRefresh() {
        AppLogger.lifecycle.notice("manual refresh requested (Troubleshoot)")
        lastStatusSuccess = nil            // make the status poll due on the next (immediate) tick
        signals.send(.manualRefresh)       // wake the usage loop now + reset backoff (engine)
    }

    // MARK: - Optimistic reset (#36)

    /// React to a park/resume signal (`.sleep`/`.wake`) from either the system sleep/wake observer or
    /// the screen-lock observer (#114): `Timer` scheduling is unreliable across sleep, so we invalidate
    /// the optimistic-reset timer on park and recompute its delay from the current `Date()` on resume —
    /// if a reset passed while parked, `rescheduleResetTimer`'s `delay <= 0` guard fires it immediately.
    /// Other signals (`.networkRestored`, `.manualRefresh`) do not touch the reset timer.
    private func handleParkSignal(_ signal: PollSignal) {
        switch signal {
        case .sleep:
            resetTimer?.invalidate()
            resetTimer = nil
        case .wake:
            rescheduleResetTimer(from: lastOutput?.snapshot, now: currentDate())
        default:
            break
        }
    }

    /// (Re)arm the one-shot `resetTimer` for the nearest **future** window reset in `snapshot`. Any
    /// pending timer is invalidated first, so this is safe to call on every poll and on wake. When the
    /// nearest reset is already at/past `now` (e.g. we woke after it passed), the optimistic reset is
    /// applied immediately instead of scheduling a timer in the past; when neither window has a future
    /// reset (both past, or 5h idle + no 7d — impossible in practice), nothing is scheduled.
    private func rescheduleResetTimer(from snapshot: UsageSnapshot?, now: Date) {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let snapshot else { return }
        guard let instant = ResetClock.nextResetInstant(
            fiveHourResetsAt: snapshot.fiveHour.resetsAt,
            sevenDayResetsAt: snapshot.sevenDay.resetsAt,
            now: now) else {
            // No future reset to wait for. If a boundary already passed, roll forward now.
            fireOptimisticReset()
            return
        }
        let delay = instant.timeIntervalSince(now)
        guard delay > 0 else { fireOptimisticReset(); return }
        // `.common` run-loop mode so it still fires while an NSMenu is tracking (mirrors `ageTimer`).
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireOptimisticReset() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }

    /// A window reset boundary just passed: overlay a local optimistic reset on the retained snapshot
    /// (zero usage + rolled-forward `resets_at`), render it immediately so the menu bar never shows the
    /// stale ⏰, re-arm the timer for the next boundary, then force an authoritative refresh. The forced
    /// poll goes through the engine (`.manualRefresh`), so backoff/health update normally and the next
    /// successful response overwrites the optimistic overlay wholesale (the API is the source of truth).
    private func fireOptimisticReset() {
        guard let output = lastOutput, let snapshot = output.snapshot else { return }
        let now = currentDate()
        let reset = ResetClock.optimisticReset(snapshot, now: now)
        // Nothing actually crossed a boundary (early/spurious fire) — leave state untouched.
        guard reset != snapshot else { return }
        AppLogger.lifecycle.notice("optimistic reset applied, forcing refresh")
        // 1. Replace the retained output with the optimistic overlay and render it now (no ⏰).
        let overlay = PollOutput(
            snapshot: reset, health: output.health, interval: output.interval,
            diagnostics: output.diagnostics)
        lastOutput = overlay
        render(overlay, at: now)
        // 2. Arm the timer for the *next* boundary (the window that did not just reset).
        rescheduleResetTimer(from: reset, now: now)
        // 3. Force the authoritative refresh (engine → backoff/health → overwrites the overlay).
        forceRefresh()
    }

    /// Apply a new monitored-services config chosen in Settings (#89): adopt it, drop the stale
    /// status (it was resolved under the old config — the enabled set may have changed), and force an
    /// immediate re-poll so the popup/menu-bar reflect the new services within a moment. Clearing
    /// `lastStatusHealth` briefly hides the status rows/dot until that fetch lands — honest, since
    /// the retained value describes services that are no longer the ones being monitored.
    func monitoredServicesChanged(_ config: MonitoredServices) {
        monitoredServices = config
        lastStatusHealth = nil
        lastStatusSuccess = nil            // status poll is due again on the immediate tick
        signals.send(.manualRefresh)       // wake the usage loop now, which rides the status poll
        reRenderForCurrentTime()           // clear the stale rows/dot right away
    }

    /// Show or hide the optional "Troubleshoot…" item — and flip the popup's service-status
    /// visibility — for the current ⌥ Option state (ADR-0020). Called on menu open and by
    /// `optionPollTimer` while it is open — the status-item-menu replacement for the inert native
    /// `isAlternate` swap. Skips the work when the state is unchanged, so the poll is cheap.
    private func updateTroubleshootVisibility(_ optionHeld: Bool) {
        guard let troubleshootItem, optionHeld != lastOptionHeld else { return }
        lastOptionHeld = optionHeld
        troubleshootItem.isHidden = !optionHeld
        // "Development tools…" needs both gates: ⌥ Option AND the `devToolsEnabled` defaults key. The
        // item always exists now, so the flag gate is applied here (re-checked each open, so toggling
        // the defaults key takes effect on the next menu open).
        devToolsItem?.isHidden = !(optionHeld && ColorStore.devToolsEnabled)
        // Reveal the Quit tag ("(dev build …)" / "(stub …)") only while ⌥ is held (`quitDevTitle` is nil
        // for a plain `.app` on the real network, so the title stays a plain "Quit TokenPace" there).
        if let quitItem, let quitDevTitle {
            quitItem.attributedTitle = Self.dropdownMenuItemText(optionHeld ? quitDevTitle : "Quit TokenPace")
        }
        popupVC.optionHeld = optionHeld
        // The service-status rows appearing/disappearing changes the popup's fitting size; `NSMenu`
        // does not re-measure a hosted item view on its own (see `setPopupLayout`'s note), so the
        // frame must be re-fit here too, exactly like every other content change.
        popupVC.view.frame = NSRect(origin: .zero, size: popupVC.view.fittingSize)
    }

    /// The native menu item's text, forced to `dropdownTextSize` (regular weight) — the counterpart
    /// of the popup's own labels, which use the same constant, so the dropdown's custom-view section
    /// and its native items never visually drift in size again.
    private static func dropdownMenuItemText(_ text: String) -> NSAttributedString {
        // No explicit colour — NSMenu draws the title in its own appearance's label colour.
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: dropdownTextSize)])
    }

    /// Quit the app via the standard terminate path, which triggers `applicationWillTerminate`.
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Compare the stored config version against the running one and run any migrations before the
    /// config is used (#71, ADR-0023). Phase 1 is a scaffold: it classifies the launch, logs the
    /// outcome, and records the current version — there are no real migration steps yet, only the
    /// `.upgraded` extension point. Called first thing in `applicationDidFinishLaunching`.
    private func runConfigMigrationsIfNeeded() {
        let current = TokenPaceKit.version
        switch MigrationPlan.transition(stored: PersistedConfig.lastRunVersion, current: current) {
        case .firstRun:
            AppLogger.lifecycle.notice(
                "config: first run, no prior version (\(current, privacy: .public))")
        case .unchanged:
            AppLogger.lifecycle.notice("config: version unchanged (\(current, privacy: .public))")
        case .upgraded(let from, let to):
            AppLogger.lifecycle.notice(
                "config: version \(from, privacy: .public) → \(to, privacy: .public), running migrations")
            // Future from→to migrations run here. Empty scaffold for now (#71).
        }
        // Idempotent per-key migrations that must catch an upgrade from *any* prior version (not gated
        // on the version diff above): merge the pre-#227 pause settings into the unified key.
        PersistedConfig.migratePauseKeysIfNeeded()
        // Record the running version so the next launch compares against it.
        PersistedConfig.lastRunVersion = current
    }

    /// Opt-out auto-registration: attempt to register whenever the OS has no active login item for
    /// us — either never registered, or a registration that dropped with a replaced bundle on an
    /// in-place update (`.notFound`, #69). This runs on every launch and is idempotent via the
    /// status guard: `.registered`/`.requiresApproval` are left alone (the user/system decided).
    ///
    /// Gated to a real `.app` bundle: an ad-hoc-signed `swift run` binary is registerable too, so
    /// without this gate every dev run would silently add a login item pointing at `.build/…` and
    /// pollute the user's Login Items (#69). On a dev build the Settings toggle stays clickable, so
    /// launch-at-login can still be exercised on demand — it's just not auto-registered.
    private func registerLaunchAtLoginIfNeeded() {
        guard LaunchAtLoginController.isAppBundle else {
            AppLogger.lifecycle.notice(
                "launch-at-login: not an .app bundle (swift run), skipping opt-out auto-register")
            return
        }
        let status = LaunchAtLoginController.currentStatus()
        guard LaunchAtLogin.shouldAttemptRegister(status) else {
            AppLogger.lifecycle.notice(
                "launch-at-login: status=\(String(describing: status), privacy: .public), no auto-register")
            return
        }
        do {
            try LaunchAtLoginController.enable()
            AppLogger.lifecycle.notice("launch-at-login: auto-registered (opt-out)")
        } catch {
            // A genuine install registers here — including recovery after a bundle replacement
            // dropped the BTM item. A throw means an installed-but-unregisterable bundle; log it.
            AppLogger.lifecycle.error(
                "launch-at-login: auto-register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        statusTask?.cancel()
        updateTask?.cancel()
        installTask?.cancel()
        archiveTask?.cancel()
        ageTimer?.invalidate()
        resetTimer?.invalidate()
        sleepWake?.stop()
        screenLock?.stop()
        network.stop()
    }

    // MARK: - Live polling wiring (#13)

    /// Wire the platform signal sources to the engine and consume its output on the main actor.
    private func startPolling() {
        // Sleep/wake and network observers push signals into the shared hub. The optimistic-reset
        // timer (#36) also keys off sleep/wake: `Timer` scheduling is unreliable across sleep, so we
        // invalidate on sleep and recompute the delay from the current `Date()` on wake — if a reset
        // passed while asleep, `rescheduleResetTimer`'s `delay <= 0` guard fires it immediately.
        sleepWake = WorkspaceSleepWake { [signals, weak self] signal in
            signals.send(signal)
            // Observers fire on the main queue (see WorkspaceSleepWake), so we are on the main actor.
            MainActor.assumeIsolated { self?.handleParkSignal(signal) }
        }
        // Screen lock / screensaver / display-sleep park the loop the same way, gated by the
        // pause-on-screen-lock preference (#114). It emits the same `.sleep`/`.wake`, so it also drives
        // the optimistic-reset timer through the shared handler.
        screenLock = ScreenLockObserver { [signals, weak self] signal in
            signals.send(signal)
            MainActor.assumeIsolated { self?.handleParkSignal(signal) }
        }
        network.start { [signals] in signals.send(.networkRestored) }

        // Build and run the polling engine for the launch scenario (`TOKENPACE_STUB`, or the real
        // network). The dev-tools live selector (#187) re-runs `buildAndRunEngine(for:)` to switch the
        // data source without a restart, so the observers + age timer above stay put and only the
        // engine is rebuilt.
        buildAndRunEngine(for: currentScenario)

        // Re-render on a fixed cadence so time-derived text ages without waiting for the next poll:
        // the popup's "Last update" line ("just now" → "1m ago") and the menu bar's stale ⚠️
        // thresholds (30/60 min) both depend on `now`, not on new data. 30 s is fine-grained enough
        // for minute-resolution text and costs nothing — it only recomputes view models, never fetches.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reRenderForCurrentTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    /// Construct the polling engine (transport, token provider, refresher) for `scenario` and start its
    /// consumer task, tearing down any previous engine first. Shared by launch and the dev-tools live
    /// selector (#187). The scenario→transport mapping and the stub-vs-real token/refresher choice come
    /// from the shared ``StubScenario`` registry, so the env path and the dropdown never diverge.
    ///
    /// Each call takes a **fresh** signal stream from the hub (``SignalHub/newStream()``) — an
    /// `AsyncStream` is single-consumer, so a rebuilt engine must not reuse the old (finished) stream.
    private func buildAndRunEngine(for scenario: StubScenario) {
        pollTask?.cancel()

        // The scenario's clock (fixed for a date-decoupled stub, else the wall clock) feeds BOTH the
        // stub transport's `resets_at` and the engine's own `now`, so canned resets and pacing math
        // never disagree. The visible render reads the same clock via `currentDate()`.
        let clock = scenario.clock()
        let transport = scenario.makeTransport(now: clock)
        // The status poll uses the same transport seam (the stub answers the status endpoint too).
        statusTransport = transport
        // Under a stub the bearer token is never validated (canned responses), so skip the Keychain
        // entirely — reading it would only pop the system access prompt on a dev build. The refresher
        // is live-only for the same reason: a stub run must never spawn the CLI.
        //
        // Exception — `TOKENPACE_FORCE_REFRESH=1` (verification only, #183), real network only: hand
        // the engine an *already-expired* stub token together with the *real* `ClaudeCLIRefresher`, so
        // the poll takes the `.expired` branch and spawns `claude --safe-mode …` on demand. The two
        // env vars are independent (force-refresh is ignored under a stub).
        let forceRefresh =
            ProcessInfo.processInfo.environment["TOKENPACE_FORCE_REFRESH"] == "1" && !scenario.usesStubToken
        let tokenProvider: TokenProviding = switch (scenario.usesStubToken, forceRefresh) {
        case (true, _):      StubTokenProvider()
        case (false, true):  ExpiredStubTokenProvider()
        case (false, false): KeychainTokenProvider()
        }
        let refresher: DelegatedRefresher? = scenario.usesStubToken ? nil : ClaudeCLIRefresher()
        let engine = PollingEngine(
            transport: transport,
            tokenProvider: tokenProvider,
            refresher: refresher,
            scheduler: LivePollScheduler(signals: signals.newStream()),
            probe: ProcessClaudeActivityProbe(),
            now: clock)

        // Consume on the main actor — every PollOutput drives the menu bar + popup.
        pollTask = Task { [weak self] in
            for await output in engine.run() {
                guard let self else { break }
                self.apply(output)
            }
        }
    }

    /// Switch the live data source to `scenario` (dev-tools selector, #187): rebuild the engine and
    /// force an immediate poll so the menu bar + popup reflect the new state within one cycle. No-op if
    /// the scenario is already active. Dev-only — reached only from the Development-tools dropdown.
    private func switchScenario(_ scenario: StubScenario) {
        guard scenario != currentScenario else { return }
        AppLogger.lifecycle.notice("dev: stub scenario → \(scenario.id, privacy: .public)")
        currentScenario = scenario
        updateQuitDevTitle()             // keep the ⌥-Option Quit tag in sync with the live stub
        buildAndRunEngine(for: scenario)
        lastStatusSuccess = nil          // make the status poll due on the next (immediate) tick
        // The awaiting-input watcher is gated on `.realNetwork`, so switching *into* a stub tears it
        // down and switching back out brings it up again — without this the gate would only ever be
        // evaluated at launch. Also refresh the Settings hints that explain the stubbed state.
        updateAwaitingInputWatcher()
        reRenderForCurrentTime()         // drop the stale awaiting count from the widget right away
        settingsWC?.updateStubState(active: scenario != .realNetwork)
        signals.send(.manualRefresh)     // wake the freshly-built usage loop now
    }

    /// Recompute the ⌥-Option "Quit TokenPace (…)" tag for the current build + stub. Called at menu-build
    /// time and again whenever the live stub selector (#187) switches scenarios, so the tag always names
    /// the stub actually running — including in a **signed `.app`** (which a real notification build must
    /// be). A plain `.app` on the real network gets no tag (`nil`). The suffix is shown only while ⌥ is
    /// held (see `updateTroubleshootVisibility`).
    private func updateQuitDevTitle() {
        let isDevBuild = !LaunchAtLoginController.isAppBundle
        let hasStub = currentScenario != .realNetwork
        if isDevBuild, hasStub {
            quitDevTitle = "Quit TokenPace (dev build – \(currentScenario.id))"
        } else if isDevBuild {
            quitDevTitle = "Quit TokenPace (dev build)"
        } else if hasStub {
            quitDevTitle = "Quit TokenPace (stub – \(currentScenario.id))"
        } else {
            quitDevTitle = nil
        }
        // If Option is currently held and the dropdown is open, reflect the new tag immediately.
        if lastOptionHeld, let quitItem, let quitDevTitle {
            quitItem.attributedTitle = Self.dropdownMenuItemText(quitDevTitle)
        }
    }


    /// Map one poll result into the menu-bar image and the popup model, and retain it so the age
    /// timer can re-render it against a later `now`. Also rides this heartbeat to poll the Claude
    /// status page when due (#31) — no separate timer.
    private func apply(_ output: PollOutput) {
        detectBackToWorkEdge(output)
        detectExtraUsageEdge(output)
        lastOutput = output
        render(output, at: currentDate())
        // Re-arm the optimistic-reset timer against this poll's `resets_at` (#36). A successful poll
        // fully overwrites any prior optimistic overlay; a 429/error poll carries the stale last-known
        // snapshot, so rescheduling is a harmless no-op (same instant).
        rescheduleResetTimer(from: output.snapshot, now: currentDate())
        // Live-update an open Troubleshoot window: both sections (JSON, timestamps, next update,
        // token dates) refresh in place each poll (ADR-0020). No-op while the controller is nil.
        troubleshootWC?.render(output)
        journalPoll(output)
        pollStatusIfDue(usageInterval: output.interval)
        pollUpdateIfDue()
        pollArchiveIfDue()
    }

    /// Append this usage poll to the local journal (#242) — a `usage` line on success, an `error` line
    /// on a genuine failure. No-op unless the journal is enabled **and** the app is on the live
    /// `.realNetwork` scenario: synthetic stub data must never enter the journal.
    ///
    /// The record is built here (on the main actor, from the fresh `output`) but the file write is
    /// dispatched to the `UsageJournal` actor, so the render path is never blocked and a write error is
    /// swallowed by the writer. The interval carried on `output` is the gap-detector's expected cadence.
    private func journalPoll(_ output: PollOutput) {
        guard PersistedConfig.journalEnabled, currentScenario == .realNetwork else { return }
        let now = currentDate()
        let interval = output.interval
        let record: JournalRecord
        if output.health.failingSince == nil, let snapshot = output.snapshot {
            record = .usage(
                from: snapshot, now: now,
                durationMs: output.diagnostics?.fetch.durationMs,
                plan: output.diagnostics?.token?.subscriptionType,
                tier: output.diagnostics?.token?.rateLimitTier)
        } else if let fetch = output.diagnostics?.fetch {
            record = .error(diagnostics: fetch, failure: output.health.reason, now: now)
        } else {
            return  // A failure with no diagnostics (never in the live path) — nothing to record.
        }
        Task { [usageJournal] in
            await usageJournal.append(record, at: now, expectedInterval: interval)
        }
    }

    /// Dev hook (#242): generate a synthetic multi-day journal and terminate. Writes through
    /// `UsageJournal` (honouring `TOKENPACE_JOURNAL_FILE`), bypassing the live-only poll gates because
    /// this is fixture data for downstream UI verification, not a real poll. Logs the target path.
    private func generateJournalFixture(days: Int) {
        let records = JournalFixture.multiDay(days: days, endingAt: Date())
        AppLogger.journal.notice(
            "journal: generating fixture — \(days, privacy: .public) days, \(records.count, privacy: .public) records")
        Task { [usageJournal] in
            await usageJournal.appendFixture(records)
            AppLogger.journal.notice("journal: fixture written")
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// Detect the blocked→unblocked edge for the "Back to work!" notification (#160) and post when it
    /// fires. Called at the top of `apply`, before `lastOutput` is overwritten.
    ///
    /// The "was blocked" state is **persisted** (`PersistedConfig.backToWorkWasBlocked`), not an
    /// in-memory flag, so the edge survives an app restart or a Mac sleep/reboot between the block and
    /// the reset. Tracking and posting live in separate guards on purpose:
    /// - **Tracking runs on every successful poll**, regardless of whether the feature is enabled, so
    ///   the persisted state is always current — toggling the feature off→on never forgets a pending
    ///   edge, and never fires a stale one for a reset that happened while the feature was off.
    /// - **Posting runs only when the feature is enabled** *and* the previous successful reading was
    ///   genuinely blocked *and* we are now workable.
    ///
    /// Only genuine successful polls update the state: a failing/stale poll carries the last-known
    /// snapshot forward (`health.failingSince != nil`), and the optimistic-reset overlay bypasses
    /// `apply` entirely (it calls `render`, not `apply`), so neither can produce a false "unblocked".
    private func detectBackToWorkEdge(_ output: PollOutput) {
        guard output.health.failingSince == nil, let snapshot = output.snapshot else { return }
        let nowWorkable = WorkAvailability.canWork(snapshot)
        if PersistedConfig.backToWorkEnabled, PersistedConfig.backToWorkWasBlocked, nowWorkable {
            maybePostBackToWork()
        }
        PersistedConfig.backToWorkWasBlocked = !nowWorkable
    }

    /// Apply the quiet-hours gate and post the "Back to work!" banner if allowed (#160). The pure
    /// evaluation (`NotificationSchedule`) runs against the user's window/suppress choice in a
    /// device-zone gregorian calendar; the impure post lives in `BackToWorkNotifier`.
    private func maybePostBackToWork() {
        guard notificationsAllowedNow() else {
            AppLogger.lifecycle.info("back-to-work: suppressed by quiet hours")
            return
        }
        BackToWorkNotifier.postBackToWork()
    }

    /// Detect the not-spending→spending-on-credits edge for the "Now using Extra Usage Credit"
    /// notification and post when it fires. Called from `apply`, alongside `detectBackToWorkEdge` and
    /// with the identical tracking/posting split: the "was on credits" state is **persisted**
    /// (`PersistedConfig.extraUsageWasOnCredits`) and updated on **every** successful poll regardless of
    /// the toggle (so an off→on flip never forgets or replays an edge); posting is gated on the toggle,
    /// the previous reading being *not* on credits, and the current one being on credits.
    ///
    /// This is a distinct edge from "Back to work!": that fires on blocked→workable, this on the switch
    /// onto paid credit (a state that is already workable), so the two never collide.
    private func detectExtraUsageEdge(_ output: PollOutput) {
        guard output.health.failingSince == nil, let snapshot = output.snapshot else { return }
        let nowOnCredits = ExtraUsageOnset.isOnCredits(snapshot)
        if PersistedConfig.extraUsageNotifyEnabled,
           !PersistedConfig.extraUsageWasOnCredits,
           nowOnCredits,
           let spend = snapshot.spend {
            maybePostExtraUsage(for: spend)
        }
        PersistedConfig.extraUsageWasOnCredits = nowOnCredits
    }

    /// Apply the quiet-hours gate and post the "Now using Extra Usage Credit" banner if allowed. The
    /// body (spent amount + limit) is built by the pure `ExtraUsageOnset.bannerBody(for:)`.
    private func maybePostExtraUsage(for spend: SpendInfo) {
        guard notificationsAllowedNow() else {
            AppLogger.lifecycle.info("extra-usage: suppressed by quiet hours")
            return
        }
        BackToWorkNotifier.postExtraUsage(body: ExtraUsageOnset.bannerBody(for: spend))
    }

    /// Whether the shared quiet-hours window / weekend-suppress currently allows a notification. Both
    /// local notifications ("Back to work!", "Extra Usage Credit") gate on the **same** user schedule
    /// (`notifyWindow*` + `notifySuppressDays`), evaluated in a device-zone gregorian calendar.
    private func notificationsAllowedNow() -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = .current
        return NotificationSchedule.isAllowed(
            at: Date(),
            window: (PersistedConfig.notifyWindowStartMinute, PersistedConfig.notifyWindowEndMinute),
            suppress: PersistedConfig.notifySuppressDays,
            calendar: calendar
        )
    }

    /// Fetch the Claude status page when `StatusCadence` says it is due — riding the usage poll's
    /// heartbeat with a 5-min politeness floor (`max(floor, usageInterval)`), so it never hammers a
    /// third-party page even when the usage cadence is fast or thrashing on 429.
    private func pollStatusIfDue(usageInterval: TimeInterval) {
        // While a service problem is in progress, poll faster (down to the 60-s problem floor) to
        // catch escalation/recovery quickly; otherwise the polite 5-min floor applies.
        let hasProblem = lastStatusHealth?.worstProblem != nil
        guard StatusCadence.isDue(
            lastSuccess: lastStatusSuccess, usageInterval: usageInterval,
            hasProblem: hasProblem, now: Date()) else { return }
        // Cancel any slow in-flight fetch rather than overlap.
        statusTask?.cancel()
        let transport = statusTransport
        // Snapshot the config for this fetch — which logical services to resolve, and which grey
        // `unknown` lines to show if it fails (#89). `Claude API` is always in there.
        let config = monitoredServices
        statusTask = Task { [weak self] in
            let health: StatusHealth
            let succeeded: Bool
            var fetchedSummary: StatusSummary?
            do {
                let summary = try await StatusClient.fetch(transport: transport)
                health = .from(summary, config: config)
                fetchedSummary = summary
                succeeded = true
            } catch {
                // Any failure → honest "unknown" (grey), and don't advance lastStatusSuccess so the
                // next usage tick retries.
                health = .unknown(for: config)
                succeeded = false
            }
            guard let self, !Task.isCancelled else { return }
            self.lastStatusHealth = health
            if succeeded { self.lastStatusSuccess = Date() }
            // Journal the successful status poll as its own data sample (#242) — same live-only /
            // enabled gates as the usage seam. Status rides a separate cadence, so it does **not** run
            // the usage gap detector; it is an independent sample in the shared file.
            if succeeded, let summary = fetchedSummary,
               PersistedConfig.journalEnabled, self.currentScenario == .realNetwork {
                let record = JournalRecord.status(from: summary, health: health, now: self.currentDate())
                let at = self.currentDate()
                Task { [usageJournal = self.usageJournal] in await usageJournal.appendStatus(record, at: at) }
            }
            // Re-render with the new status against the retained usage output.
            self.reRenderForCurrentTime()
        }
    }

    // MARK: - Update check (#37)

    /// Run the periodic GitHub-release check when it is due, riding the usage heartbeat like the
    /// status poll. No-op when the user turned the feature off, or when the 12 h cadence has not
    /// elapsed.
    private func pollUpdateIfDue() {
        guard PersistedConfig.automaticUpdateChecks else { return }
        guard UpdateCheckCadence.isDue(lastCheck: PersistedConfig.lastUpdateCheck, now: Date()) else { return }
        performUpdateCheck(userInitiated: false)
    }

    /// Perform one update check — shared by three callers: the launch-time check (always, bypassing
    /// the cadence), the periodic heartbeat (`pollUpdateIfDue`, gated by `UpdateCheckCadence`), and the
    /// Settings… "Check now" button (`userInitiated: true`). `userInitiated` only affects logging; all
    /// three record the attempt and surface a result identically.
    ///
    /// The attempt marker is advanced on **every** run, success or graceful failure, so a private-repo
    /// 404 on the anonymous path does not re-fetch each heartbeat (ADR-0025). The fetch itself is
    /// dispatched on a `Task`; because `AppDelegate` is `@MainActor`, the continuation after `await`
    /// resumes on the main actor, so flipping the menu item and touching `PersistedConfig` is safe.
    func performUpdateCheck(userInitiated: Bool) {
        updateTask?.cancel()
        let fetcher = makeUpdateFetcher()
        AppLogger.network.notice(
            "update: checking (userInitiated=\(userInitiated, privacy: .public))")
        updateTask = Task { [weak self] in
            let release = await GitHubReleaseClient.checkForUpdate(using: fetcher)
            guard let self, !Task.isCancelled else { return }
            PersistedConfig.lastUpdateCheck = Date()
            if let release {
                self.handleUpdateFound(release)
            } else {
                // Up to date (or a graceful failure). Clear the stale "newer release" state and the
                // defer flag, then recompute the item: it does **not** simply hide — a successful
                // auto-update leaves a pending "what's new" that surfaces precisely when the installed
                // build is the newest (`UpdateMenuState`).
                self.lastKnownRelease = nil
                self.installDeferred = false
                self.settingsWC?.updateAvailability(nil)
                self.refreshUpdateMenuItem()
            }
        }
    }

    // MARK: - Session-log archive (#110)

    /// Mirror Claude Code's session logs when the daily `ArchiveCadence` says it is due, riding the
    /// usage heartbeat like the update and status polls. No-op when the feature is off, no destination
    /// is set, or the 24 h window has not elapsed.
    private func pollArchiveIfDue() {
        guard PersistedConfig.archiveEnabled, PersistedConfig.archiveDestination != nil else { return }
        guard ArchiveCadence.isDue(lastSync: PersistedConfig.lastArchiveSync, now: Date()) else { return }
        performArchiveSync(userInitiated: false)
    }

    /// Run one archive sync — shared by the daily heartbeat (`pollArchiveIfDue`) and the Settings…
    /// "Archive now" button (`userInitiated: true`). Requires a destination (the caller guards, but
    /// this re-checks). The `lastArchiveSync` marker advances only on **success**, so a failed sync
    /// (unwritable folder) stays due and retries next heartbeat (`ArchiveCadence`).
    ///
    /// Dispatched on a `Task` off the main actor for the file I/O; because `AppDelegate` is
    /// `@MainActor`, the continuation after `await` resumes on the main actor, so touching
    /// `PersistedConfig`, `lastArchiveSummary`, and the Settings window is safe.
    func performArchiveSync(userInitiated: Bool) {
        guard let path = PersistedConfig.archiveDestination else { return }
        let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        archiveTask?.cancel()
        AppLogger.archive.notice("archive: sync starting (userInitiated=\(userInitiated, privacy: .public))")
        archiveTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<LogArchiver.Summary, Error> in
                do { return .success(try LogArchiver().sync(to: destination)) }
                catch { return .failure(error) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let summary):
                PersistedConfig.lastArchiveSync = Date()
                self.lastArchiveSummary = summary
                AppLogger.archive.notice(
                    "archive: sync ok — \(summary.copied, privacy: .public) updated, \(summary.bytes, privacy: .public) bytes, \(summary.totalInArchive, privacy: .public) files / \(summary.totalBytesInArchive, privacy: .public) bytes in archive")
                self.settingsWC?.updateArchiveStatus()
            case .failure(let error):
                // Don't advance the marker → next heartbeat retries.
                AppLogger.archive.error(
                    "archive: sync failed — \(error.localizedDescription, privacy: .public)")
                self.settingsWC?.updateArchiveStatus()
            }
        }
    }

    /// Choose the fetch path: the `gh` subprocess when `TOKENPACE_GH_AUTH` is set (maintainers, so a
    /// private repo's releases are readable via local `gh` credentials), otherwise the anonymous
    /// HTTPS client (which works once the repo is public; while private it 404s → no update).
    ///
    /// `TOKENPACE_FAKE_LATEST=vX.Y.Z` overrides both paths with a canned tag — a verification aid
    /// (mirrors `TOKENPACE_STUB`) so the "update available" and "up to date" UI branches can be driven
    /// on demand regardless of what the real latest release is. Never set in normal use.
    private func makeUpdateFetcher() -> UpdateFetcher {
        if let fake = ProcessInfo.processInfo.environment["TOKENPACE_FAKE_LATEST"], !fake.isEmpty {
            return StubUpdateFetcher(tag: fake)
        }
        if ghAuthEnabled {
            return GHReleaseFetcher()
        }
        return HTTPUpdateFetcher()
    }

    /// Resolve whether `TOKENPACE_GH_AUTH` is set. The app is usually launched at login by launchd,
    /// which passes no shell environment, so a plain `export TOKENPACE_GH_AUTH=1` in `~/.zshrc` would
    /// be invisible via `ProcessInfo`. So check `ProcessInfo` first (terminal / `launchctl setenv`
    /// launches), then fall back to the login shell's rc files via `ShellEnvironment`. Run once and
    /// memoised in `ghAuthEnabled` — the shell probe is a subprocess, not something to repeat per poll.
    private static func resolveGHAuth() -> Bool {
        if let flag = ProcessInfo.processInfo.environment["TOKENPACE_GH_AUTH"], !flag.isEmpty {
            return true
        }
        if let flag = ShellEnvironment.value(for: "TOKENPACE_GH_AUTH"), !flag.isEmpty {
            AppLogger.lifecycle.notice("update: TOKENPACE_GH_AUTH found in login shell env")
            return true
        }
        return false
    }

    /// Surface a newly-found newer release: retain it (drives the menu click + Settings line), update
    /// the Settings window if open, then let the update menu item (`refreshUpdateMenuItem`) and the
    /// auto-installer (`evaluateAutoInstall`) react. There are **no** macOS notifications (#130 removed
    /// the banner) — the single dropdown item is the sole signal.
    ///
    /// A newer release also clears any stale `pendingWhatsNewVersion`: once a version past the
    /// installed build exists, "what's new" is superseded (the menu shows "New version available"
    /// instead — the pre-emption `UpdateMenuState` encodes).
    private func handleUpdateFound(_ release: GitHubRelease) {
        lastKnownRelease = release
        settingsWC?.updateAvailability(release)

        // A newer release supersedes an unseen "what's new" from an earlier auto-update.
        if PersistedConfig.pendingWhatsNewVersion != nil,
           UpdateComparison.isNewer(tag: release.tagName, than: TokenPaceKit.version) {
            PersistedConfig.pendingWhatsNewVersion = nil
            AppLogger.lifecycle.notice("update: cleared pending what's new (superseded by newer release)")
        }

        // Drop a stored install-failure record once it no longer denotes the newest known release
        // (#210) — a newer tag has appeared, so the About pane must not keep showing the old failure.
        // `lastFailedInstallVersion` is the source of truth the menu state reads; clearing the whole
        // `lastUpdateFailure` keeps the stage/reason in lockstep with it.
        if let failedTag = PersistedConfig.lastFailedInstallVersion,
           LastUpdateFailure.shouldClear(failedTag: failedTag, latestKnownTag: release.tagName) {
            PersistedConfig.lastUpdateFailure = nil
            AppLogger.lifecycle.notice("update: cleared stale install-failure record (superseded by newer release)")
        }

        let firstTimeSeen = PersistedConfig.lastSeenLatestVersion != release.tagName
        PersistedConfig.lastSeenLatestVersion = release.tagName
        AppLogger.lifecycle.notice(
            "update: new version available tag=\(release.tagName, privacy: .public) firstSeen=\(firstTimeSeen, privacy: .public)")

        evaluateAutoInstall(for: release)
        refreshUpdateMenuItem()
    }

    /// Decide whether to auto-install this release and, on a `.install` verdict, run the installer
    /// (#122–#124, ADR-0033). The pure `UpdateInstallPlan.decide` folds every gate (opt-in, newer, real
    /// `.app`, has asset, free space, AC power, unmetered) into one verdict; the log line names the
    /// outcome either way.
    ///
    /// The environment facts are read from the shell (`DiskSpace`, `PowerSource`,
    /// `NetworkMonitor.isMetered`) and injected into the pure plan — they gate *installation only*,
    /// never the lightweight update check (`pollUpdateIfDue`), which keeps running on the 12 h cadence
    /// regardless of disk/power/network.
    ///
    /// A **forced** run (a deliberate dry run via `TOKENPACE_UPDATE_DRYRUN`) bypasses the power/metered
    /// gates — the maintainer asked for it explicitly — but **not** the free-space gate (nothing makes
    /// it safe to fill the disk). The `defer…` verdicts are *temporary*: the next update heartbeat
    /// re-evaluates, so the install happens once conditions improve.
    ///
    /// On `.install` the installer downloads → verifies → unzips → (dry-run stop, or) atomically
    /// replaces the app bundle and relaunches. `deferInsufficientSpace`/`deferOnBattery`/
    /// `deferMeteredNetwork`/`skip…` only log; the signal path (banner/menu/Download) carries the
    /// update as a fallback.
    private func evaluateAutoInstall(for release: GitHubRelease) {
        let forced = ProcessInfo.processInfo.environment["TOKENPACE_UPDATE_DRYRUN"] == "1"
        let freeBytes = DiskSpace.availableBytes(forVolumeContaining: Bundle.main.bundleURL) ?? .max
        let decision = UpdateInstallPlan.decide(
            release: release,
            currentVersion: TokenPaceKit.version,
            isAppBundle: LaunchAtLoginController.isAppBundle,
            autoInstallEnabled: PersistedConfig.installUpdatesAutomatically,
            freeDiskBytes: freeBytes,
            onACPower: forced ? true : PowerSource.isOnACPower,
            networkIsMetered: forced ? false : network.isMetered)
        // A `defer…` verdict drives the blue "Update pending" menu item (#130); every other verdict
        // clears that flag. Set it before `refreshUpdateMenuItem` (called by the caller) reads it.
        switch decision {
        case .deferInsufficientSpace, .deferOnBattery, .deferMeteredNetwork:
            installDeferred = true
        default:
            installDeferred = false
        }

        switch decision {
        case let .install(asset, targetVersion):
            AppLogger.lifecycle.notice(
                "update-install: decision=install target=\(targetVersion, privacy: .public) asset=\(asset.name, privacy: .public)")
            startInstall(asset: asset, tag: targetVersion)
        case let .deferInsufficientSpace(_, targetVersion):
            AppLogger.lifecycle.notice(
                "update-install: decision=defer reason=insufficient-space target=\(targetVersion, privacy: .public)")
        case let .deferOnBattery(_, targetVersion):
            AppLogger.lifecycle.notice(
                "update-install: decision=defer reason=on-battery target=\(targetVersion, privacy: .public)")
        case let .deferMeteredNetwork(_, targetVersion):
            AppLogger.lifecycle.notice(
                "update-install: decision=defer reason=metered-network target=\(targetVersion, privacy: .public)")
        case .skipAutoInstallOff:
            AppLogger.lifecycle.notice("update-install: decision=skip reason=auto-install-off")
        case .skipNotNewer:
            AppLogger.lifecycle.notice("update-install: decision=skip reason=not-newer")
        case .skipNotAppBundle:
            AppLogger.lifecycle.notice("update-install: decision=skip reason=not-app-bundle")
        case .skipNoAsset:
            AppLogger.lifecycle.notice("update-install: decision=skip reason=no-asset")
        }
    }

    /// Run the installer for an `.install` verdict — a dry run under `TOKENPACE_UPDATE_DRYRUN`
    /// (download/verify/unzip, no replace), otherwise the real install (atomic replace + relaunch).
    /// Any failure logs and falls back to the single dropdown item (`refreshUpdateMenuItem`).
    /// Dispatched on `installTask` (cancelled before a new one / on terminate); because `AppDelegate`
    /// is `@MainActor`, the continuation after `await` is safe.
    ///
    /// **"What's new" is marked pending *before* the install runs** (#130): a real install ends by
    /// relaunching + terminating *inside* `install()`, so there is no code path after
    /// `.installedRelaunching` in which to persist it — it must already be on disk when the new build
    /// starts and shows the blue `whatsNew` item. On a failure the marker is cleared again (nothing was
    /// installed) and `lastFailedInstallVersion` is set so this exact tag is not retried — a newer tag
    /// still is. A dry run touches neither marker (nothing was really installed).
    private func startInstall(asset: GitHubReleaseAsset, tag: String) {
        installTask?.cancel()
        let dryRun = ProcessInfo.processInfo.environment["TOKENPACE_UPDATE_DRYRUN"] == "1"
        // Persist the pending "what's new" up front so it survives the imminent relaunch. Skip for a
        // dry run (no real install / relaunch happens).
        if !dryRun {
            PersistedConfig.pendingWhatsNewVersion = tag
            AppLogger.lifecycle.notice("update-install: what's new pending set tag=\(tag, privacy: .public)")
        }
        let installer = UpdateInstaller(ghAuthEnabled: ghAuthEnabled)
        installTask = Task { [weak self] in
            let outcome = await installer.install(asset, expectedTag: tag)
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case let .installedRelaunching(tag):
                // The installer requests the relaunch + terminate itself; just note it. The pending
                // "what's new" was already persisted above and will drive the post-restart menu item.
                AppLogger.lifecycle.notice("update-install: installed \(tag, privacy: .public), app will relaunch")
            case let .dryRunVerified(bundlePath):
                AppLogger.lifecycle.notice(
                    "update-install: dry-run complete, verified bundle at \(bundlePath, privacy: .public)")
            case .notApplicable, .downloadFailed, .verifyFailed, .unzipFailed, .replaceFailed:
                // Nothing was installed — undo the speculative "what's new", and (except for the inert
                // `notApplicable` dev-build case) record this failure so the tag is not retried and the
                // About pane can show *why* it failed (#210: tag + stage + reason).
                PersistedConfig.pendingWhatsNewVersion = nil
                if let failure = outcome.failure(tag: tag) {
                    PersistedConfig.lastUpdateFailure = failure
                    AppLogger.lifecycle.notice(
                        "update-install: last failed install set tag=\(tag, privacy: .public) stage=\(failure.stage.rawValue, privacy: .public)")
                }
                AppLogger.lifecycle.error(
                    "update-install: did not complete (\(String(describing: outcome), privacy: .public)) — signal item remains")
                self.refreshUpdateMenuItem()
            }
        }
    }

    /// Recompute the single update menu item (#130) from the current version/flags and apply it: a
    /// `.hidden` state hides the item **and** its separator (no dangling rule); any `shown` state
    /// reveals them with the matching dot colour + label. This is the one place the item's visibility
    /// is decided — called after every update check (both branches), after an install verdict/failure,
    /// after the auto-install toggle changes, and at launch (so a "what's new" left pending by a prior
    /// relaunch surfaces immediately).
    ///
    /// The pure `UpdateMenuState.evaluate` picks the winner; the colour + wording live here (the view
    /// side, per ADR-0009/0013), reusing the popup's `dotColor` so the update dot matches the
    /// service-status dots exactly.
    private func refreshUpdateMenuItem() {
        // `TOKENPACE_UPDATE_STATE=failed|available|pending|whatsnew` forces the item to a given state
        // for live verification (#130), without writing anything to the real UserDefaults — a
        // maintainer aid like `TOKENPACE_STUB`/`TOKENPACE_FAKE_LATEST`, never set in normal use.
        let item = Self.forcedUpdateItem
            ?? UpdateMenuState.evaluate(
                installedVersion: TokenPaceKit.version,
                latestKnownVersion: lastKnownRelease?.tagName,
                autoInstallEnabled: PersistedConfig.installUpdatesAutomatically,
                installDeferred: installDeferred,
                lastFailedInstallVersion: PersistedConfig.lastFailedInstallVersion,
                pendingWhatsNewVersion: PersistedConfig.pendingWhatsNewVersion)
        currentUpdateItem = item

        if item == .hidden {
            updateSeparatorItem?.isHidden = true
            updateAvailableItem?.isHidden = true
            return
        }
        updateSeparatorItem?.isHidden = false
        updateAvailableItem?.isHidden = false
        updateAvailableItem?.attributedTitle = Self.updateItemTitle(for: item)
        AppLogger.lifecycle.notice("update: menu item = \(String(describing: item), privacy: .public)")
    }

    /// Handle a click on the update menu item (#130, #210) — the click target is now **Settings →
    /// About**, not the GitHub releases page in a browser. About surfaces the update state (available /
    /// failed with stage + reason) and keeps the "Download" / release-notes links in-pane, so a single
    /// destination carries every signal. If the item was the `whatsNew` state, opening it acknowledges
    /// the update: clear `pendingWhatsNewVersion` and recompute the item so it disappears.
    @objc private func openReleasesPage() {
        AppLogger.lifecycle.notice("update: user opened About from update item (item=\(String(describing: self.currentUpdateItem), privacy: .public))")
        openSettings(section: .about)
        if currentUpdateItem == .whatsNew {
            PersistedConfig.pendingWhatsNewVersion = nil
            AppLogger.lifecycle.notice("update: cleared pending what's new (user opened it)")
            refreshUpdateMenuItem()
        }
    }

    /// The update menu item's title for `item` (#130): a `circle.fill` dot tinted to the item's
    /// severity (reusing `PopupViewController.dotColor` so it matches the popup's service dots) followed
    /// by the label at `dropdownTextSize`, so it reads like the other native items. The dot is nudged
    /// up to sit on the text's optical centre (`Self.dotAttachment`), same as the popup rows.
    private static func updateItemTitle(for item: UpdateMenuState.Item) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        if let attachment = PopupViewController.dotAttachment(
            color: dotColor(for: item), accessibility: "update") {
            attributed.append(NSAttributedString(attachment: attachment))
            attributed.append(NSAttributedString(string: "  "))
        }
        attributed.append(NSAttributedString(
            string: label(for: item),
            attributes: [.font: NSFont.systemFont(ofSize: dropdownTextSize)]))
        return attributed
    }

    /// The dropdown label for each visible update state (#130). `hidden` never renders a title, so it
    /// falls back to an empty string.
    private static func label(for item: UpdateMenuState.Item) -> String {
        switch item {
        case .hidden:          return ""
        case .updateFailed:    return "New version available (update failed)…"
        case .updateAvailable: return "New version available…"
        case .updatePending:   return "Update pending…"
        case .whatsNew:        return "What's new in the version…"
        }
    }

    /// The dot colour for each update state (#130), taken from the popup's service-status palette so
    /// the update dot uses the **same** colours as the status dots (issue #130): red for a failed
    /// install, blue for every other signal. `hidden` is never drawn; it maps to blue harmlessly.
    private static func dotColor(for item: UpdateMenuState.Item) -> NSColor {
        switch item {
        case .updateFailed: return PopupViewController.dotColor(.majorOutage)     // red
        default:            return PopupViewController.dotColor(.underMaintenance) // blue
        }
    }

    /// Re-render the retained last poll against the current time — grows the "Last update" age and
    /// advances the menu bar's stale thresholds. No-op before the first poll. **Never fetches.**
    private func reRenderForCurrentTime() {
        guard let output = lastOutput else { return }
        render(output, at: currentDate())
    }

    /// Bring the awaiting-input watcher in line with the current feature state (#233). Creates the
    /// watcher lazily when the master toggle is on and drives it via `setActive`; tears it down when
    /// off. Called at launch and whenever the toggle flips.
    ///
    /// The `TOKENPACE_AWAITING` stub short-circuits the watcher entirely — the forced count is read
    /// directly by `awaitingInputForDisplay`, so there's nothing to watch.
    ///
    /// A data stub also short-circuits it: on any scenario but `.realNetwork` the watcher stays down,
    /// mirroring the journal's `currentScenario == .realNetwork` gate. A stub is meant to be a frozen,
    /// reproducible frame, but the watcher reads the *live* `~/.claude` trees — so a screenshot run
    /// would show whatever real sessions happen to be waiting right then. `TOKENPACE_AWAITING=N` stays
    /// the way to exercise the indicator under a stub, with synthetic sessions instead of live ones.
    private func updateAwaitingInputWatcher() {
        let wantWatcher = PersistedConfig.awaitingInputEnabled
            && awaitingInputStub == nil
            && currentScenario == .realNetwork
        guard wantWatcher else {
            awaitingInputWatcher?.setActive(false)
            awaitingInputWatcher = nil
            awaitingInput = .none
            return
        }
        if awaitingInputWatcher == nil {
            let watcher = AwaitingInputWatcher(onResultChanged: { [weak self] result in
                guard let self else { return }
                self.awaitingInput = result
                self.reRenderForCurrentTime()
            })
            awaitingInputWatcher = watcher
        }
        // Active whenever the feature is on. FSEvents makes this cheap; a finer gate (pause while the
        // screen is locked / Claude isn't running, mirroring #114) can be layered on later by calling
        // `setActive(false/true)` from the lock and claude-activity signals — the watcher supports it.
        awaitingInputWatcher?.setActive(true)
    }

    /// Render a poll result into the menu-bar image and popup model at instant `now`.
    private func render(_ output: PollOutput, at now: Date) {
        // Roll any window whose reset boundary has already passed forward to its next window *before*
        // formatting, so a countdown never computes `remaining <= 0` (which used to surface the removed
        // `.resetNow` state). The exact `resetTimer` normally fires the roll-forward at the boundary
        // (`fireOptimisticReset`), but a render driven by another timer (the 30 s `ageTimer`, a poll
        // tick) can land in the sub-second gap before it fires — so we apply the same pure overlay here
        // on every render. It is a no-op when nothing has crossed a boundary, and the next authoritative
        // poll overwrites it wholesale (the API stays the source of truth). See ADR-0043.
        let snapshot = output.snapshot.map { ResetClock.optimisticReset($0, now: now) }
        // #233: the awaiting-input count is `nil` (hidden) unless the feature is on and ≥ 1 session is
        // waiting. Sourced from the watcher (or the `TOKENPACE_AWAITING` stub), independent of the poll.
        let awaitingInput = awaitingInputForDisplay
        statusView?.layout = MenuBarLayout.make(
            from: snapshot, health: output.health, now: now,
            // #31: honour the "Show service status dot" toggle — nil hides the dot and reclaims its width.
            serviceProblem: PersistedConfig.showServiceStatusDot ? lastStatusHealth?.worstProblem : nil,
            resetMode: PersistedConfig.resetCountdownModeMenuBar,   // #103: which reset countdown to show
            // #94: honour the "Hide 7-day bar when calm" toggle — drops a calm 7-day bar, centring 5h.
            hideCalmSevenDay: PersistedConfig.hideCalmSevenDayBar,
            // #144: honour the "Show extra-usage credits" toggle — draws the ¤ icon when credits are
            // active and a base limit is exhausted; false hides it and reclaims its width.
            showCredits: PersistedConfig.showExtraUsage,
            // #194, #227: honour the "Pause icon hides bars" toggle — when fully blocked (isBlocked), true
            // drops both bars for a countdown-only widget beside the red pause icon; false keeps the (red)
            // bars beside it. The pause icon itself is drawn whenever blocked, independent of this flag.
            pauseHidesBars: PersistedConfig.pauseHidesBars,
            // "Far behind" interval: the user's green→blue crossover scale (off→0/no-blue, short→1,
            // medium→2, long→3). `nil` (off) maps to 0.
            behindMultiplier: PersistedConfig.farBehindInterval.multiplier ?? 0)
            .withAwaitingInput(awaitingInput)   // #233: graft the awaiting-input indicator (trailing)
        refreshStatusImage()   // the menu-bar image is snapshotted, not auto-rendered, on layout change
        setPopupLayout(PopupLayout.make(
            from: snapshot, health: output.health, now: now, interval: output.interval,
            serviceStatus: lastStatusHealth,
            // #211: honour the "Show model-specific limits" toggle — false drops the per-model rows
            // (Opus/Sonnet/scoped), leaving only 5h/7d in the popup.
            showModelSpecificLimits: PersistedConfig.showModelSpecificLimits,
            // "Far behind" interval: the user's green→blue crossover scale (off→0/no-blue, short→1,
            // medium→2, long→3). `nil` (off) maps to 0.
            behindMultiplier: PersistedConfig.farBehindInterval.multiplier ?? 0)
            .withAwaitingInput(awaitingInput)   // #233: graft the awaiting-input indicator (right of brand)
            // Graft the brand-coloured plan label ("Max 5x") from the Keychain rate-limit tier — a
            // plan mark, not a secret. `nil` (no tier / unreadable creds) draws just "Claude".
            .withPlanLabel(claudePlanLabel(rateLimitTier: output.diagnostics?.token?.rateLimitTier)))
    }

    /// Set the popup model **and** resize the hosted view to fit. A menu item's hosted view must
    /// carry a concrete non-zero frame — `NSMenu` lays the item out from `frame`, not Auto Layout —
    /// and it does **not** re-measure when the content rebuilds. So every layout change (cold start
    /// *and* each live poll) must re-fit the frame, otherwise sections added later (e.g. the bars +
    /// their labels once the first snapshot lands) are clipped to the older, smaller frame — leaving
    /// the fixed-width bars visible but the intrinsic-width text rows cut off.
    private func setPopupLayout(_ layout: PopupLayout) {
        popupVC.layout = layout
        popupVC.view.frame = NSRect(origin: .zero, size: popupVC.view.fittingSize)
        devToolsWC?.updatePreview(layout)   // mirror into the dev colour tuner's live popup preview (#185)
    }

    // MARK: - Menu-bar image

    /// Re-render the menu-bar image and resize the item to fit. Called at launch, on every poll (when the
    /// *data* changes), and on a theme flip (via the `effectiveAppearance` KVO). The image is a single
    /// non-template `NSImage` drawn in the button's current appearance, so its semantic colours resolve to
    /// the right light/dark value; the KVO re-snapshots it when the bar flips (non-template does not
    /// re-resolve on its own).
    private func refreshStatusImage() {
        guard let button = statusItem?.button, let view = statusView else { return }
        var image: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance { image = view.snapshotImage() }
        guard let image else { return }
        button.image = image
        statusItem?.length = image.size.width
    }
}

// MARK: - NSMenuDelegate: ⌥ Option swap (ADR-0020)

extension AppDelegate: NSMenuDelegate {

    /// While the dropdown is open, poll ⌥ Option and reveal/hide the Troubleshoot item live. The
    /// native `isAlternate` mechanism is inert in a status-item menu, and an event monitor is starved
    /// by menu tracking (verified), so a modifier-polling timer drives the reveal instead. Seed
    /// visibility from the modifiers already held at open time (the user may open the menu with ⌥ down).
    func menuWillOpen(_ menu: NSMenu) {
        // Seed visibility from the modifiers held at open time. Force the first sync by desyncing
        // `lastOptionHeld`.
        lastOptionHeld = !NSEvent.modifierFlags.contains(.option)
        updateTroubleshootVisibility(NSEvent.modifierFlags.contains(.option))
        // Poll the live modifier state while the menu tracks. Added in `.common` modes so it fires
        // during the modal `NSEventTrackingRunLoopMode` (a timer in `.default` — like an event
        // monitor — would be starved by menu tracking). The fire runs on the main run loop, so the
        // main-actor hop is a known-safe assumption (mirrors `ageTimer`).
        optionPollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTroubleshootVisibility(NSEvent.modifierFlags.contains(.option)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        optionPollTimer = timer
    }

    /// Stop the poll and hide the Troubleshoot item again, so the next open starts clean (and no
    /// timer leaks between openings).
    func menuDidClose(_ menu: NSMenu) {
        optionPollTimer?.invalidate()
        optionPollTimer = nil
        lastOptionHeld = true            // force the reset below to apply
        updateTroubleshootVisibility(false)
    }
}
