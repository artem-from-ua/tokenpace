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

    /// The "New version available" menu item (blue-dot indicator), sitting just above Quit behind its
    /// own separator. Hidden until a check finds a newer release; `isHidden` is flipped in
    /// `handleUpdateFound` / `performUpdateCheck` via `setUpdateItemVisible`.
    private var updateAvailableItem: NSMenuItem?
    /// The separator above ``updateAvailableItem``, hidden/shown in lockstep with it so an absent
    /// update leaves no dangling rule above Quit.
    private var updateSeparatorItem: NSMenuItem?
    /// The newest release found so far, or `nil` if none/up-to-date. Drives the menu click target and
    /// the Configure… "Update available" line.
    private var lastKnownRelease: GitHubRelease?
    /// The in-flight update fetch, if any — cancelled before a new check and on terminate.
    private var updateTask: Task<Void, Never>?
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
        // dot to draw the eye (same tinted `circle.fill` attachment the popup uses for service dots).
        // Both the separator and the item are hidden until a check finds a newer release, so an absent
        // update leaves no dangling rule; click opens the releases page. Visibility is flipped by
        // `setUpdateItemVisible` from `handleUpdateFound` / `performUpdateCheck`.
        let updateSeparator = NSMenuItem.separator()
        updateSeparator.isHidden = true
        menu.addItem(updateSeparator)
        self.updateSeparatorItem = updateSeparator

        let updateItem = NSMenuItem(title: "", action: #selector(openReleasesPage), keyEquivalent: "")
        updateItem.attributedTitle = Self.updateItemTitle()
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

        // Update check (#37): install the notification delegate before any banner can arrive, and —
        // when automatic checks are on — request notification authorization once. Both no-op outside
        // a real `.app` bundle.
        UpdateNotifier.installDelegate()
        if PersistedConfig.automaticUpdateChecks {
            UpdateNotifier.requestAuthorizationIfNeeded()
            // Always check once on launch, bypassing the 12 h cadence: a build the user just
            // installed/relaunched should surface a pending update immediately, not up to half a day
            // later. The cadence still governs re-checks during a long-running session
            // (`pollUpdateIfDue`).
            performUpdateCheck(userInitiated: false)
        }

        AppLogger.lifecycle.info(
            "TokenPace status item attached (\(TokenPaceKit.version, privacy: .public)); live polling started"
        )
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
            wc.onPausePollingChange = { [weak self] on in
                // Turning the pause OFF must un-stick a loop already parked by a screen lock: send a
                // `.wake` so it resumes immediately. Turning it ON changes nothing now — the next lock
                // will park it (the observer reads the pref live). No render impact either way.
                if !on { self?.signals.send(.wake) }
            }
            wc.onArchiveNow = { [weak self] in self?.performArchiveSync(userInitiated: true) }
            wc.archiveSummaryProvider = { [weak self] in self?.lastArchiveSummary }
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
        //  • `=optimistic-reset` → the reset-boundary flow (#36): the 5h window resets ~20 s after
        //                    launch, so the bar flips 60 % → 0 % (no ⏰) and a forced refresh follows.
        //  • `=5h-orange` / `both-orange` / `both-red` / `red-orange` / `calm5-orange7`
        //                  → fixed 5h×7d severity frames for the reset-countdown table (#103).
        //                    `calm5-orange7` is the lone-distant-7d-orange cell where the Settings
        //                    "Include distant 7d limit reset" checkbox toggles a visible difference.
        let stubMode = Self.stubName
        let transport: UsageTransport = switch stubMode {
        case "1":          StubUsageTransport(mode: .climbing)
        case "screenshot": StubUsageTransport(mode: .screenshot)
        case "error":      StubUsageTransport(mode: .authError)
        case "idle":       StubUsageTransport(mode: .idle)
        case "optimistic-reset": StubUsageTransport(mode: .optimisticReset)
        // Reset-countdown (#103) verification frames: fixed 5h×7d severities to exercise the table.
        case "5h-orange":   StubUsageTransport(mode: .pacing(.fiveOrange))
        case "both-orange": StubUsageTransport(mode: .pacing(.bothOrange))
        case "both-red":    StubUsageTransport(mode: .pacing(.bothRed))
        case "red-orange":  StubUsageTransport(mode: .pacing(.redOrange))
        case "calm5-orange7": StubUsageTransport(mode: .pacing(.calmFiveOrangeSeven))
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
                // Up to date (or a graceful failure). Clear any stale surfaced state so a manual
                // check reflects "you're current"; the menu item + its separator hide again.
                self.lastKnownRelease = nil
                self.setUpdateItemVisible(false)
                self.settingsWC?.updateAvailability(nil)
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

    /// Surface a newly-found newer release: retain it (drives the menu click + Configure line), reveal
    /// the blue-dot menu item, update the Configure… window if open, and post the macOS banner —
    /// **once per version** (guarded on `lastSeenLatestVersion`) so the same un-upgraded release does
    /// not re-notify every day. The menu item / Configure line stay shown regardless.
    private func handleUpdateFound(_ release: GitHubRelease) {
        lastKnownRelease = release
        setUpdateItemVisible(true)
        settingsWC?.updateAvailability(release)

        let firstTimeSeen = PersistedConfig.lastSeenLatestVersion != release.tagName
        PersistedConfig.lastSeenLatestVersion = release.tagName
        AppLogger.lifecycle.notice(
            "update: new version available tag=\(release.tagName, privacy: .public) firstSeen=\(firstTimeSeen, privacy: .public)")
        if firstTimeSeen {
            UpdateNotifier.post(release: release)
        }
    }

    /// Show or hide the "New version available" item together with its separator, so the two never
    /// drift out of sync (an absent update must leave no dangling rule).
    private func setUpdateItemVisible(_ visible: Bool) {
        updateSeparatorItem?.isHidden = !visible
        updateAvailableItem?.isHidden = !visible
    }

    /// Open the releases page from the "New version available" menu item — the specific release if one
    /// is known, else the releases index (#37).
    @objc private func openReleasesPage() {
        let url = lastKnownRelease.flatMap { URL(string: $0.htmlURL) } ?? GitHubReleaseClient.releasesPageURL
        AppLogger.lifecycle.notice("update: user opened releases page")
        NSWorkspace.shared.open(url)
    }

    /// The "New version available" menu item's title: a blue `circle.fill` dot (same tinted-symbol
    /// attachment technique as the popup's service-status rows) followed by the label at
    /// `dropdownTextSize`, so it matches the other native items' typography.
    private static func updateItemTitle() -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [.systemBlue]))
        if let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "update available")?
            .withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = dot
            attributed.append(NSAttributedString(attachment: attachment))
            attributed.append(NSAttributedString(string: "  "))
        }
        attributed.append(NSAttributedString(
            string: "New version available",
            attributes: [.font: NSFont.systemFont(ofSize: dropdownTextSize)]))
        return attributed
    }

    /// Re-render the retained last poll against the current time — grows the "Last update" age and
    /// advances the menu bar's stale thresholds. No-op before the first poll. **Never fetches.**
    private func reRenderForCurrentTime() {
        guard let output = lastOutput else { return }
        render(output, at: Date())
    }

    /// Render a poll result into the menu-bar image and popup model at instant `now`.
    private func render(_ output: PollOutput, at now: Date) {
        statusView?.layout = MenuBarLayout.make(
            from: output.snapshot, health: output.health, now: now,
            // #31: honour the "Show service status dot" toggle — nil hides the dot and reclaims its width.
            serviceProblem: PersistedConfig.showServiceStatusDot ? lastStatusHealth?.worstProblem : nil,
            resetMode: PersistedConfig.resetCountdownModeMenuBar)   // #103: which reset countdown to show
        refreshStatusImage()   // the menu-bar image is snapshotted, not auto-rendered, on layout change
        setPopupLayout(PopupLayout.make(
            from: output.snapshot, health: output.health, now: now, interval: output.interval,
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
