import AppKit
import TokenPaceKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu-bar item. Held strongly for the process lifetime — releasing it removes the item.
    private var statusItem: NSStatusItem?

    /// The custom view that renders the menu-bar image. Held so the image can be re-snapshotted when
    /// the menu-bar appearance changes (Dark ↔ Light).
    private var statusView: StatusItemView?

    /// KVO token for the button's `effectiveAppearance`, so the non-template image's semantic
    /// colours (idle glyph / reset label) track the menu-bar theme.
    private var appearanceObservation: NSKeyValueObservation?

    /// The detail popup's content controller (issue #11). Hosted inside a menu item so the popup
    /// gets the native menu-bar look — a rounded panel with **no arrow**, and the status button is
    /// highlighted while it is open (both come free with `NSMenu`, unlike `NSPopover`).
    private let popupVC = PopupViewController()

    /// The "Settings…" window (#14), created lazily on first use and kept alive so a
    /// second click focuses the existing window rather than opening a duplicate (single-instance).
    private var settingsWC: SettingsWindowController?

    /// The hidden Troubleshoot window (ADR-0020), reached via ⌥ Option on "Settings…". Lazily
    /// created and kept alive; while open it re-renders on every poll (see `apply(_:)`).
    private var troubleshootWC: TroubleshootWindowController?

    /// The optional "Troubleshoot…" item (ADR-0020), hidden by default and revealed **below** the
    /// always-visible "Settings…" while ⌥ Option is held. `NSMenuItem.isHidden` is flipped live by
    /// `updateTroubleshootVisibility(_:)`, driven by `optionPollTimer` — the native `isAlternate`
    /// swap does not work in a status-item menu. "Settings…" is a plain, always-shown item beside it.
    private var troubleshootItem: NSMenuItem?

    /// The opaque overlay inserted into the menu window's background view to make the *whole* dropdown
    /// solid (issue #86). Weak: the menu window owns it, and it is torn down when the menu closes. Held
    /// only so a re-open can clear a stale one defensively.
    private weak var opaqueMenuBackdrop: NSView?


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

    /// The active `TOKENPACE_STUB` mode name (`"1"`/`"screenshot"`/`"error"`), or `nil` for a normal
    /// run against the real network. One source of truth read from the environment, so the Quit
    /// item's dev-build tag and `startPolling`'s transport wiring agree on which mode is live.
    private static let stubName = ProcessInfo.processInfo.environment["TOKENPACE_STUB"]

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

        // Load the persisted monitored-services choice (#89) before the first status poll, so it
        // resolves the right logical services from the start. Falls back to `.default` when absent.
        monitoredServices = PersistedConfig.monitoredServices

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Cold start: no data yet — render the structure (idle/empty), not fake bars. The first
        // poll replaces this within a moment.
        let now = Date()
        let coldHealth = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil)
        let view = StatusItemView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 22)))
        view.layout = MenuBarLayout.make(from: nil, health: coldHealth, now: now)
        view.calmColors = PersistedConfig.calmMenuBarColors   // apply the saved choice from launch (#105)
        self.statusView = view
        self.statusItem = item

        // Hand the button a ready non-template image. (Hosting the custom NSView as a button
        // subview is unreliable — the system button paints over it; see StatusItemView.snapshotImage.)
        refreshStatusImage()

        // The image is non-template, so macOS won't re-tint it when the menu-bar theme flips;
        // re-snapshot in the new appearance ourselves (otherwise the reset label / idle glyph,
        // drawn in labelColor, stay the wrong shade — e.g. dark text on a dark menu bar).
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshStatusImage() }
        }

        popupVC.loadView()   // realise the view so it can be sized before the menu measures it
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

        // Action items at the bottom of the same menu (#14). `keyEquivalent: ""` keeps a shortcut
        // glyph off the right edge — none is wanted, and there is no main menu to host a default ⌘Q.
        menu.addItem(.separator())
        // "Settings…" is always visible. Directly below it sits the optional "Troubleshoot…" item
        // (ADR-0020), hidden by default and revealed only while ⌥ Option is held. The native
        // `isAlternate` mechanism does NOT work in a status-item menu, so the reveal is driven by a
        // modifier-polling timer set in `menuWillOpen` — see `updateTroubleshootVisibility(_:)`. Each
        // item carries its own fixed selector; empty keyEquivalent keeps the menu glyph-free.
        let settingsItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.attributedTitle = Self.dropdownMenuItemText("Settings…")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let troubleshootItem = NSMenuItem(title: "", action: #selector(openTroubleshoot), keyEquivalent: "")
        troubleshootItem.attributedTitle = Self.dropdownMenuItemText("Troubleshoot…")
        troubleshootItem.target = self
        troubleshootItem.isHidden = true
        menu.addItem(troubleshootItem)
        self.troubleshootItem = troubleshootItem

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
        // macOS menu grouping). A bare `swift run` binary is tagged "(dev build)" (#69) so quitting
        // the right process is unambiguous when a dev build and the installed `.app` run side by
        // side; under a stub the mode is named too — "(dev build – error)" — so a stubbed run reads
        // apart from a plain dev build at a glance.
        menu.addItem(.separator())
        let quitTitle: String
        if LaunchAtLoginController.isAppBundle {
            quitTitle = "Quit TokenPace"
        } else if let stub = Self.stubName {
            quitTitle = "Quit TokenPace (dev build – \(stub))"
        } else {
            quitTitle = "Quit TokenPace (dev build)"
        }
        let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "")
        quitItem.attributedTitle = Self.dropdownMenuItemText(quitTitle)
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu

        startPolling()

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
    }

    // MARK: - Menu actions (#14)

    /// Open (or focus) the Settings… window. Lazily creates the single instance and wires the
    /// monitored-services change callback (#89) so a toggle there re-polls the status immediately.
    @objc private func openSettings() {
        if settingsWC == nil {
            let wc = SettingsWindowController()
            wc.onMonitoredServicesChange = { [weak self] config in self?.monitoredServicesChanged(config) }
            wc.onCheckForUpdatesNow = { [weak self] in self?.performUpdateCheck(userInitiated: true) }
            wc.onCalmColorsChange = { [weak self] on in
                self?.statusView?.calmColors = on
                self?.refreshStatusImage()   // menu-bar image is snapshotted, not auto-rendered
            }
            wc.onResetCountdownModeMenuBarChange = { [weak self] _ in
                // The mode changes the layout (which countdown to draw), not just a colour — rebuild
                // the menu-bar layout from the last poll (render reads PersistedConfig for the mode).
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
            wc.onHideCalmSevenDayChange = { [weak self] _ in
                // Toggling this changes the layout (7-day bar drawn or not, 5h vertical centring),
                // not just a colour — rebuild from the last poll (render reads PersistedConfig).
                self?.reRenderForCurrentTime()
            }
            wc.onPausePollingChange = { [weak self] on in
                // Turning the pause OFF must un-stick a loop already parked by a screen lock: send a
                // `.wake` so it resumes immediately. Turning it ON changes nothing now — the next lock
                // will park it (the observer reads the pref live). No render impact either way.
                if !on { self?.signals.send(.wake) }
            }
            wc.onArchiveNow = { [weak self] in self?.performArchiveSync(userInitiated: true) }
            wc.archiveSummaryProvider = { [weak self] in self?.lastArchiveSummary }
            wc.onBackToWorkEnabled = { completion in
                // Lazily request notification authorization the first time the user enables the
                // feature (#160) — never at launch, since this is opt-in.
                BackToWorkNotifier.requestAuthorizationIfNeeded(completion: completion)
            }
            settingsWC = wc
        }
        // Reflect the latest known update state whenever the window opens (#37).
        settingsWC?.updateAvailability(lastKnownRelease)
        settingsWC?.show()
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
            rescheduleResetTimer(from: lastOutput?.snapshot, now: Date())
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
        let now = Date()
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

        // TOKENPACE_STUB swaps the live URLSession for a canned-response transport so the app can be
        // driven end-to-end (popup text, interval logs) without touching the usage API. Verification
        // aid only — never set in normal use; the default path is the real network.
        //  • `=1`          → climbing utilisation (exercises adaptive cadence on screen).
        //  • `=screenshot` → frozen, hand-picked values (a stable frame for the README).
        //  • `=error`      → 401 auth failure + both Claude services degraded (the warning block).
        //  • `=idle`       → the honest "no active 5h session" state (#100): solid-blue 5h bar, no
        //                    phantom reset, menu-bar time falls back to the 7-day reset ("4d").
        //  • `=idle-blocked` → the **blocked** idle state (#158): idle 5h + 7-day exhausted (100 %) and
        //                    no credits → the idle bar goes **grey** (menu bar + popup, both colour
        //                    modes), the popup status reads "waiting for limit reset", and the 7-day
        //                    reset time is painted **red** (the blocking reset). Compare against `=idle`.
        //  • `=active-blocked` → the **active** blocked state (#177): a live 5h window (48 %) while 7-day
        //                    is exhausted (100 %, `weekly_all` critical) and no credits. Not idle → the 5h
        //                    row is a normal "on pace" row, but the popup's 7-day reset gets the **red**
        //                    blocking-reset badge. Before the fix no badge showed (Артем's bug).
        //  • `=optimistic-reset` → the reset-boundary flow (#36): the 5h window resets ~20 s after
        //                    launch, so the bar flips 60 % → 0 % (no ⏰) and a forced refresh follows.
        //  • `=broken-reset` → a noisy 5h (100 %) with `resets_at: null` (#167): an API data error on
        //                    the chosen window → the menu bar shows the ⚠️ error state (glyph + bars),
        //                    not a fabricated "<1m". The 7-day window is calm with a valid reset.
        //  • `=5h-orange` / `both-orange` / `both-red` / `red-orange` / `calm5-orange7`
        //                  → fixed 5h×7d severity frames for the reset-countdown table (#103).
        //                    `calm5-orange7` is the lone days-away 7d-orange cell where the reset-
        //                    countdown mode (smart vs never) changes what's shown.
        //  • `=calm-both`  → both bars calm (5h green + 7d green): with the default "Hide 7-day bar
        //                    when calm" (#94) on, the 7-day bar is dropped and a lone green 5h bar
        //                    sits centred (no reset text — both calm). Turn the toggle off to see
        //                    both bars again.
        //  • `=calm-degraded` → calm bars + a **degraded (yellow)** service dot: with "Calm colours"
        //                    (#105) off the dot is yellow; turn Calm on (Settings → General) and it
        //                    mutes to white alongside the bars. The frame that verifies #… .
        //  • `=credits-active` / `credits-limit-reached` / `credits-no-limit` (#144)
        //                  → the trailing money-credits ¤ icon. All three pin the 7-day window at
        //                    100 % (a base limit exhausted → the icon shows) and vary `spend`:
        //                    `credits-active` = enabled €15 limit, €10.77 spent (paced colour);
        //                    `credits-limit-reached` = spend_limit_reached (RED icon);
        //                    `credits-no-limit` = unlimited limit (NEUTRAL icon). Toggle "Calm
        //                    colours" to see the calm frames (active/no-limit) mute to white.
        let stubMode = Self.stubName
        let transport: UsageTransport = switch stubMode {
        case "1":          StubUsageTransport(mode: .climbing)
        case "screenshot": StubUsageTransport(mode: .screenshot)
        case "error":      StubUsageTransport(mode: .authError)
        case "idle":       StubUsageTransport(mode: .idle)
        case "idle-blocked": StubUsageTransport(mode: .idleBlocked)
        case "active-blocked": StubUsageTransport(mode: .activeBlocked)
        case "optimistic-reset": StubUsageTransport(mode: .optimisticReset)
        // Broken-`resets_at` (#167): noisy 5h with `resets_at: null` → ⚠️ error state, not a fake "<1m".
        case "broken-reset": StubUsageTransport(mode: .brokenReset)
        // Reset-countdown (#103) verification frames: fixed 5h×7d severities to exercise the table.
        case "5h-orange":   StubUsageTransport(mode: .pacing(.fiveOrange))
        case "both-orange": StubUsageTransport(mode: .pacing(.bothOrange))
        case "both-red":    StubUsageTransport(mode: .pacing(.bothRed))
        case "red-orange":  StubUsageTransport(mode: .pacing(.redOrange))
        case "red-green":   StubUsageTransport(mode: .pacing(.redGreen))
        case "calm5-orange7": StubUsageTransport(mode: .pacing(.calmFiveOrangeSeven))
        // 20-min override (ADR-0044): 5h ahead only ~2 pts but resets in 12 min → forced orange.
        case "near-reset":  StubUsageTransport(mode: .pacing(.nearResetFiveHour))
        // Both-calm frame (#94): exercises the "Hide 7-day bar when calm" opt-out (lone centred 5h).
        case "calm-both":  StubUsageTransport(mode: .pacing(.calmBoth))
        // Calm bars + degraded (yellow) service dot: verifies calm colours muting the dot (#…).
        case "calm-degraded": StubUsageTransport(mode: .calmDegraded)
        // Money-credits icon (#144): three frames for the trailing ¤ icon. Each pins the 7-day window
        // at 100 % (a base limit exhausted, so the icon's show-trigger fires) and differs in `spend`:
        //  • `credits-active`        → enabled, €15 limit, €10.77 spent (~72 %) → paced icon colour.
        //  • `credits-limit-reached` → spend_limit_reached (€5 limit below €10.77 spent) → RED icon.
        //  • `credits-no-limit`      → enabled, unlimited (limit: null) → NEUTRAL (foreground) icon.
        case "credits-active":        StubUsageTransport(mode: .credits(.active))
        case "credits-limit-reached": StubUsageTransport(mode: .credits(.limitReached))
        case "credits-no-limit":      StubUsageTransport(mode: .credits(.noLimit))
        // Back-to-work edge (#160): first poll blocked (7d 100 %), then workable → fires the
        // "Back to work!" notification once, subject to quiet hours + authorization.
        case "just-unblocked":        StubUsageTransport(mode: .justUnblocked)
        // Reset-boundary idle grace (ADR-0041): active → post-reset empty five_hour → active again.
        // The 5h bar must stay "ready" (non-idle) across the empty polls — no "waiting for limit
        // reset" flicker between the active windows.
        case "reset-grace":           StubUsageTransport(mode: .resetGrace)
        default:           URLSession.shared
        }
        // The status poll uses the same transport seam (the stub answers the status endpoint too).
        statusTransport = transport
        // Under the stub the bearer token is never validated (canned responses), so skip the
        // Keychain entirely — reading it would only pop the system access prompt on a dev build.
        // The refresher is live-only for the same reason: a stub run must never spawn the CLI.
        let tokenProvider: TokenProviding = stubMode == nil ? KeychainTokenProvider() : StubTokenProvider()
        let refresher: DelegatedRefresher? = stubMode == nil ? ClaudeCLIRefresher() : nil
        let engine = PollingEngine(
            transport: transport,
            tokenProvider: tokenProvider,
            refresher: refresher,
            scheduler: LivePollScheduler(signals: signals.stream),
            probe: ProcessClaudeActivityProbe(),
            now: { Date() })

        // Consume on the main actor — every PollOutput drives the menu bar + popup.
        pollTask = Task { [weak self] in
            for await output in engine.run() {
                guard let self else { break }
                self.apply(output)
            }
        }

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

    /// Map one poll result into the menu-bar image and the popup model, and retain it so the age
    /// timer can re-render it against a later `now`. Also rides this heartbeat to poll the Claude
    /// status page when due (#31) — no separate timer.
    private func apply(_ output: PollOutput) {
        detectBackToWorkEdge(output)
        lastOutput = output
        render(output, at: Date())
        // Re-arm the optimistic-reset timer against this poll's `resets_at` (#36). A successful poll
        // fully overwrites any prior optimistic overlay; a 429/error poll carries the stale last-known
        // snapshot, so rescheduling is a harmless no-op (same instant).
        rescheduleResetTimer(from: output.snapshot, now: Date())
        // Live-update an open Troubleshoot window: both sections (JSON, timestamps, next update,
        // token dates) refresh in place each poll (ADR-0020). No-op while the controller is nil.
        troubleshootWC?.render(output)
        pollStatusIfDue(usageInterval: output.interval)
        pollUpdateIfDue()
        pollArchiveIfDue()
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = .current
        let allowed = NotificationSchedule.isAllowed(
            at: Date(),
            window: (PersistedConfig.notifyWindowStartMinute, PersistedConfig.notifyWindowEndMinute),
            suppress: PersistedConfig.notifySuppressDays,
            calendar: calendar
        )
        guard allowed else {
            AppLogger.lifecycle.info("back-to-work: suppressed by quiet hours")
            return
        }
        BackToWorkNotifier.postBackToWork()
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
            do {
                let summary = try await StatusClient.fetch(transport: transport)
                health = .from(summary, config: config)
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
                // `notApplicable` dev-build case) mark this tag failed so it is not retried.
                PersistedConfig.pendingWhatsNewVersion = nil
                if outcome != .notApplicable {
                    PersistedConfig.lastFailedInstallVersion = tag
                    AppLogger.lifecycle.notice(
                        "update-install: last failed install version set tag=\(tag, privacy: .public)")
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

    /// Open the releases page from the update menu item (#130) — the click target is **always** the
    /// releases index (there is no in-app release-notes render). If the item was the `whatsNew` state,
    /// opening it acknowledges the update: clear `pendingWhatsNewVersion` and recompute the item so it
    /// disappears.
    @objc private func openReleasesPage() {
        AppLogger.lifecycle.notice("update: user opened releases page (item=\(String(describing: self.currentUpdateItem), privacy: .public))")
        NSWorkspace.shared.open(GitHubReleaseClient.releasesPageURL)
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
        render(output, at: Date())
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
        statusView?.layout = MenuBarLayout.make(
            from: snapshot, health: output.health, now: now,
            // #31: honour the "Show service status dot" toggle — nil hides the dot and reclaims its width.
            serviceProblem: PersistedConfig.showServiceStatusDot ? lastStatusHealth?.worstProblem : nil,
            resetMode: PersistedConfig.resetCountdownModeMenuBar,   // #103: which reset countdown to show
            // #94: honour the "Hide 7-day bar when calm" toggle — drops a calm 7-day bar, centring 5h.
            hideCalmSevenDay: PersistedConfig.hideCalmSevenDayBar,
            // #144: honour the "Show extra-usage credits" toggle — draws the trailing ¤ icon when
            // credits are active and a base limit is exhausted; false hides it and reclaims its width.
            showCredits: PersistedConfig.showExtraUsage)
        refreshStatusImage()   // the menu-bar image is snapshotted, not auto-rendered, on layout change
        setPopupLayout(PopupLayout.make(
            from: snapshot, health: output.health, now: now, interval: output.interval,
            serviceStatus: lastStatusHealth))
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
    }

    // MARK: - Menu-bar image

    /// Re-render the menu-bar image in the button's current appearance and resize the item to fit.
    /// Called at launch, on every poll, and whenever the menu-bar theme changes.
    private func refreshStatusImage() {
        guard let button = statusItem?.button, let view = statusView else { return }
        let image = view.snapshotImage(appearance: button.effectiveAppearance)
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

        // Make the WHOLE dropdown solid — including the native Settings/Quit items — not just our bar
        // section. The menu window mounts after menuWillOpen, so defer to the next runloop turn (mirrors
        // the ⌥-poll timing).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.installOpaqueMenuBackdropIfNeeded() }
        }
    }

    /// Make the entire dropdown opaque by inserting an opaque overlay into the menu window's background
    /// view — covering the native Settings/Quit items that our own `PopupViewController` backdrop cannot
    /// reach (issue #86).
    ///
    /// **Fragile — leans on `NSMenu`'s private view hierarchy.** Probed on macOS 15: the dropdown lives
    /// in an `NSPopupMenuWindow` whose `contentView` is an `NSRootMenuWindowBackgroundView`; the window
    /// is already `isOpaque`, and the see-through look is that background view's translucent system
    /// material. We drop a `SolidBackdropView` (opaque, appearance-aware) as its **bottom-most** subview
    /// (below the `NSMenuScrollView` that hosts the items), so the whole panel reads solid. If a future
    /// macOS renames/reshapes this hierarchy the guard simply finds nothing and no-ops — the popup's own
    /// backdrop still covers the bar section, so this degrades gracefully rather than breaking.
    private func installOpaqueMenuBackdropIfNeeded() {
        opaqueMenuBackdrop?.removeFromSuperview()
        opaqueMenuBackdrop = nil
        guard let bg = popupVC.view.window?.contentView else { return }
        let overlay = SolidBackdropView(frame: bg.bounds)
        overlay.autoresizingMask = [.width, .height]
        bg.addSubview(overlay, positioned: .below, relativeTo: bg.subviews.first)
        opaqueMenuBackdrop = overlay
    }

    /// Stop the poll and hide the Troubleshoot item again, so the next open starts clean (and no
    /// timer leaks between openings). Also tear down the whole-dropdown opaque overlay.
    func menuDidClose(_ menu: NSMenu) {
        optionPollTimer?.invalidate()
        optionPollTimer = nil
        lastOptionHeld = true            // force the reset below to apply
        updateTroubleshootVisibility(false)
        // Tear down the whole-dropdown opaque overlay (issue #86); the menu window is going away, but
        // clear it explicitly so a re-open never reuses a stale one.
        opaqueMenuBackdrop?.removeFromSuperview()
        opaqueMenuBackdrop = nil
    }
}
