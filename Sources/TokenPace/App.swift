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

    /// Re-renders the popup/menu bar from `lastOutput` on a fixed cadence so the "Last update" age
    /// grows ("just now" → "1m ago") without waiting for the next 180 s poll. **Never** fetches — it
    /// only recomputes the view models against the current time.
    private var ageTimer: Timer?

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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Cold start: no data yet — render the structure (idle/empty), not fake bars. The first
        // poll replaces this within a moment.
        let now = Date()
        let coldHealth = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil)
        let view = StatusItemView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 22)))
        view.layout = MenuBarLayout.make(from: nil, health: coldHealth, now: now)
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
        // Separate Quit from Settings… so the terminating action sits in its own group (standard
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

        AppLogger.lifecycle.info(
            "TokenPace status item attached (\(TokenPaceKit.version, privacy: .public)); live polling started"
        )
    }

    // MARK: - Menu actions (#14)

    /// Open (or focus) the Settings… window. Lazily creates the single instance.
    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
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
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: dropdownTextSize)])
    }

    /// Quit the app via the standard terminate path, which triggers `applicationWillTerminate`.
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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
        ageTimer?.invalidate()
        sleepWake?.stop()
        network.stop()
    }

    // MARK: - Live polling wiring (#13)

    /// Wire the platform signal sources to the engine and consume its output on the main actor.
    private func startPolling() {
        // Sleep/wake and network observers push signals into the shared hub.
        sleepWake = WorkspaceSleepWake { [signals] signal in signals.send(signal) }
        network.start { [signals] in signals.send(.networkRestored) }

        // TOKENPACE_STUB swaps the live URLSession for a canned-response transport so the app can be
        // driven end-to-end (popup text, interval logs) without touching the usage API. Verification
        // aid only — never set in normal use; the default path is the real network.
        //  • `=1`          → climbing utilisation (exercises adaptive cadence on screen).
        //  • `=screenshot` → frozen, hand-picked values (a stable frame for the README).
        //  • `=error`      → 401 auth failure + both Claude services degraded (the warning block).
        let stubMode = Self.stubName
        let transport: UsageTransport = switch stubMode {
        case "1":          StubUsageTransport(mode: .climbing)
        case "screenshot": StubUsageTransport(mode: .screenshot)
        case "error":      StubUsageTransport(mode: .authError)
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
        // Live-update an open Troubleshoot window: both sections (JSON, timestamps, next update,
        // token dates) refresh in place each poll (ADR-0020). No-op while the controller is nil.
        troubleshootWC?.render(output)
        pollStatusIfDue(usageInterval: output.interval)
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
        statusTask = Task { [weak self] in
            let health: StatusHealth
            let succeeded: Bool
            do {
                let summary = try await StatusClient.fetch(transport: transport)
                health = .from(summary)
                succeeded = true
            } catch {
                // Any failure → honest "unknown" (grey), and don't advance lastStatusSuccess so the
                // next usage tick retries.
                health = .unknown
                succeeded = false
            }
            guard let self, !Task.isCancelled else { return }
            self.lastStatusHealth = health
            if succeeded { self.lastStatusSuccess = Date() }
            // Re-render with the new status against the retained usage output.
            self.reRenderForCurrentTime()
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
        statusView?.layout = MenuBarLayout.make(
            from: output.snapshot, health: output.health, now: now,
            serviceProblem: lastStatusHealth?.worstProblem)
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
