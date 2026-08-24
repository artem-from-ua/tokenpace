import AppKit
import UserNotifications
import TokenPaceKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu-bar item. Held strongly for the process lifetime — releasing it removes the item.
    private var statusItem: NSStatusItem?

    /// The custom view that renders the menu-bar image. The image is a single non-template `NSImage`
    /// (semantic colours resolved in the button's appearance); the KVO below re-snapshots it on a theme flip.
    private var statusView: StatusItemView?

    /// KVO on the button's `effectiveAppearance`. The menu-bar image is **non-template**, so it does not
    /// re-resolve its semantic colours on a theme flip by itself — this re-snapshots it when the bar
    /// flips light/dark.
    private var appearanceObservation: NSKeyValueObservation?

    /// The detail popup's content controller. Hosted inside a menu item so the popup gets the native
    /// menu-bar look — a rounded panel with **no arrow**, and the status button is highlighted while it
    /// is open (both come free with `NSMenu`, unlike `NSPopover`).
    private let popupVC = PopupViewController()

    /// The "Settings…" window, created lazily on first use and kept alive so a second click focuses the
    /// existing window rather than opening a duplicate (single-instance).
    private var settingsWC: SettingsWindowController?

    /// The "Insights" window (ADR-0067) — the separate data-visualisation surface reached from the first
    /// menu item. Lazily created and kept alive (single-instance), like `settingsWC`.
    private var insightsWC: InsightsWindowController?

    /// The hidden Troubleshoot window (ADR-0020), reached via ⌥ Option on "Settings…". Lazily
    /// created and kept alive; while open it re-renders on every poll (see `apply(_:)`).
    private var troubleshootWC: TroubleshootWindowController?

    /// The "Troubleshoot…" item (ADR-0020), revealed **below** "Settings…" while ⌥ Option is held.
    /// `NSMenuItem.isHidden` is flipped live by `updateTroubleshootVisibility(_:)`, driven by
    /// `optionPollTimer` — the native `isAlternate` swap does not work in a status-item menu.
    private var troubleshootItem: NSMenuItem?

    /// The "Settings…" item. ⌥-gated, hidden and revealed in lockstep with the other action items by
    /// `updateTroubleshootVisibility(_:)`.
    private var settingsItem: NSMenuItem?

    /// The separator above "Quit TokenPace". Hidden with the action items — a divider with nothing on
    /// one side of it reads as a rendering fault, and with ⌥ up there is nothing below it.
    private var quitSeparatorItem: NSMenuItem?

    /// The dev-only Development tools window. Lazily created and kept alive.
    private var devToolsWC: DevToolsWindowController?

    /// The optional "Development tools…" item, shown just below "Troubleshoot…" but **only** when the
    /// `devToolsEnabled` defaults key is set (`PersistedConfig.devToolsEnabled`) **and** ⌥ Option is
    /// held. Visibility is flipped alongside `troubleshootItem` in `updateTroubleshootVisibility(_:)`.
    private var devToolsItem: NSMenuItem?

    /// The "Quit TokenPace" item. Its title carries a build/stub tag — "(dev build)", "(dev build – error)",
    /// or "(stub – error)" — but **only** while ⌥ Option is held; the plain "Quit TokenPace" shows otherwise.
    /// The tag appears whenever this is a dev build **or** a stub is active — including a **signed `.app`**
    /// running a stub; a plain `.app` on the real network has no tag and stays "Quit TokenPace" regardless
    /// of Option.
    private var quitItem: NSMenuItem?

    /// The tag title shown on `quitItem` while ⌥ Option is held, or nil when there is none (a plain `.app`
    /// on the real network). Computed by ``updateQuitDevTitle()`` at menu-build time and re-computed on
    /// every live stub switch, so the ⌥ swap is a cheap string assignment that always names the stub
    /// actually running.
    private var quitDevTitle: String?


    /// Polls the ⌥ Option state while the dropdown is open, showing/hiding `troubleshootItem` when it
    /// changes (ADR-0020). A timer — not an event monitor — because NSMenu tracking runs a modal
    /// `NSEventTrackingRunLoopMode` that starves `addLocalMonitorForEvents(.flagsChanged)`, while
    /// `isAlternate` is inert in a status-item menu. Scheduled in `.common` modes so it *does* fire
    /// during tracking. Live only between `menuWillOpen` and `menuDidClose`.
    private var optionPollTimer: Timer?
    /// The last ⌥ state pushed to the menu, so the poll only re-toggles the item on a real change.
    private var lastOptionHeld = false

    // MARK: live polling

    /// Fan-in of sleep/wake (`NSWorkspace`) and network (`NWPathMonitor`) signals into the loop.
    private let signals = SignalHub()
    /// System sleep/wake observers, feeding `.sleep`/`.wake` into `signals`.
    private var sleepWake: WorkspaceSleepWake?
    /// Screen lock / screensaver / display-sleep observers, feeding `.sleep`/`.wake` into `signals`
    /// when `PersistedConfig.pausePollingWhenScreenLocked` is on.
    private var screenLock: ScreenLockObserver?
    /// Whether the screen is usable right now — `false` while locked, running a screensaver, or with
    /// the display asleep. Gates the awaiting-input watcher **unconditionally**: unlike the usage
    /// poll, there is no setting that makes scanning sessions the user cannot answer useful. Fed by
    /// ``ScreenLockObserver``'s availability callback, which bypasses the pause preference.
    private var screenAvailable = true
    /// `false` between `NSWorkspace.willSleep` and `didWake`. A backstop behind ``screenAvailable``:
    /// `screensDidSleep` normally arrives first and already parks the watcher, but notification
    /// ordering is not an Apple contract, so `didWake` guarantees a catch-up either way.
    private var systemAwake = true
    /// Connectivity monitor, feeding `.networkRestored` into `signals`.
    private let network = NetworkMonitor()
    /// The running poll loop's consumer task — cancelled on terminate.
    private var pollTask: Task<Void, Never>?

    /// The most recent poll result, retained so the popup's "Last update …" line can be re-aged
    /// between polls (the data is unchanged; only `now` advances).
    private var lastOutput: PollOutput?

    /// The most recent popup model, retained so a window opened *between* renders can be seeded with
    /// what the dropdown is showing right now — the Settings preview (ADR-0083) would otherwise sit
    /// empty until the next poll or 30 s age tick.
    private var lastPopupLayout: PopupLayout?

    // MARK: Awaiting-input indicator (ADR-0066)

    /// Watches `~/.claude/sessions` + `jobs` for sessions awaiting user input, or `nil` while the
    /// feature is off. Created/destroyed by ``updateAwaitingInputWatcher()``.
    private var awaitingInputWatcher: AwaitingInputWatcher?
    /// The latest awaiting-input result from the watcher (count, urgency, per-project). Read by
    /// ``awaitingInputForDisplay`` at render time.
    private var awaitingInput: AwaitingSessions = .none
    /// Verification stub: `TOKENPACE_AWAITING=N` synthesizes `N` awaiting sessions, bypassing the
    /// watcher. `TOKENPACE_AWAITING_DAYS=d1,d2,…` sets each session's days-until-deletion (to drive the
    /// urgency tint / red/orange buckets); missing days default to 20 (neutral). `TOKENPACE_AWAITING_
    /// PROJECTS=a,b,…` names the sessions' projects (round-robin) for the per-project popover.
    /// `TOKENPACE_AWAITING_NAMES=n1,n2,…` titles the sessions **positionally** — an empty slot
    /// (`a,,c`) or a missing one renders as `<unnamed>`. See docs/guides/ui-verification.md.
    /// Verification only — no such env var in a real build.
    private let awaitingInputStub: AwaitingSessions? = {
        let env = ProcessInfo.processInfo.environment
        guard let n = env["TOKENPACE_AWAITING"].flatMap(Int.init), n >= 0 else { return nil }
        let days = (env["TOKENPACE_AWAITING_DAYS"] ?? "").split(separator: ",").compactMap { Double($0) }
        let projects = (env["TOKENPACE_AWAITING_PROJECTS"] ?? "app").split(separator: ",").map(String.init)
        // Positional, unlike `_PROJECTS`: names identify, so cycling them would print the same title
        // on different rows. Empty subsequences are kept so `a,,c` can address the middle slot.
        let names = env["TOKENPACE_AWAITING_NAMES"].map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } ?? []
        let sessions = (0..<n).map { i in
            let name = i < names.count && !names[i].isEmpty ? names[i] : nil
            return AwaitingSession(
                project: projects.isEmpty ? "app" : projects[i % projects.count],
                daysUntilDeletion: i < days.count ? days[i] : 20,
                name: name)
        }
        return AwaitingSessions(sessions)
    }()

    /// Verification stub: `TOKENPACE_AWAITING_CYCLE=<seconds>` makes the forced count alternate
    /// between `TOKENPACE_AWAITING`'s value and zero on that period, so the hand's slide in and out
    /// (ADR-0073) can actually be watched. A knob on the existing stub, not a `StubScenario` case, so
    /// it can be checked against any data world the widget shares (bars, `blockedReset`, pause glyph).
    /// Verification only.
    private let awaitingCycleInterval: TimeInterval? = {
        let env = ProcessInfo.processInfo.environment
        guard let seconds = env["TOKENPACE_AWAITING_CYCLE"].flatMap(Double.init), seconds > 0
        else { return nil }
        return seconds
    }()

    /// Which half of the awaiting cycle is showing. Flipped by ``awaitingCycleTimer``.
    private var awaitingCycleOn = true
    /// Drives ``awaitingCycleInterval``. Non-nil only under that stub.
    private var awaitingCycleTimer: Timer?

    /// The awaiting-input result to render, or `nil` to hide the indicator. `nil` unless the feature is
    /// enabled **and** at least one session is waiting.
    ///
    /// The `TOKENPACE_AWAITING` stub forces the result **and** treats the feature as enabled, so the
    /// indicator can be verified with a plain `swift run` without toggling settings or running live
    /// Claude sessions (verification-only; a real build has no such env var). See ui-verification.md.
    private var awaitingInputForDisplay: AwaitingSessions? {
        if let stub = awaitingInputStub {
            // The cycle stub blanks the count on its off phase, which is what the hand animates out of.
            if awaitingCycleInterval != nil && !awaitingCycleOn { return nil }
            return stub.count >= 1 ? stub : nil
        }
        guard PersistedConfig.awaitingInputEnabled else { return nil }
        return awaitingInput.count >= 1 ? awaitingInput : nil
    }

    // MARK: Claude service status

    /// The transport used for status polls — the same seam as the usage transport (real
    /// `URLSession.shared`, or the stub under `TOKENPACE_STUB=1`). Set in `startPolling`.
    private var statusTransport: UsageTransport = URLSession.shared
    /// The latest mapped service status, or `nil` until the first status poll lands (cold start →
    /// no status lines in the popup).
    private var lastStatusHealth: StatusHealth?
    /// Instant of the last **successful** status poll, driving `StatusCadence.isDue`. A failed poll
    /// does not advance it, so the next usage tick retries.
    ///
    /// Stamped with `currentDate()`, not `Date()`: this value also reaches `PopupLayout` (via
    /// `withStatusAge`), a deterministic layer, so under a time-mocking stub a wall-clock stamp would
    /// render an age that is negative or jumps.
    private var lastStatusSuccess: Date?
    /// The in-flight status fetch, if any — held so a new tick can cancel a slow one rather than
    /// overlap.
    private var statusTask: Task<Void, Never>?
    /// The status loop's own heartbeat (ADR-0119) — a `LivePollScheduler` on its own `SignalHub`
    /// subscription, so status polling runs whether or not the usage poll is ticking (or enabled at
    /// all). Cancelled on terminate.
    private var statusLoopTask: Task<Void, Never>?
    /// The **status source's own** 429 hold — one `PollingBackoff` per status source, never shared
    /// (ADR-0119 §2): hold at exactly `Retry-After` (or 180 s), no escalation across consecutive
    /// 429s, first 200 clears it. Independent of the usage engine's backoff in both directions.
    private var statusBackoff = PollingBackoff()

    // MARK: GitHub status source

    /// The second status source, in the per-source shape ADR-0119 left room for: its own heartbeat,
    /// its own 429 hold, its own last-success marker and its own in-flight task. Nothing here is
    /// shared with Claude's — a 429 from `githubstatus.com` must hold only this source, an
    /// unreachable GitHub must not grey Claude's rows, and a Claude incident must not drag this poll
    /// down to the 60-second problem floor against a third party's page.
    private var githubLoopTask: Task<Void, Never>?
    private var githubTask: Task<Void, Never>?
    private var githubBackoff = PollingBackoff()
    private var lastGitHubSuccess: Date?
    /// The GitHub half of the rendered health. Kept apart from `lastStatusHealth` and merged only at
    /// render time, so neither provider's poll can overwrite the other's checks.
    private var lastGitHubHealth: StatusHealth?

    // MARK: update check

    /// The single update menu item, sitting just above Quit behind its own separator. Hidden unless
    /// `UpdateMenuState` says otherwise; its colour/label/visibility are set by `refreshUpdateMenuItem`.
    private var updateAvailableItem: NSMenuItem?
    /// The separator above ``updateAvailableItem``, hidden/shown in lockstep with it so an absent
    /// update leaves no dangling rule above Quit.
    private var updateSeparatorItem: NSMenuItem?
    /// The update item state last applied by `refreshUpdateMenuItem`, read by `openReleasesPage` to
    /// know whether opening it should clear the pending "what's new".
    private var currentUpdateItem: UpdateMenuState.Item = .hidden
    /// Whether the last auto-install verdict was a `defer…` (battery / metered / low disk) — drives the
    /// blue "Update pending" item. Set in `evaluateAutoInstall`, read by `refreshUpdateMenuItem`.
    private var installDeferred = false
    /// **Every** environment condition currently holding the install back, where `installDeferred`
    /// only says *that* one does. Mirrored into `SettingsModel` so About can name them; kept here too
    /// so a Settings window opened later starts from the current state.
    private var installBlockers: [UpdateDeferralReason] = []
    /// The newest release found so far, or `nil` if none/up-to-date. Drives the update menu item state
    /// and the Settings "Update available" line.
    private var lastKnownRelease: GitHubRelease?
    /// The in-flight update fetch, if any — cancelled before a new check and on terminate.
    private var updateTask: Task<Void, Never>?
    /// The in-flight auto-install, if any — cancelled before a new one and on terminate.
    private var installTask: Task<Void, Never>?
    /// The in-flight archive sync, if any — cancelled before a new sync and on terminate.
    private var archiveTask: Task<Void, Never>?
    /// The usage-journal writer. An `actor`, so appends are dispatched to it off the main actor; it
    /// never blocks a poll and swallows any write error. Only writes on the live `.realNetwork`
    /// scenario and when the journal is enabled — both gates are checked at the seam.
    private let usageJournal = UsageJournal()
    /// The dev-only raw status-payload log. Constructed unconditionally — it is inert until
    /// `PersistedConfig.statusPayloadLogEnabled` is set from Development tools, and holding it here
    /// keeps the "last fingerprint" across polls so unchanged payloads never reach the disk.
    private let statusPayloadLog = StatusPayloadLog()
    /// The incidents the last successful status poll deemed visible. Retained like
    /// `lastStatusHealth` so a re-render between polls (⌥ pressed, a usage tick) keeps showing them
    /// instead of blanking the section.
    private var lastClaudeIncidents: [VisibleIncident] = []
    /// GitHub's visible incidents, kept apart from Claude's for the same reason the healths are: the
    /// two arrive on independent polls, so a single list would be rewritten by whichever landed last
    /// and the other provider's incidents would vanish until its own next poll.
    private var lastGitHubIncidents: [VisibleIncident] = []
    /// Both providers' incidents as one list — what the popup renders under Option, and what the
    /// episode subscription and its notifications read. That is what makes GitHub incidents flow
    /// through the existing notification mechanism with no toggle of their own.
    private var lastVisibleIncidents: [VisibleIncident] { lastClaudeIncidents + lastGitHubIncidents }
    /// Routes taps on incident banners. Held for the process's lifetime — `UNUserNotificationCenter`
    /// keeps only a weak reference to its delegate, so letting this go would silently stop routing.
    private lazy var incidentNotificationDelegate = IncidentNotificationDelegate(
        onUnfollowed: { [weak self] in self?.reRenderForCurrentTime() })
    /// The result of the last archive sync, retained so the Settings status line can show
    /// "Last archived: … · N files" between runs. `nil` until the first sync completes.
    private(set) var lastArchiveSummary: LogArchiver.Summary?
    /// Whether the last archive run refused for lack of free space. Kept here — like
    /// `installBlockers` — so a Settings window opened *after* the refusal still starts from the
    /// current state; not persisted, because the next run re-derives it.
    private var archiveSpaceBlock: ArchiveSpaceVerdict = .proceed
    /// Whether the `gh` path is enabled, resolved once (lazily) from `TOKENPACE_GH_AUTH`. Checked in
    /// `ProcessInfo` first (terminal / `launchctl setenv` launches), then — since a login-launched app
    /// sees no shell env — from the login shell's `~/.zshrc`/`~/.zprofile` via `ShellEnvironment`. The
    /// shell probe is memoised so it runs at most once, not on every heartbeat.
    private lazy var ghAuthEnabled: Bool = Self.resolveGHAuth()

    /// What TokenPace monitors for Claude — loaded from `PersistedConfig` on launch, updated live
    /// when the user changes it in Settings (`providerMonitoringChanged`). Carries both halves:
    /// whether the usage API is polled at all, and which status-page services are watched. `Claude
    /// API` has no flag — it is derived (`claudeApiLocked`) from the rest. Seeded to `.default` until
    /// `applicationDidFinishLaunching` reads the stored value.
    private var providerMonitoring: ProviderMonitoring = .default

    /// The status-page half, for the many call sites that only care about services.
    private var monitoredServices: MonitoredServices { providerMonitoring.services }

    /// Re-renders the popup/menu bar from `lastOutput` on a fixed cadence so the "Last update" age
    /// grows ("just now" → "1m ago") without waiting for the next 180 s poll. **Never** fetches — it
    /// only recomputes the view models against the current time.
    private var ageTimer: Timer?

    /// Drives the smooth pacing-colour transitions on both surfaces (ADR-0070). Owned here rather
    /// than by either view because the popup's bar views are rebuilt from scratch on every update —
    /// state kept on them would be lost immediately — and because the two surfaces must share one
    /// registry and one frame clock. Its frame callback is wired to ``reRenderForCurrentTime()``.
    private let colorAnimator = ColorAnimator()

    /// Steps the `color-cycle` verification stub through its pacing zones (ADR-0070): a colour walk
    /// with the bar geometry pinned, so a maintainer can watch every transition without the usage
    /// API. Non-nil only under that stub.
    private var colorCycleTimer: Timer?

    /// One-shot timer firing exactly at the nearest window `resets_at` to apply a local optimistic
    /// reset + force a refresh, so the menu bar rolls straight from a live countdown to a fresh window
    /// without ever showing the stale ⏰. Rescheduled on every `apply(_:)` against the latest
    /// `resets_at`, invalidated on sleep, and recomputed on wake so a long sleep never fires a stale
    /// in-the-past reset. Unlike `ageTimer` this is non-repeating and fires at a variable instant.
    private var resetTimer: Timer?

    /// How `TOKENPACE_STUB` resolved at launch: the scenario, whether it was asked for explicitly, and
    /// the bogus value if one was passed. Resolution lives in ``StubScenario`` so the rules are
    /// testable and the valid-id list can't drift from the registry.
    ///
    /// An installed `.app` with no env stays live (production's normal mode); a dev build with no env —
    /// or **any** unrecognized value — gets the frozen `screenshot` frame instead of the real network.
    private static let launchResolution = StubScenario.resolve(
        env: ProcessInfo.processInfo.environment["TOKENPACE_STUB"],
        isAppBundle: LaunchAtLoginController.isAppBundle
    )

    /// The `TOKENPACE_STUB` scenario the app launched with. Seeds ``currentScenario`` and the
    /// dropdown's initial selection.
    private static let launchScenario = launchResolution.scenario

    /// The scenario currently driving the data source. Starts at ``launchScenario`` and changes only
    /// via the dev-tools live selector, which tears down and rebuilds the polling engine. Read by the
    /// Quit dev-build tag and the dropdown preselection so both agree on what's live.
    private var currentScenario: StubScenario = AppDelegate.launchScenario

    /// Whether ``currentScenario`` was **deliberately** chosen — a recognized `TOKENPACE_STUB` value, a
    /// plain `.app` launch, or a pick from the dev-tools dropdown. False when we fell back after a bad
    /// env value, or when a dev build defaulted to the screenshot frame.
    ///
    /// Only the awaiting-input watcher reads this (see ``updateAwaitingInputWatcher``): it scans the
    /// **live** `~/.claude` trees, so it must never come up on a live network nobody selected.
    private var scenarioWasExplicit: Bool = AppDelegate.launchResolution.isExplicit

    /// The clock the **visible** render reads. Normally the wall clock, but a date-decoupled stub
    /// (`StubScenario.stubClock`) pins it to a fixed instant so a stubbed frame is reproducible and,
    /// crucially, agrees with the stub transport's `resets_at` (both are built from this same clock).
    /// Only the visible path (layouts, reset countdowns, optimistic-reset overlay) uses this — service
    /// cadence (status/update/archive polls, quiet-hours) stays on the real `Date()`.
    private func currentDate() -> Date { currentScenario.stubClock ?? Date() }

    /// A forced update menu-item state from `TOKENPACE_UPDATE_STATE`, or `nil` for the real,
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
        // future migration can rename keys or clean up stale system state before the rest of launch
        // depends on it (ADR-0023).
        runConfigMigrationsIfNeeded()

        // The notification delegate and the incident category must be in place before this method
        // returns. A banner that *launched* the app is handed to the delegate immediately, so one
        // installed later would arrive with nothing listening — the tap would be lost.
        //
        // Gated on `isSupported`: on a bare `swift run` there is no bundle, and merely *touching*
        // `UNUserNotificationCenter.current()` raises `bundleProxyForCurrentProcess is nil` and kills
        // the process at launch.
        if BackToWorkNotifier.isSupported {
            UNUserNotificationCenter.current().delegate = incidentNotificationDelegate
            BackToWorkNotifier.registerCategories()
        }
        popupVC.onToggleSubscription = { [weak self] in self?.toggleEpisodeSubscription() }
        // The nothing-monitored popup routes straight to the page that produced the state.
        popupVC.onOpenProviderSettings = { [weak self] in self?.openSettings(section: .providers) }
        // The popup measures status/incident ages against the **scenario's** clock, not the wall
        // clock: a date-decoupled stub freezes time, and mixing the two made a stub's "2h" render as
        // "203d 11h" — the gap between the frozen frame and today.
        popupVC.now = { [weak self] in self?.currentDate() ?? Date() }

        // A bogus `TOKENPACE_STUB` no longer falls through to the live network — say so, naming the
        // value and every id that would have worked. Silent on every normal path.
        if let bogus = Self.launchResolution.unknownValue {
            AppLogger.lifecycle.notice(
                """
                dev: unknown TOKENPACE_STUB "\(bogus, privacy: .public)" — running the frozen \
                \(StubScenario.screenshot.id, privacy: .public) stub instead of the real network. \
                Available: \(StubScenario.validIDs.joined(separator: ", "), privacy: .public)
                """
            )
        }

        // Dev hook: `TOKENPACE_GENERATE_JOURNAL=<days>` writes a synthetic multi-day journal and
        // exits, so a downstream reader can be pointed at it via `TOKENPACE_JOURNAL_FILE`. Bypasses the
        // live-only poll path on purpose — this is generated fixture data, not a real poll.
        if let daysRaw = ProcessInfo.processInfo.environment["TOKENPACE_GENERATE_JOURNAL"],
           let days = Int(daysRaw) {
            generateJournalFixture(days: days)
            return
        }

        // Load the persisted provider-monitoring choice before the first poll, so both the usage
        // mode and the logical services resolve correctly from the start.
        providerMonitoring = PersistedConfig.providerMonitoring

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Cold start: no data yet — render the structure (idle/empty), not fake bars. The first
        // poll replaces this within a moment.
        let now = currentDate()
        let coldHealth = UsageHealth(lastSuccess: nil, failingSince: nil, reason: nil)
        let view = StatusItemView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 22)))
        view.layout = MenuBarLayout.make(from: nil, health: coldHealth, now: now)
        view.colorsTell = PersistedConfig.colorsTell     // saved calm-colours mode
        view.barStyle = PersistedConfig.menuBarStyle     // this surface's saved style
        // Smooth colour transitions (ADR-0070): both surfaces share one animator, and a frame simply
        // re-renders from the retained poll — the same path a settings change or an age tick takes.
        view.colorAnimator = colorAnimator
        popupVC.colorAnimator = colorAnimator
        colorAnimator.onFrame = { [weak self] in self?.reRenderForCurrentTime() }
        self.statusView = view
        self.statusItem = item

        // Hand the button a ready image. (Hosting the custom NSView as a button subview is unreliable —
        // the system button paints over it; see StatusItemView.snapshotImage.) The image is non-template,
        // so it must be re-snapshotted on a theme flip — the KVO below does that.
        refreshStatusImage()
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // A theme flip re-resolves every semantic colour, so the endpoints of any in-flight
                // transition now describe *different* appearances — blending them would render a
                // colour belonging to neither. Snap first, then re-snapshot (ADR-0070).
                self?.colorAnimator.finishAll()
                self?.refreshStatusImage()
            }
        }

        popupVC.loadView()   // realise the view so it can be sized before the menu measures it
        popupVC.barStyle = PersistedConfig.dropdownStyle   // this surface's own style
        // The dropdown's two section-visibility modes, likewise applied from launch.
        popupVC.modelLimitsVisibility = PersistedConfig.showPerModelLimits
        popupVC.extraUsageVisibility = PersistedConfig.showExtraUsage
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

        // "Insights…" (opens the separate usage-history visualisation window) is temporarily hidden:
        // the window has nothing worth showing yet. The window controller and `openInsights` action
        // are kept intact so restoring this is a one-line uncomment.
        // let insightsItem = NSMenuItem(title: "", action: #selector(openInsights), keyEquivalent: "")
        // insightsItem.attributedTitle = Self.dropdownMenuItemText("Insights…")
        // insightsItem.target = self
        // menu.addItem(insightsItem)
        // menu.addItem(.separator())

        // Action items at the bottom of the same menu. `keyEquivalent: ""` keeps a shortcut glyph off
        // the right edge — none is wanted, and there is no main menu to host a default ⌘Q.
        //
        // **Every item below is ⌥-gated.** With ⌥ up the menu is the widget and nothing else; the
        // popup draws a dim "hold ⌥ Option for more" caption where this column would be. The native
        // `isAlternate` mechanism does NOT work in a status-item menu, so the reveal is driven by a
        // modifier-polling timer set in `menuWillOpen` — see `updateTroubleshootVisibility(_:)`.
        //
        // They are built **hidden**, matching the ⌥-up state the menu opens into. `menuWillOpen` seeds
        // the real state before the menu is drawn, so a user opening with ⌥ already down still gets the
        // full column — but the built-in state has to be the common one, or the first frame flickers.
        let settingsItem = NSMenuItem(title: "", action: #selector(openSettings as () -> Void), keyEquivalent: "")
        settingsItem.attributedTitle = Self.dropdownMenuItemText("Settings…")
        settingsItem.target = self
        settingsItem.isHidden = true
        menu.addItem(settingsItem)
        self.settingsItem = settingsItem

        let troubleshootItem = NSMenuItem(title: "", action: #selector(openTroubleshoot), keyEquivalent: "")
        troubleshootItem.attributedTitle = Self.dropdownMenuItemText("Troubleshoot…")
        troubleshootItem.target = self
        troubleshootItem.isHidden = true
        menu.addItem(troubleshootItem)
        self.troubleshootItem = troubleshootItem

        // "Development tools…": the stub selector and payload log, sitting just below "Troubleshoot…".
        // Only ever visible when the `devToolsEnabled` defaults key is set AND ⌥ Option is held (both
        // gates applied in `updateTroubleshootVisibility`). The item is created unconditionally but
        // starts hidden: the gate is re-checked on every menu open, so toggling the defaults key takes
        // effect on the next open — no menu rebuild.
        let devItem = NSMenuItem(title: "", action: #selector(openDevTools), keyEquivalent: "")
        devItem.attributedTitle = Self.dropdownMenuItemText("Development tools…")
        devItem.target = self
        devItem.isHidden = true
        menu.addItem(devItem)
        self.devToolsItem = devItem

        // The single update item: one dropdown line carrying every non-critical update signal, sitting
        // just above Quit behind its own separator, with a status-coloured dot (same tinted
        // `circle.fill` attachment the popup uses for service dots). Both the separator and the item
        // start hidden and are driven entirely by `refreshUpdateMenuItem` (colour, label, visibility);
        // click opens Settings → About, except in the `whatsNew` state, which opens the installed tag's
        // release notes in the browser — see `openReleasesPage`.
        let updateSeparator = NSMenuItem.separator()
        updateSeparator.isHidden = true
        menu.addItem(updateSeparator)
        self.updateSeparatorItem = updateSeparator

        let updateItem = NSMenuItem(title: "", action: #selector(openReleasesPage), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        self.updateAvailableItem = updateItem

        // Separate Quit from the items above so the terminating action sits in its own group. The Quit
        // item grows a tag under ⌥ Option so the running process reads apart at a glance: a bare
        // `swift run` binary is tagged "(dev build)", and whenever a **stub** is active the scenario is
        // named too — even in a signed `.app` — e.g. "(stub – credits-onset)". A plain `.app` on the
        // real network shows no tag. The tag is revealed only while ⌥ Option is held (swapped in
        // `updateTroubleshootVisibility`).
        let quitSeparator = NSMenuItem.separator()
        quitSeparator.isHidden = true
        menu.addItem(quitSeparator)
        self.quitSeparatorItem = quitSeparator
        updateQuitDevTitle()
        let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "")
        quitItem.attributedTitle = Self.dropdownMenuItemText("Quit TokenPace")
        quitItem.target = self
        quitItem.isHidden = true
        menu.addItem(quitItem)
        self.quitItem = quitItem

        item.menu = menu

        startPolling()

        // Start the awaiting-input watcher if the feature is already on from a prior launch. No-op
        // (and no file watching) while the feature is off — it's opt-in.
        updateAwaitingInputWatcher()

        // Opt-out auto-registration of launch-at-login: register on the first launch only, log the
        // outcome, never crash on an unsigned build.
        registerLaunchAtLoginIfNeeded()

        // Update check: there are no system notifications — the sole signal is the single dropdown
        // item (`refreshUpdateMenuItem`). Surface a "what's new" left pending by a prior auto-update
        // relaunch right away, then check for a newer release.
        refreshUpdateMenuItem()
        if PersistedConfig.automaticUpdateChecks {
            // Always check once on launch, bypassing the 12 h cadence: a build the user just
            // installed/relaunched should surface a pending update immediately, not up to half a day
            // later.
            performUpdateCheck(userInitiated: false)
        }

        AppLogger.lifecycle.info(
            "TokenPace status item attached (\(TokenPaceKit.version, privacy: .public)); live polling started"
        )

        // Dev helper: `TOKENPACE_OPEN_SETTINGS=1 swift run` auto-opens the Settings window on launch, so
        // a settings change can be inspected without an AX menu-bar click — which is unsafe when the
        // installed `.app` and a dev build run side by side (the click can land on the wrong instance).
        if ProcessInfo.processInfo.environment["TOKENPACE_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openSettings() }
        }
        // Same for the Troubleshoot window, normally reached only via the ⌥-revealed menu item.
        if ProcessInfo.processInfo.environment["TOKENPACE_OPEN_TROUBLESHOOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openTroubleshoot() }
        }
        // Same for the Development tools window. Requires the `devToolsEnabled` defaults key too.
        if PersistedConfig.devToolsEnabled,
           ProcessInfo.processInfo.environment["TOKENPACE_OPEN_DEVTOOLS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openDevTools() }
        }
    }

    // MARK: - Menu actions

    /// Open (or focus) the Settings… window from the "Settings…" menu item. Leaves the section alone —
    /// a fresh window lands on About (the model's default); a reused one keeps its last-viewed pane.
    @objc private func openSettings() {
        openSettings(section: nil)
    }

    /// Open (or focus) the Insights window from the first menu item (ADR-0067). Lazily creates the
    /// single instance and keeps it alive, mirroring the Settings window's single-instance pattern.
    @objc private func openInsights() {
        if insightsWC == nil { insightsWC = InsightsWindowController() }
        insightsWC?.show()
    }

    /// Open (or focus) the Settings… window, optionally forcing a specific `section` (the update menu
    /// item opens straight to About). Lazily creates the single instance and wires the
    /// provider-monitoring change callback so a toggle there re-polls immediately.
    private func openSettings(section: SettingsSection?) {
        if settingsWC == nil {
            let wc = SettingsWindowController()
            wc.onProviderMonitoringChange = { [weak self] config in self?.providerMonitoringChanged(config) }
            wc.onGitHubMonitoringChange = { [weak self] _ in self?.gitHubMonitoringChanged() }
            wc.onCheckForUpdatesNow = { [weak self] in self?.performUpdateCheck(userInitiated: true) }
            wc.onInstallUpdateNow = { [weak self] in self?.installUpdateNow() }
            wc.onColorAdviceChange = { [weak self] mode in
                self?.statusView?.colorsTell = mode
                // Go through the normal render path, not a bare `refreshStatusImage()`: only
                // `render(_:at:)` calls `beginFrame()`, which advances `ColorAnimator.frameTime`. A
                // stale clock would date the new tween to the last poll's instant, already past its
                // 450 ms duration, so it would never animate (ADR-0070). Before the first poll there
                // is no `lastOutput` to re-render from, so fall back to the bare snapshot.
                if self?.lastOutput == nil { self?.refreshStatusImage() }
                else { self?.reRenderForCurrentTime() }
            }
            wc.onMenuBarStyleChange = { [weak self] style in
                // Render-only, menu bar only. The bar occupies the same rect whichever style it is (no
                // width rebuild), so a re-snapshot suffices.
                self?.statusView?.barStyle = style
                self?.refreshStatusImage()
            }
            wc.onDropdownStyleChange = { [weak self] style in
                // Render-only, popup only. The VC's `barStyle` didSet rebuilds its child bars.
                self?.popupVC.barStyle = style
                self?.reRenderForCurrentTime()
            }
            wc.onServiceDotChange = { [weak self] _ in
                // The dot changes the layout (drawn + item width), not just a colour — rebuild the
                // menu-bar layout from the last poll.
                self?.reRenderForCurrentTime()
            }
            wc.onModelLimitsVisibilityChange = { [weak self] mode in
                // Popup-only: the VC owns the gate because it depends on the live ⌥ state. Its
                // `didSet` rebuilds, which re-measures the hosted view.
                self?.popupVC.modelLimitsVisibility = mode
                self?.reRenderForCurrentTime()
            }
            wc.onExtraUsageVisibilityChange = { [weak self] mode in
                // Popup-only: the menu-bar credits icon keeps its own toggle (`onExtraUsageChange`).
                self?.popupVC.extraUsageVisibility = mode
                self?.reRenderForCurrentTime()
            }
            wc.onTopBarHidingChange = { [weak self] _ in
                // Changing this changes the layout (which bar is drawn, whether the survivor is
                // vertically centred), not just a colour — rebuild from the last poll.
                self?.reRenderForCurrentTime()
            }
            wc.onPausePollingChange = { [weak self] on in
                // Turning the pause OFF must un-stick a loop already parked by a screen lock: send a
                // `.wake` so it resumes immediately. Turning it ON changes nothing now.
                if !on { self?.signals.send(.wake) }
            }
            wc.onAwaitingInputEnabledChange = { [weak self] _ in
                // The master toggle flipped — start/stop the watcher (which reads the pref) and
                // re-render so the indicator appears/disappears from the last poll.
                self?.updateAwaitingInputWatcher()
                self?.reRenderForCurrentTime()
            }
            wc.onAwaitingInputAppearanceChange = { [weak self] in
                // An awaiting-input appearance option changed (left-of-pause placement). Must go
                // through `render(_:at:)`, not a bare `refreshStatusImage()`: only that advances
                // `ColorAnimator.frameTime`, and the presence tween needs a fresh clock to animate
                // rather than read as already finished (ADR-0070).
                self?.reRenderForCurrentTime()
            }
            wc.onArchiveNow = { [weak self] in self?.performArchiveSync(userInitiated: true) }
            wc.archiveSummaryProvider = { [weak self] in self?.lastArchiveSummary }
            wc.onBackToWorkEnabled = { completion in
                // Lazily request notification authorization the first time the user enables the
                // feature — never at launch, since this is opt-in.
                BackToWorkNotifier.requestAuthorizationIfNeeded(completion: completion)
            }
            // The Settings "Try" button: fire the banner on demand, bypassing edge-detection and
            // quiet hours. Each preview asks for authorization first — without it `post` returns
            // silently at its authorization guard and the button looks broken. The request is a no-op
            // once answered, so repeat presses cost nothing.
            wc.onTryBackToWork = {
                BackToWorkNotifier.requestAuthorizationIfNeeded { _ in
                    BackToWorkNotifier.postBackToWork()
                }
            }
            wc.onPreviewIncidents = { [weak self] in self?.previewIncidentBanners() }
            // "Try" for the Extra-Usage banner: build the body from the latest snapshot's spend so the
            // preview shows real amount/limit when available; an empty SpendInfo degrades to the
            // generic line. Bypasses edge-detection and quiet hours, same as back-to-work's Try.
            wc.onTryExtraUsage = { [weak self] in
                let spend = self?.lastOutput?.snapshot?.spend ?? SpendInfo()
                BackToWorkNotifier.requestAuthorizationIfNeeded { _ in
                    BackToWorkNotifier.postExtraUsage(body: ExtraUsageOnset.bannerBody(for: spend))
                }
            }
            // The live preview shares the one animator, so its transitions run on the same frame clock
            // as the menu bar and the popup rather than a second timer (ADR-0070, ADR-0083).
            wc.previewColorAnimator = colorAnimator
            settingsWC = wc
        }
        // Reflect the latest known update state whenever the window opens, including why an available
        // update is still pending — the blockers were computed at the last install evaluation, which
        // usually predates the window.
        settingsWC?.updateAvailability(lastKnownRelease)
        settingsWC?.updateDeferral(installBlockers)
        // Same reasoning for the archiver's low-space refusal: decided during a sync, which almost
        // always predates the window being opened.
        settingsWC?.updateArchiveBlock(archiveSpaceBlock)
        // Same for the live data source: the model seeds itself from `launchScenario`, but the
        // dev-tools selector may have switched scenarios since. Pull the current value on every open
        // so the "Stubbed in this development build." hints can never outlive the stub.
        settingsWC?.updateStubState(active: currentScenario != .realNetwork)
        // Seed the preview before the window goes up: `show()` attaches it, and renders can be up to
        // 30 s apart, so without this it would paint an empty card until the next one.
        if let lastPopupLayout { settingsWC?.updatePreview(lastPopupLayout) }
        settingsWC?.show(section: section)
    }

    /// Open (or focus) the hidden Troubleshoot window (ADR-0020), seeded with the latest poll result.
    /// Lazily creates the single instance; while open it re-renders on every poll. Its force-refresh
    /// button routes back to `forceRefresh()`.
    @objc private func openTroubleshoot() {
        if troubleshootWC == nil {
            let wc = TroubleshootWindowController()
            wc.onForceRefresh = { [weak self] in self?.forceRefresh() }
            troubleshootWC = wc
        }
        troubleshootWC?.show(lastOutput)
    }

    /// Open (or focus) the Development tools window: the live stub selector and the status-payload
    /// log switch. Lazily creates the single instance. Reachable only when the `devToolsEnabled`
    /// defaults key is set (the item is gated in the menu).
    @objc private func openDevTools() {
        if devToolsWC == nil {
            devToolsWC = DevToolsWindowController()
            // Live stub selector: the dropdown reports its pick back here to swap the data source
            // without a restart — the window holds no model reference of its own.
            devToolsWC?.onStubChange = { [weak self] in self?.switchScenario($0) }
        }
        devToolsWC?.setCurrentScenario(currentScenario)   // preselect the active stub (incl. env-set)
        devToolsWC?.show()
    }

    /// Force an immediate refresh of both data streams (the Troubleshoot window's button, ADR-0020):
    /// send `.manualRefresh` so **both** loops wake now, and clear the status side's own due-marker
    /// and 429 hold so its next poll actually fetches — mirroring what `.manualRefresh` already means
    /// for the usage engine (`PollSignal.manualRefresh`). Without clearing the backoff the button
    /// would silently do nothing for up to `Retry-After` seconds.
    private func forceRefresh() {
        AppLogger.lifecycle.notice("manual refresh requested (Troubleshoot)")
        lastStatusSuccess = nil            // make the status poll due on the next (immediate) tick
        statusBackoff = statusBackoff.reset()
        signals.send(.manualRefresh)       // wake both loops now + reset backoff (engine)
    }

    // MARK: - Optimistic reset

    /// React to a park/resume signal (`.sleep`/`.wake`) from either the system sleep/wake observer or
    /// the screen-lock observer: `Timer` scheduling is unreliable across sleep, so we invalidate the
    /// optimistic-reset timer on park and recompute its delay from the current `Date()` on resume — if
    /// a reset passed while parked, `rescheduleResetTimer`'s `delay <= 0` guard fires it immediately.
    /// Other signals (`.networkRestored`, `.manualRefresh`) do not touch the reset timer.
    private func handleParkSignal(_ signal: PollSignal) {
        switch signal {
        case .sleep:
            resetTimer?.invalidate()
            resetTimer = nil
            // Nothing is on screen to watch a fade, and a timer across sleep is unreliable anyway —
            // settle every transition at its destination (ADR-0070).
            colorAnimator.finishAll()
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

    /// Apply a new provider-monitoring config chosen in Settings: adopt it, drop the stale status (it
    /// was resolved under the old config), and force an immediate re-poll so the popup/menu-bar
    /// reflect the new services within a moment. Clearing `lastStatusHealth` briefly hides the status
    /// rows/dot until that fetch lands — honest, since the retained value describes services that are
    /// no longer the ones being monitored.
    ///
    /// The `.manualRefresh` signal is what makes a `usageApiEnabled` flip take effect **now** rather
    /// than up to a full interval later: the polling engine reads the mode from its seam at the top of
    /// each iteration, so it needs to be woken, not reconfigured.
    func providerMonitoringChanged(_ config: ProviderMonitoring) {
        providerMonitoring = config
        lastStatusHealth = nil
        lastStatusSuccess = nil            // status poll is due again on the immediate tick
        signals.send(.manualRefresh)       // wake the usage loop now, which rides the status poll
        reRenderForCurrentTime()           // clear the stale rows/dot right away
    }

    /// Show or hide **every action item** — and flip the popup's ⌥-driven content — for the current
    /// ⌥ Option state (ADR-0020). Called on menu open and by `optionPollTimer` while it is open — the
    /// status-item-menu replacement for the inert native `isAlternate` swap. Skips the work when the
    /// state is unchanged, so the poll is cheap.
    ///
    /// The name is historical: it gated only "Troubleshoot…" originally. Renaming it would touch every
    /// call site for no behavioural gain.
    private func updateTroubleshootVisibility(_ optionHeld: Bool) {
        guard optionHeld != lastOptionHeld else { return }
        lastOptionHeld = optionHeld
        // The guard above is not scoped to `troubleshootItem`: the popup's caption must follow ⌥ even
        // in the moments that optional is nil, and every item below is optional-chained anyway.
        troubleshootItem?.isHidden = !optionHeld
        // ⌥-gated — see the menu-build comment. The separator goes with them: a divider above a
        // hidden Quit would be a line under nothing.
        settingsItem?.isHidden = !optionHeld
        quitSeparatorItem?.isHidden = !optionHeld
        quitItem?.isHidden = !optionHeld
        // The update line itself stays visible in both states — it is a notice, not an action. Its
        // separator does not: it divides that line from the items above, and with ⌥ up there is nothing
        // above it to divide from. Guarded on the item's own visibility so a hidden update line does not
        // grow a separator under ⌥.
        if let updateAvailableItem, !updateAvailableItem.isHidden {
            updateSeparatorItem?.isHidden = !optionHeld
        }
        // "Development tools…" needs both gates: ⌥ Option AND the `devToolsEnabled` defaults key. The
        // item always exists now, so the flag gate is applied here (re-checked each open, so toggling
        // the defaults key takes effect on the next menu open).
        devToolsItem?.isHidden = !(optionHeld && PersistedConfig.devToolsEnabled)
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
    /// config is used (ADR-0023). Called first thing in `applicationDidFinishLaunching`.
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
        }
        // Idempotent per-key migrations that must catch an upgrade from *any* prior version (not gated
        // on the version diff above).
        PersistedConfig.retirePauseKeysIfNeeded()               // sweep away the pause keys (ADR-0090)
        PersistedConfig.migrateModelLimitsVisibilityIfNeeded()  // bool "show model/service limits" → tri-state
        // Bool "hide the calm 7-day bar" → its successor, which names the hidden bar directly
        // (ADR-0086). Only an explicit old choice carries over.
        PersistedConfig.migrateTopBarHidingIfNeeded()
        // Split the single bar-style key across the two surfaces. Must run before anything reads
        // either style key, or the getters resolve the stale raw to the preset default and the user's
        // choice is silently lost.
        PersistedConfig.migrateBarStyleIfNeeded()
        // Move the Appearance keys onto their surface-prefixed names, resolving each stored value
        // through its type's `legacyRawValues` on the way. **Runs last of the Appearance migrations,
        // deliberately** — the ones above write pre-migration key names, so this pass must see their
        // output, or a just-migrated flat key would be stranded until the next launch.
        PersistedConfig.migrateAppearanceKeysIfNeeded()
        // Retired: the "Far behind pace interval" key (width is fixed, blue is data-derived now), the
        // "Show reset countdown" key (ADR-0091 — the countdown now appears only where there are no
        // bars), and the "Custom" appearance stash (preset rows preview rather than overwrite).
        PersistedConfig.retireFarBehindIntervalIfNeeded()
        PersistedConfig.retireResetCountdownModeIfNeeded()
        PersistedConfig.retireCustomAppearanceValuesIfNeeded()
        // Record the running version so the next launch compares against it.
        PersistedConfig.lastRunVersion = current
    }

    /// Opt-out auto-registration: attempt to register whenever the OS has no active login item for
    /// us — either never registered, or a registration that dropped with a replaced bundle on an
    /// in-place update (`.notFound`). This runs on every launch and is idempotent via the status
    /// guard: `.registered`/`.requiresApproval` are left alone (the user/system decided).
    ///
    /// Gated to a real `.app` bundle: an ad-hoc-signed `swift run` binary is registerable too, so
    /// without this gate every dev run would silently add a login item pointing at `.build/…` and
    /// pollute the user's Login Items. On a dev build the Settings toggle stays clickable, so
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
        statusLoopTask?.cancel()
        githubLoopTask?.cancel()
        githubTask?.cancel()
        updateTask?.cancel()
        installTask?.cancel()
        archiveTask?.cancel()
        ageTimer?.invalidate()
        resetTimer?.invalidate()
        colorCycleTimer?.invalidate()
        awaitingCycleTimer?.invalidate()
        colorAnimator.finishAll()      // stop the transition frame timer (ADR-0070)
        // Best-effort: write out an error run still accumulating (ADR-0123). This handler is
        // synchronous and cannot await, so a run open at a hard kill is lost — acceptable, since a
        // run still open describes a failure the next launch will record again within one cadence.
        // All providers, not one: a per-provider flush here writes one run and drops the rest.
        Task { [usageJournal] in await usageJournal.flushAllErrorRuns() }
        sleepWake?.stop()
        screenLock?.stop()
        network.stop()
    }

    // MARK: - Live polling wiring

    /// Wire the platform signal sources to the engine and consume its output on the main actor.
    private func startPolling() {
        // Sleep/wake and network observers push signals into the shared hub. The optimistic-reset
        // timer also keys off sleep/wake: `Timer` scheduling is unreliable across sleep, so we
        // invalidate on sleep and recompute the delay from the current `Date()` on wake — if a reset
        // passed while asleep, `rescheduleResetTimer`'s `delay <= 0` guard fires it immediately.
        sleepWake = WorkspaceSleepWake { [signals, weak self] signal in
            signals.send(signal)
            // Observers fire on the main queue (see WorkspaceSleepWake), so we are on the main actor.
            MainActor.assumeIsolated {
                self?.handleParkSignal(signal)
                // System sleep also parks the awaiting-input watcher — a backstop behind the screen
                // gate below, which normally fires first. See `systemAwake`.
                self?.systemAwake = (signal != .sleep)
                self?.updateAwaitingInputWatcher()
            }
        }
        // Screen lock / screensaver / display-sleep park the loop the same way, gated by the
        // pause-on-screen-lock preference. It emits the same `.sleep`/`.wake`, so it also drives the
        // optimistic-reset timer through the shared handler.
        //
        // The second callback carries raw screen availability, *ungated* by that preference, and
        // drives the awaiting-input watcher — see `ScreenLockObserver`'s doc for why the gates differ.
        screenLock = ScreenLockObserver(
            onSignal: { [signals, weak self] signal in
                signals.send(signal)
                MainActor.assumeIsolated { self?.handleParkSignal(signal) }
            },
            onScreenAvailabilityChanged: { [weak self] available in
                MainActor.assumeIsolated {
                    self?.screenAvailable = available
                    self?.updateAwaitingInputWatcher()
                }
            })
        network.start { [signals] in signals.send(.networkRestored) }

        // Build and run the polling engine for the launch scenario (`TOKENPACE_STUB`, or the real
        // network). The dev-tools live selector re-runs `buildAndRunEngine(for:)` to switch the data
        // source without a restart, so the observers + age timer above stay put and only the engine
        // is rebuilt.
        buildAndRunEngine(for: currentScenario)
        // The status loop's own heartbeat (ADR-0119) — started once, alongside the engine but not
        // inside `buildAndRunEngine`: a live scenario swap rebuilds the engine, and the status loop
        // must survive that (it re-reads `statusTransport` on each poll, so it picks up the new
        // transport without being torn down).
        startStatusLoop()
        startGitHubLoop()
        updateColorCycle(for: currentScenario)   // arm the colour walk when launched under that stub
        startAwaitingCycleIfRequested()          // and the awaiting-input walk (ADR-0073)

        // Re-render on a fixed cadence so time-derived text ages without waiting for the next poll:
        // the popup's "Last update" line and the menu bar's stale thresholds both depend on `now`,
        // not on new data. It only recomputes view models, never fetches.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reRenderForCurrentTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ageTimer = timer
    }

    /// Construct the polling engine (transport, token provider, refresher) for `scenario` and start its
    /// consumer task, tearing down any previous engine first. Shared by launch and the dev-tools live
    /// selector. The scenario→transport mapping and the stub-vs-real token/refresher choice come from
    /// the shared ``StubScenario`` registry, so the env path and the dropdown never diverge.
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
        // Exception — `TOKENPACE_FORCE_REFRESH=1` (verification only), real network only: hand the
        // engine an *already-expired* stub token together with the *real* `ClaudeCLIRefresher`, so the
        // poll takes the `.expired` branch and spawns `claude --safe-mode …` on demand. The two env
        // vars are independent (force-refresh is ignored under a stub).
        let forceRefresh =
            ProcessInfo.processInfo.environment["TOKENPACE_FORCE_REFRESH"] == "1" && !scenario.usesStubToken
        let tokenProvider: TokenProviding = switch (scenario.usesStubToken, forceRefresh) {
        case (true, _):      StubTokenProvider()
        case (false, true):  ExpiredStubTokenProvider()
        case (false, false): KeychainTokenProvider()
        }
        let refresher: DelegatedRefresher? = scenario.usesStubToken ? nil : ClaudeCLIRefresher()

        // Bring the journal up to the current sample format. What makes this safe without a pause
        // flag is that `UsageJournal` is an **actor**: a rewrite and an append can never run
        // concurrently, so the first poll simply waits its turn if it arrives mid-rewrite. Files
        // already current are detected and skipped. Detached and unawaited on purpose — a journal
        // that cannot be migrated must never stop the app from working.
        let journalToMigrate = usageJournal
        Task.detached(priority: .utility) { await journalToMigrate.migrateIfNeeded() }

        let engine = PollingEngine(
            transport: transport,
            tokenProvider: tokenProvider,
            refresher: refresher,
            scheduler: LivePollScheduler(signals: signals.newStream(for: .usage)),
            probe: TranscriptActivityProbe(index: FileSystemActivityIndex()),
            now: clock,
            // Read the switch **live** on every iteration, not once at construction — a toggle in
            // Settings then takes effect on the next tick, and `providerMonitoringChanged` sends
            // `.manualRefresh` so that tick is immediate. The engine calls this from its own task, so
            // it goes through the `nonisolated` reader rather than the main-actor-isolated property.
            usageApiEnabled: { PersistedConfig.usageApiEnabledUnsafe() },
            // The weekly reconstruction's ratio takes ~20 h of active work to settle, so it is
            // restored across relaunches rather than re-warmed each time. Same `nonisolated` reader
            // discipline as the switch above — the engine calls these from its own task.
            restoreWeekly: { PersistedConfig.weeklyInterpolatorUnsafe() },
            persistWeekly: { PersistedConfig.setWeeklyInterpolatorUnsafe($0) },
            restoreSevenDayReset: { PersistedConfig.lastSevenDayResetUnsafe() },
            persistSevenDayReset: { PersistedConfig.setLastSevenDayResetUnsafe($0) })

        // Consume on the main actor — every PollOutput drives the menu bar + popup.
        pollTask = Task { [weak self] in
            for await output in engine.run() {
                guard let self else { break }
                self.apply(output)
            }
        }
    }

    /// Switch the live data source to `scenario` (dev-tools selector): rebuild the engine and force an
    /// immediate poll so the menu bar + popup reflect the new state within one cycle. No-op if the
    /// scenario is already active. Dev-only — reached only from the Development-tools dropdown.
    private func switchScenario(_ scenario: StubScenario) {
        guard scenario != currentScenario else { return }
        AppLogger.lifecycle.notice("dev: stub scenario → \(scenario.id, privacy: .public)")
        currentScenario = scenario
        // Picking from the dropdown *is* the explicit choice, so selecting "Real network" here brings
        // the awaiting-input watcher up even on a dev build.
        scenarioWasExplicit = true
        updateQuitDevTitle()             // keep the ⌥-Option Quit tag in sync with the live stub
        // The old and new data sources are unrelated worlds — carrying colours across would fade
        // between two of them. Drop the state outright, then (re)arm the colour walk (ADR-0070).
        colorAnimator.reset()
        updateColorCycle(for: scenario)
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

    /// Recompute the ⌥-Option "Quit TokenPace (…)" tag for the current build + stub. Called at
    /// menu-build time and again whenever the live stub selector switches scenarios, so the tag
    /// always names the stub actually running. A plain `.app` on the real network gets no tag (`nil`).
    /// The suffix is shown only while ⌥ is held (see `updateTroubleshootVisibility`).
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
    /// timer can re-render it against a later `now`. Also offers this heartbeat to the status poll:
    /// since ADR-0119 the status loop has a timer of its own, so this is a second, opportunistic
    /// entrance rather than the only one — both go through the same `isDue` gate.
    private func apply(_ output: PollOutput) {
        detectBackToWorkEdge(output)
        detectExtraUsageEdge(output)
        lastOutput = output
        render(output, at: currentDate())
        // Re-arm the optimistic-reset timer against this poll's `resets_at`. A successful poll fully
        // overwrites any prior optimistic overlay; a 429/error poll carries the stale last-known
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

    /// Append this usage poll to the local journal — a `usage` line on success, an `error` line on a
    /// genuine failure. No-op unless the journal is enabled **and** the app is on the live
    /// `.realNetwork` scenario: synthetic stub data must never enter the journal.
    ///
    /// The record is built here (on the main actor, from the fresh `output`) but the file write is
    /// dispatched to the `UsageJournal` actor, so the render path is never blocked and a write error is
    /// swallowed by the writer. The interval carried on `output` is the gap-detector's expected cadence.
    private func journalPoll(_ output: PollOutput) {
        guard PersistedConfig.journalEnabled, currentScenario == .realNetwork else { return }
        // While the usage poll is off there is no usage sample to record and no failure to report —
        // writing an `error` line every tick would fill the journal with a state the user chose.
        // Status polls keep writing through `appendStatus`, which does not touch the usage clock, so
        // that half of the journal stays live.
        guard output.health.isCollectingUsage else { return }
        let now = currentDate()
        let interval = output.interval
        let record: JournalRecord
        if output.health.failingSince == nil, let snapshot = output.snapshot {
            record = .usage(
                from: snapshot, now: now,
                durationMs: output.diagnostics?.fetch.durationMs,
                plan: output.diagnostics?.token?.subscriptionType,
                tier: output.diagnostics?.token?.rateLimitTier,
                // The journal records the value the bars were drawn from, the API's value beside it,
                // and the exchange rate behind both — every poll, not only when they differ.
                weekly: output.weekly)
        } else if let fetch = output.diagnostics?.fetch {
            record = .error(diagnostics: fetch, failure: output.health.reason, now: now)
        } else {
            return  // A failure with no diagnostics (never in the live path) — nothing to record.
        }
        Task { [usageJournal] in
            await usageJournal.append(record, at: now, expectedInterval: interval)
        }
    }

    /// Dev hook: generate a synthetic multi-day journal and terminate. Writes through `UsageJournal`
    /// (honouring `TOKENPACE_JOURNAL_FILE`), bypassing the live-only poll gates because this is
    /// fixture data for downstream UI verification, not a real poll.
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

    /// Detect the spent→available edge of the **subscription** quota for the "Back to work!"
    /// notification and post when it fires. Called at the top of `apply`, before `lastOutput` is
    /// overwritten.
    ///
    /// The tracked signal is `WorkAvailability.subscriptionAvailable` — "is my 5h/7d quota back?" —
    /// **not** `canWork`. Extra Usage Credit is deliberately outside this notification in both
    /// directions: a subscription reset is announced even when credits were covering the work in the
    /// meantime, and a credits reset on its own announces nothing while the subscription is still
    /// spent. Switching onto paid credit has its own banner (`detectExtraUsageEdge`, ADR-0050).
    ///
    /// The "quota was spent" state is **persisted** (`PersistedConfig.backToWorkWasBlocked`), not an
    /// in-memory flag, so the edge survives an app restart or a Mac sleep/reboot between hitting the
    /// limit and the reset. Tracking and posting live in separate guards on purpose: **tracking runs
    /// on every successful poll**, regardless of whether the feature is enabled, so the persisted
    /// state is always current; **posting runs only when the feature is enabled** *and* the previous
    /// successful reading had the subscription spent *and* it is available now.
    ///
    /// Only genuine successful polls update the state: a failing/stale poll carries the last-known
    /// snapshot forward (`health.failingSince != nil`), and the optimistic-reset overlay bypasses
    /// `apply` entirely (it calls `render`, not `apply`), so neither can produce a false "available".
    private func detectBackToWorkEdge(_ output: PollOutput) {
        // `hasLiveUsageData`, not `failingSince == nil`: the service-only mode is not failing either,
        // and a frozen snapshot there would re-assert "available" on every tick.
        guard output.health.hasLiveUsageData, let snapshot = output.snapshot else { return }
        let nowAvailable = WorkAvailability.subscriptionAvailable(snapshot)
        if PersistedConfig.backToWorkEnabled, PersistedConfig.backToWorkWasBlocked, nowAvailable {
            maybePostBackToWork()
        }
        PersistedConfig.backToWorkWasBlocked = !nowAvailable
    }

    /// Apply the quiet-hours gate and post the "Back to work!" banner if allowed. The pure evaluation
    /// (`NotificationSchedule`) runs against the user's window/suppress choice in a device-zone
    /// gregorian calendar; the impure post lives in `BackToWorkNotifier`.
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
    /// (`PersistedConfig.extraUsageWasOnCredits`) and updated on **every** successful poll regardless
    /// of the toggle; posting is gated on the toggle, the previous reading being *not* on credits, and
    /// the current one being on credits.
    ///
    /// Distinct from "Back to work!": that fires on blocked→workable, this on the switch onto paid
    /// credit (a state that is already workable), so the two never collide.
    private func detectExtraUsageEdge(_ output: PollOutput) {
        guard output.health.hasLiveUsageData, let snapshot = output.snapshot else { return }
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

    // MARK: - Episode subscription

    /// What the popup's single subscribe row should show right now, or `nil` to omit it.
    private func currentSubscriptionState() -> EpisodeSubscriptionState? {
        // Both providers: the subscription is one thing for the whole app — following an episode
        // means "tell me when this is over", and that question does not change with whose page the
        // incident is on.
        EpisodeEvaluator.rowState(
            incidents: lastVisibleIncidents,
            subscription: PersistedConfig.episodeSubscription)
    }

    /// Fold the latest poll into the episode subscription: persist the new state **unconditionally**,
    /// post banners only when the user is following, notifications are enabled, and quiet hours allow.
    ///
    /// The unconditional persist is the same discipline as `detectBackToWorkEdge`: state that only
    /// advances while a toggle is on will either replay an old edge or miss a new one the moment the
    /// toggle flips.
    private func advanceEpisodeSubscription() {
        let (events, next) = EpisodeEvaluator.evaluate(
            subscription: PersistedConfig.episodeSubscription,
            incidents: lastClaudeIncidents,
            now: currentDate())
        PersistedConfig.episodeSubscription = next

        guard !events.isEmpty else { return }
        guard notificationsAllowedNow() else {
            AppLogger.lifecycle.info("incident: suppressed by quiet hours")
            return
        }
        for event in events {
            postIncidentBanner(event)
        }
    }

    /// Post one of every incident banner the app can produce, for the Settings "Preview" button.
    ///
    /// Routed through ``postIncidentBanner(_:)`` rather than composing the text here, so the preview
    /// is the real thing: a wording change cannot drift out of sync with what the preview shows. The
    /// three are genuinely distinct messages rather than variants — an update carries the incident's
    /// own text, while the two endings make different claims ("you can work" versus "they say it is
    /// fixed"). Delivered unconditionally, bypassing quiet hours — the user pressed a button. Mirrors
    /// `tryBackToWork` / `tryExtraUsage`.
    private func previewIncidentBanners() {
        AppLogger.lifecycle.notice("incident: preview (forced) notifications")
        // Ask for authorization first. Without a subscription there has been no reason to request it
        // yet, so on a fresh install the three posts below would each hit `post`'s authorization
        // guard and return silently — the button would look broken. `requestAuthorizationIfNeeded`
        // is a no-op once the user has answered, so pressing Preview again costs nothing.
        // Without a subscription there has been no reason to request authorization yet, so on a fresh
        // install the three posts below would each hit `post`'s authorization guard and return
        // silently. `requestAuthorizationIfNeeded` is a no-op once answered.
        BackToWorkNotifier.requestAuthorizationIfNeeded { [weak self] _ in
            self?.postIncidentPreviewBanners()
        }
    }

    /// The three preview posts, run after authorization has been settled.
    private func postIncidentPreviewBanners() {
        postIncidentBanner(.update(
            incidentID: "f6gkkq6txl7z",
            name: "Degraded performance of multiple models",
            body: "We are continuing to work on a fix for this issue.",
            severity: .degraded))
        postIncidentBanner(.ended(reason: .fixDeployed))
        postIncidentBanner(.ended(reason: .componentsGreen))
    }

    /// Post one banner for an episode event. The quiet-hours and enablement gates are the caller's;
    /// this only turns an event into words.
    private func postIncidentBanner(_ event: EpisodeEvent) {
        switch event {
        case let .update(incidentID, name, body, severity):
            BackToWorkNotifier.postIncident(
                title: "\(Self.severityDot(severity)) \(name)",
                body: body,
                incidentID: incidentID)
        case let .ended(reason):
            // The two endings are different claims and must not be worded the same: components green
            // is "you can work", a deployed fix is only "they say it should be fixed".
            switch reason {
            case .componentsGreen:
                BackToWorkNotifier.postIncident(
                    title: "🟢 Claude is back",
                    body: "The services you monitor are operational again.",
                    incidentID: nil)
            case .fixDeployed:
                BackToWorkNotifier.postIncident(
                    title: "🟡 Fix deployed",
                    body: "Anthropic has deployed a fix and is monitoring for recovery.",
                    incidentID: nil)
            }
        }
    }

    /// A coloured dot for the banner title. `UNNotificationContent` has no colour indicator of its
    /// own, so the popup's visual language is carried by an emoji — simpler and more reliable than a
    /// generated `UNNotificationAttachment` image (ADR-0071 §8 / design §7).
    private static func severityDot(_ status: ServiceStatus) -> String {
        switch status {
        case .operational:      return "🟢"
        case .degraded:         return "🟡"
        case .partialOutage:    return "🟠"
        case .majorOutage:      return "🔴"
        case .underMaintenance: return "🔵"
        case .unknown:          return "⚪"
        }
    }

    /// Toggle the episode subscription from the popup's subscribe row.
    ///
    /// Subscribing seeds the seen-update set with everything already on screen, so the click cannot
    /// immediately notify about text the user is looking at.
    private func toggleEpisodeSubscription() {
        let current = PersistedConfig.episodeSubscription
        if current.isFollowing {
            PersistedConfig.episodeSubscription = EpisodeEvaluator.unfollow()
            AppLogger.lifecycle.info("incident: unfollowed the episode")
        } else {
            PersistedConfig.episodeSubscription = EpisodeEvaluator.follow(incidents: lastVisibleIncidents)
            AppLogger.lifecycle.info(
                "incident: followed the episode incidents=\(self.lastVisibleIncidents.count, privacy: .public)")
            // Asking to be notified is the first moment authorization is actually needed — requesting
            // it at launch would prompt users who never turn the feature on.
            BackToWorkNotifier.requestAuthorizationIfNeeded { _ in }
        }
        reRenderForCurrentTime()
    }

    /// The status loop's own heartbeat (ADR-0119): wait ``StatusCadence/nextInterval(backoff:usageInterval:hasProblem:)``,
    /// then poll if due — repeating for the process's lifetime.
    ///
    /// Built once at launch on its **own** `SignalHub` subscription, so it sees the same platform
    /// signals as the usage loop without competing for them: `.sleep` parks it until
    /// `.wake`/`.networkRestored`, exactly as `PollingEngine` does; `.wake`, `.networkRestored` and
    /// `.manualRefresh` cut the wait short and re-ask `isDue` rather than fetching unconditionally.
    ///
    /// The usage tick still calls `pollStatusIfDue` too. Both entrances funnel through the same
    /// `isDue` gate and the same in-flight `statusTask`, so the two heartbeats cannot double the
    /// request rate; what the second one buys is that status keeps running when the first one is slow,
    /// off, or absent.
    private func startStatusLoop() {
        let scheduler = LivePollScheduler(signals: signals.newStream(for: .status))
        statusLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.statusPollInterval()
                switch await scheduler.waitForNextPoll(interval: wait) {
                case .interrupted(.sleep):
                    await scheduler.waitWhileAsleep()   // park: no status fetch while asleep/locked
                case .elapsed, .interrupted:
                    break
                }
                guard !Task.isCancelled else { return }
                self.pollStatusIfDue()
            }
        }
    }

    /// Whether **anything at all** is monitored, across every provider.
    ///
    /// `ProviderMonitoring.isMonitoringAnything` answers only for Claude. Reading it as the app-wide
    /// answer would be a lie the moment a second provider can be enabled on its own: the popup would
    /// draw its "Monitoring is off" dead end over a live GitHub section, and the menu bar would show
    /// the nothing-monitored glyph while a GitHub outage was on screen.
    private var isMonitoringAnything: Bool {
        providerMonitoring.isMonitoringAnything || PersistedConfig.githubMonitoring.isMonitoringAnything
    }

    /// The two providers' health as one value, for the surfaces that read a single ``StatusHealth``:
    /// the menu-bar dot takes its worst-of-all, the popup groups it back into sections.
    ///
    /// Merged at **render** time rather than kept as one stored value, because the two arrive on
    /// independent cadences. A stored merge would have to be rewritten by whichever poll landed last,
    /// and the loser's checks would flicker out until its own next poll. `nil` only when neither
    /// provider has ever polled.
    private var renderedStatusHealth: StatusHealth? {
        switch (lastStatusHealth, lastGitHubHealth) {
        case let (.some(claude), .some(github)): return claude.merging(github)
        case let (.some(claude), .none):         return claude
        case let (.none, .some(github)):         return github
        case (.none, .none):                     return nil
        }
    }

    /// The GitHub provider's switch changed in Settings: poll **now** rather than at the next tick.
    /// Clearing `lastGitHubSuccess` is what makes the poll due: the cadence gate measures from the
    /// last success. Turning the provider *off* takes the same path — the poll sees the disabled
    /// config and clears the plate on the spot.
    private func gitHubMonitoringChanged() {
        lastGitHubSuccess = nil
        githubBackoff = githubBackoff.reset()
        pollGitHubIfDue()
    }

    /// The GitHub status source's heartbeat — the same shape as Claude's, on its own `SignalHub`
    /// subscription so the two never contend for a signal.
    ///
    /// Started unconditionally; the poll itself is what checks whether the provider is enabled.
    private func startGitHubLoop() {
        let scheduler = LivePollScheduler(signals: signals.newStream(for: .github))
        githubLoopTask = Task { [weak self] in
            // Poll **before** the first wait. `waitForNextPoll` sleeps the whole interval up front, so
            // starting with it would leave the section empty for the five-minute politeness floor
            // after every launch. Claude never had this problem because its status also rides the
            // usage tick; this source has no second heartbeat to cover for it.
            self?.pollGitHubIfDue()
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.githubPollInterval()
                switch await scheduler.waitForNextPoll(interval: wait) {
                case .interrupted(.sleep):
                    await scheduler.waitWhileAsleep()
                case .elapsed, .interrupted:
                    break
                }
                guard !Task.isCancelled else { return }
                self.pollGitHubIfDue()
            }
        }
    }

    /// GitHub's own cadence: its own hold, its own problem signal. `usageInterval` is always `nil` —
    /// this provider has no usage poll to settle with, which is the case ADR-0119 made the parameter
    /// optional for.
    private func githubPollInterval() -> TimeInterval {
        StatusCadence.nextInterval(
            backoff: githubBackoff,
            usageInterval: nil,
            hasProblem: lastGitHubHealth?.worstProblem(of: .github) != nil)
    }

    /// Fetch GitHub's status page when its own cadence says it is due.
    ///
    /// A near-twin of `pollStatusIfDue`, deliberately not folded into it: the two differ in every
    /// input that matters — endpoint, User-Agent, config type, backoff, success marker, health slot —
    /// so a shared implementation would be a parameter list as long as the body.
    private func pollGitHubIfDue() {
        let config = PersistedConfig.githubMonitoring
        guard config.isMonitoringAnything else {
            // Nothing to watch. Drop any stale health so the popup's GitHub section disappears with
            // the switch rather than lingering until the next launch.
            if lastGitHubHealth != nil || !lastGitHubIncidents.isEmpty {
                lastGitHubHealth = nil
                lastGitHubSuccess = nil
                lastGitHubIncidents = []
                reRenderForCurrentTime()
            }
            return
        }
        guard StatusCadence.isDue(
            lastSuccess: lastGitHubSuccess, backoff: githubBackoff, usageInterval: nil,
            hasProblem: lastGitHubHealth?.worstProblem(of: .github) != nil, now: Date()) else { return }

        githubTask?.cancel()
        let transport = statusTransport
        githubTask = Task { [weak self] in
            let health: StatusHealth
            var succeeded = false
            var rateLimited: TimeInterval??
            var fetchedSummary: StatusSummary?
            do {
                let summary = try await StatusClient.fetch(
                    transport: transport,
                    endpoint: StatusHealth.githubEndpoint,
                    // Not `claude-code/<version>`: that string is correct for Anthropic's page and
                    // misleading anywhere else (ADR-0119 §4).
                    userAgent: "TokenPace/\(TokenPaceKit.version)")
                health = .fromGitHub(summary, config: config)
                fetchedSummary = summary
                succeeded = true
            } catch StatusFetchError.rateLimited(let retryAfter) {
                health = .unknownGitHub(for: config)
                rateLimited = .some(retryAfter)
            } catch {
                health = .unknownGitHub(for: config)
            }
            guard let self, !Task.isCancelled else { return }
            self.lastGitHubHealth = health
            if succeeded, let summary = fetchedSummary {
                // GitHub's incidents, filtered against GitHub's own monitored names — never Claude's.
                // A failed poll leaves the previous list alone: an unreachable status page is not
                // evidence an incident ended.
                self.lastGitHubIncidents = IncidentVisibility.visible(
                    in: summary,
                    monitoredComponentNames: StatusHealth.monitoredGitHubComponentNames(for: config),
                    now: self.currentDate(),
                    maxAge: PersistedConfig.incidentMaxAge)
                self.advanceEpisodeSubscription()
            }
            if succeeded {
                self.lastGitHubSuccess = self.currentDate()
                if self.githubBackoff.isHolding {
                    AppLogger.network.notice("github status: 200 cleared the backoff hold")
                    self.githubBackoff = self.githubBackoff.reset()
                }
            } else if case let .some(retryAfter) = rateLimited {
                self.githubBackoff = self.githubBackoff.honoring(retryAfter: retryAfter)
                AppLogger.network.notice(
                    "github status backoff holding for \(self.githubBackoff.interval, privacy: .public)s")
            }
            self.reRenderForCurrentTime()
        }
    }

    /// How long the status loop should wait before its next poll: this source's 429 hold if one is
    /// active, else the applicable politeness floor, stretched to the usage cadence when *that* is
    /// slower and actually running. `usageInterval` is `nil` when the usage API is off — there is no
    /// usage cadence to settle with, so the floor stands on its own.
    private func statusPollInterval() -> TimeInterval {
        StatusCadence.nextInterval(
            backoff: statusBackoff,
            usageInterval: providerMonitoring.usageApiEnabled ? lastOutput?.interval : nil,
            hasProblem: lastStatusHealth?.worstProblem != nil)
    }

    /// Fetch the Claude status page when `StatusCadence` says it is due. Called from the status loop's
    /// own heartbeat and from each usage tick; the `isDue` gate below is what makes calling it from
    /// both harmless.
    ///
    /// - Parameter usageInterval: The usage cadence to settle with when one is running, or `nil` to
    ///   stand on the politeness floor alone.
    private func pollStatusIfDue(usageInterval: TimeInterval? = nil) {
        // While a service problem is in progress, poll faster (down to the 60-s problem floor) to
        // catch escalation/recovery quickly; otherwise the polite 5-min floor applies. An active 429
        // hold outranks both — the page named a number and we honour it.
        let hasProblem = lastStatusHealth?.worstProblem != nil
        guard StatusCadence.isDue(
            lastSuccess: lastStatusSuccess, backoff: statusBackoff, usageInterval: usageInterval,
            hasProblem: hasProblem, now: Date()) else { return }
        // Cancel any slow in-flight fetch rather than overlap.
        statusTask?.cancel()
        let transport = statusTransport
        // Snapshot the config for this fetch — which logical services to resolve, and which grey
        // `unknown` lines to show if it fails. `Claude API` rides along whenever anything at all is
        // monitored, which is why the usage flag travels with the service config.
        let config = monitoredServices
        let usageApiEnabled = providerMonitoring.usageApiEnabled
        statusTask = Task { [weak self] in
            let health: StatusHealth
            let succeeded: Bool
            var fetchedSummary: StatusSummary?
            var fetchedBody: Data?
            // The 429's `Retry-After` (or `nil` for "no usable hint"), when this attempt was rate
            // limited. `nil` outer value = not rate limited at all — two different nils, hence the
            // double optional rather than a bare `TimeInterval?`.
            var rateLimitHint: TimeInterval??
            do {
                let (summary, body) = try await StatusClient.fetchRaw(transport: transport)
                health = .from(summary, config: config, usageApiEnabled: usageApiEnabled)
                fetchedSummary = summary
                fetchedBody = body
                succeeded = true
            } catch {
                // Any failure → honest "unknown" (grey), and don't advance lastStatusSuccess so the
                // next tick retries. A 429 additionally arms this source's own hold, so "retries"
                // means "no sooner than the page asked for".
                if case StatusFetchError.rateLimited(let retryAfter) = error {
                    rateLimitHint = .some(retryAfter)
                }
                health = .unknown(for: config, usageApiEnabled: usageApiEnabled)
                succeeded = false
            }
            guard let self, !Task.isCancelled else { return }
            self.lastStatusHealth = health
            if succeeded {
                self.lastStatusSuccess = self.currentDate()
                // The first 200 clears any hold — PollingBackoff's own rule (ADR-0008/0032), reused
                // verbatim rather than re-decided here.
                if self.statusBackoff.isHolding {
                    AppLogger.network.notice("status backoff cleared by a successful poll")
                    self.statusBackoff = self.statusBackoff.reset()
                }
            } else if let retryAfter = rateLimitHint {
                // Re-set (never escalate) the hold at the server's number, or 180 s without one.
                self.statusBackoff = self.statusBackoff.honoring(retryAfter: retryAfter)
                AppLogger.network.notice(
                    "status backoff holding for \(self.statusBackoff.interval, privacy: .public)s")
            }
            // Recompute which incidents are worth showing, then fold the poll into the episode
            // subscription. A failed poll leaves the previous list in place — an unreachable status
            // page is not evidence that an incident ended.
            if succeeded, let summary = fetchedSummary {
                self.lastClaudeIncidents = IncidentVisibility.visible(
                    in: summary, config: config, usageApiEnabled: usageApiEnabled,
                    now: self.currentDate(),
                    maxAge: PersistedConfig.incidentMaxAge)
                self.advanceEpisodeSubscription()
            }
            // Journal the successful status poll as its own data sample — same live-only / enabled
            // gates as the usage seam. Status rides a separate cadence, so it does **not** run the
            // usage gap detector; it is an independent sample in the shared file.
            if succeeded, let summary = fetchedSummary,
               PersistedConfig.journalEnabled, self.currentScenario == .realNetwork {
                let record = JournalRecord.status(from: summary, health: health, now: self.currentDate())
                let at = self.currentDate()
                Task { [usageJournal = self.usageJournal] in await usageJournal.appendStatus(record, at: at) }
            }
            // Dev payload log (ADR-0071 §10): the raw body, written only when the material content
            // changed. Same live-only gate as the journal.
            if succeeded, let summary = fetchedSummary, let body = fetchedBody,
               PersistedConfig.statusPayloadLogEnabled, self.currentScenario == .realNetwork {
                let at = self.currentDate()
                Task { [log = self.statusPayloadLog] in
                    if await log.recordIfChanged(body: body, summary: summary, at: at) {
                        AppLogger.journal.info("status-payload-log: recorded a material change")
                    }
                }
            }
            // Re-render with the new status against the retained usage output.
            self.reRenderForCurrentTime()
        }
    }

    // MARK: - Update check

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
    /// Settings… "Check now" button (`userInitiated: true`). `userInitiated` only affects logging.
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
                self.installBlockers = []
                self.settingsWC?.updateAvailability(nil)
                self.settingsWC?.updateDeferral([])
                self.refreshUpdateMenuItem()
            }
        }
    }

    // MARK: - Session-log archive

    /// Mirror Claude Code's session logs when the daily `ArchiveCadence` says it is due, riding the
    /// usage heartbeat like the update and status polls. No-op when the feature is off, no destination
    /// is set, or the 24 h window has not elapsed.
    private func pollArchiveIfDue() {
        guard PersistedConfig.archiveEnabled, PersistedConfig.archiveDestination != nil else { return }
        guard ArchiveCadence.isDue(lastSync: PersistedConfig.lastArchiveSync, now: Date()) else { return }
        // Silent defer on battery: mirroring a session-log tree is a far heavier drain than the update
        // check, and the first sync copies the whole archive. The marker is not advanced, so the run
        // stays due and starts by itself once power is back. A manual "Archive now" reaches
        // `performArchiveSync` directly and bypasses this deliberately: the user asked.
        guard PowerSource.isOnACPower else {
            AppLogger.archive.notice("archive: deferred reason=on-battery")
            return
        }
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
                self.setArchiveSpaceBlock(.proceed)
                AppLogger.archive.notice(
                    "archive: sync ok — \(summary.copied, privacy: .public) updated, \(summary.bytes, privacy: .public) bytes, \(summary.totalInArchive, privacy: .public) files / \(summary.totalBytesInArchive, privacy: .public) bytes in archive")
                self.settingsWC?.updateArchiveStatus()
            case .failure(LogArchiver.ArchiveError.insufficientSpace(let need, let free)):
                // A designed refusal, not a fault: the run wrote nothing, the marker stays put, and
                // Settings names the reason. `.notice` rather than `.error` — an `.error` here would
                // dress up a normal full-disk state as a malfunction.
                self.setArchiveSpaceBlock(.blockedInsufficientSpace(needBytes: need, freeBytes: free))
                AppLogger.archive.notice(
                    "archive: blocked reason=insufficient-space need=\(need, privacy: .public) free=\(free, privacy: .public)")
                self.settingsWC?.updateArchiveStatus()
            case .failure(let error):
                // Don't advance the marker → next heartbeat retries.
                self.setArchiveSpaceBlock(.proceed)
                AppLogger.archive.error(
                    "archive: sync failed — \(error.localizedDescription, privacy: .public)")
                self.settingsWC?.updateArchiveStatus()
            }
        }
    }

    /// Record the low-space verdict of the last archive run and mirror it into Settings. Kept in one
    /// place so the field and the pushed value can never drift apart — unlike the archive status
    /// line, this state has no `PersistedConfig` for the model to pull from, so it must be pushed
    /// with its payload.
    private func setArchiveSpaceBlock(_ verdict: ArchiveSpaceVerdict) {
        archiveSpaceBlock = verdict
        settingsWC?.updateArchiveBlock(verdict)
    }

    /// Choose the fetch path: the `gh` subprocess when `TOKENPACE_GH_AUTH` is set (maintainers, so a
    /// private repo's releases are readable via local `gh` credentials), otherwise the anonymous
    /// HTTPS client (which works once the repo is public; while private it 404s → no update).
    ///
    /// `TOKENPACE_FAKE_LATEST=vX.Y.Z` overrides both paths with a canned tag — a verification aid so
    /// the "update available" and "up to date" UI branches can be driven on demand. Never set in
    /// normal use.
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
    /// be invisible via `ProcessInfo`. Check `ProcessInfo` first, then fall back to the login shell's
    /// rc files via `ShellEnvironment`. Memoised in `ghAuthEnabled` — the shell probe is a subprocess.
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
    /// auto-installer (`evaluateAutoInstall`) react. There are **no** macOS notifications — the single
    /// dropdown item is the sole signal.
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

        // Drop a stored install-failure record once it no longer denotes the newest known release —
        // a newer tag has appeared, so the About pane must not keep showing the old failure.
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
    /// (ADR-0033). The pure `UpdateInstallPlan.decide` folds every gate (opt-in, newer, real `.app`,
    /// has asset, free space, AC power, unmetered) into one verdict; the log line names the outcome
    /// either way.
    ///
    /// The environment facts are read from the shell and injected into the pure plan — they gate
    /// *installation only*, never the lightweight update check (`pollUpdateIfDue`).
    ///
    /// A **forced** run (a deliberate dry run via `TOKENPACE_UPDATE_DRYRUN`) bypasses the power/metered
    /// gates but **not** the free-space gate. The `defer…` verdicts are *temporary*: the next update
    /// heartbeat re-evaluates, so the install happens once conditions improve.
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
        // A `defer…` verdict drives the blue "Update pending" menu item; every other verdict clears
        // that flag. Set it before `refreshUpdateMenuItem` (called by the caller) reads it.
        switch decision {
        case .deferInsufficientSpace, .deferOnBattery, .deferMeteredNetwork:
            installDeferred = true
        default:
            installDeferred = false
        }

        // Every blocking condition, not just the one `decide` stopped at, so About can explain the
        // pending update in full. Deliberately read from the **real** environment even under a forced
        // run: this describes conditions, it decides nothing.
        installBlockers = UpdateInstallPlan.deferralReasons(
            release: release,
            currentVersion: TokenPaceKit.version,
            isAppBundle: LaunchAtLoginController.isAppBundle,
            autoInstallEnabled: PersistedConfig.installUpdatesAutomatically,
            freeDiskBytes: freeBytes,
            onACPower: PowerSource.isOnACPower,
            networkIsMetered: network.isMetered)
        settingsWC?.updateDeferral(installBlockers)

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

    /// Install the known release **now**, at the user's explicit request — the "Update now" button in
    /// Settings → About.
    ///
    /// The environment gates exist as a *courtesy*: they keep a background install from spending a
    /// metered link or risking a battery-drain mid-replace. An explicit click withdraws that courtesy,
    /// so this passes `onACPower: true, networkIsMetered: false`. Free space is **not** bypassed: no
    /// amount of user intent makes it safe to fill the disk. Neither are the settled-no gates —
    /// without an installable asset or a real `.app` bundle there is nothing to install.
    ///
    /// Distinct from `TOKENPACE_UPDATE_DRYRUN`, which conflates "bypass the gates" with "don't
    /// actually install"; here only the first half applies, so the installer is constructed with
    /// `dryRunForced: false` explicitly.
    func installUpdateNow() {
        guard let release = lastKnownRelease else {
            AppLogger.lifecycle.notice("update-install: decision=forced-skip reason=no-known-release")
            return
        }
        let freeBytes = DiskSpace.availableBytes(forVolumeContaining: Bundle.main.bundleURL) ?? .max
        let decision = UpdateInstallPlan.decide(
            release: release,
            currentVersion: TokenPaceKit.version,
            isAppBundle: LaunchAtLoginController.isAppBundle,
            // The user clicked "Update now" — that *is* the opt-in for this one install, whatever the
            // standing preference says.
            autoInstallEnabled: true,
            freeDiskBytes: freeBytes,
            onACPower: true,
            networkIsMetered: false)

        switch decision {
        case let .install(asset, targetVersion):
            AppLogger.lifecycle.notice(
                "update-install: decision=forced-install target=\(targetVersion, privacy: .public) asset=\(asset.name, privacy: .public)")
            startInstall(asset: asset, tag: targetVersion, forceRealInstall: true)
        case let .deferInsufficientSpace(_, targetVersion):
            // The one gate an explicit request cannot open.
            AppLogger.lifecycle.notice(
                "update-install: decision=forced-skip reason=insufficient-space target=\(targetVersion, privacy: .public)")
        case .deferOnBattery, .deferMeteredNetwork:
            // Unreachable: both gates were passed favourable values above.
            AppLogger.lifecycle.error("update-install: forced install hit an environment gate — unexpected")
        case .skipAutoInstallOff:
            AppLogger.lifecycle.error("update-install: forced install reported auto-install-off — unexpected")
        case .skipNotNewer:
            AppLogger.lifecycle.notice("update-install: decision=forced-skip reason=not-newer")
        case .skipNotAppBundle:
            AppLogger.lifecycle.notice("update-install: decision=forced-skip reason=not-app-bundle")
        case .skipNoAsset:
            AppLogger.lifecycle.notice("update-install: decision=forced-skip reason=no-asset")
        }
    }

    /// Run the installer for an `.install` verdict — a dry run under `TOKENPACE_UPDATE_DRYRUN`
    /// (download/verify/unzip, no replace), otherwise the real install (atomic replace + relaunch).
    /// Any failure logs and falls back to the single dropdown item (`refreshUpdateMenuItem`).
    ///
    /// **"What's new" is marked pending *before* the install runs**: a real install ends by
    /// relaunching + terminating *inside* `install()`, so there is no code path after
    /// `.installedRelaunching` in which to persist it — it must already be on disk when the new build
    /// starts. On a failure the marker is cleared again and `lastFailedInstallVersion` is set so this
    /// exact tag is not retried — a newer tag still is. A dry run touches neither marker.
    private func startInstall(asset: GitHubReleaseAsset, tag: String, forceRealInstall: Bool = false) {
        installTask?.cancel()
        // `forceRealInstall` is the "Update now" path: the user asked for an install, so the dry-run
        // env var must not turn it into a no-op.
        let dryRun = !forceRealInstall
            && ProcessInfo.processInfo.environment["TOKENPACE_UPDATE_DRYRUN"] == "1"
        // Persist the pending "what's new" up front so it survives the imminent relaunch. Skip for a
        // dry run (no real install / relaunch happens).
        if !dryRun {
            PersistedConfig.pendingWhatsNewVersion = tag
            AppLogger.lifecycle.notice("update-install: what's new pending set tag=\(tag, privacy: .public)")
        }
        let installer = UpdateInstaller(ghAuthEnabled: ghAuthEnabled, dryRunForced: dryRun)
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
                // About pane can show *why* it failed (tag + stage + reason).
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

    /// Recompute the single update menu item from the current version/flags and apply it: a `.hidden`
    /// state hides the item **and** its separator (no dangling rule); any `shown` state reveals them
    /// with the matching dot colour + label. This is the one place the item's visibility is decided —
    /// called after every update check, after an install verdict/failure, after the auto-install
    /// toggle changes, and at launch.
    ///
    /// The pure `UpdateMenuState.evaluate` picks the winner; the colour + wording live here (the view
    /// side, per ADR-0009/0013), reusing the popup's `dotColor` so the update dot matches the
    /// service-status dots exactly.
    private func refreshUpdateMenuItem() {
        // `TOKENPACE_UPDATE_STATE=failed|available|pending|whatsnew` forces the item to a given state
        // for live verification, without writing anything to the real UserDefaults. Never set in
        // normal use.
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
            popupVC.hasVisibleMenuNeighbour = false
            return
        }
        // The separator divides the update line from the action items **above** it — so it belongs on
        // screen only while those items are there. With ⌥ up they are hidden, and a divider between
        // the card and the update line is a rule under nothing.
        updateSeparatorItem?.isHidden = !lastOptionHeld
        updateAvailableItem?.isHidden = false
        // The card is no longer alone: it must keep its trimmed bottom margin, or the gap above this
        // row reads as a layout fault.
        popupVC.hasVisibleMenuNeighbour = true
        updateAvailableItem?.attributedTitle = Self.updateItemTitle(for: item)
        AppLogger.lifecycle.notice("update: menu item = \(String(describing: item), privacy: .public)")
    }

    /// Handle a click on the update menu item — the destination depends on the state.
    ///
    /// The three *pending-action* states (`updateFailed` / `updateAvailable` / `updatePending`) open
    /// **Settings → About**: it surfaces the update state and keeps the "Download" / release-notes
    /// links in-pane.
    ///
    /// `whatsNew` is different: the update has already landed, so there is nothing left to act on in
    /// About — the only thing the user came for is *what changed*. That state opens the release-notes
    /// page of the installed tag straight in the browser, skipping the About detour, and also
    /// acknowledges the update: clear `pendingWhatsNewVersion` and recompute the item.
    @objc private func openReleasesPage() {
        if currentUpdateItem == .whatsNew {
            // The acknowledged tag is the one the successful auto-update recorded — read it *before*
            // clearing. `releaseTag` adds GitHub's `v` prefix: `TokenPaceKit.version` is the bare
            // `0.111.0`, and a `…/releases/tag/0.111.0` URL is a 404.
            let tag = GitHubReleaseClient.releaseTag(
                PersistedConfig.pendingWhatsNewVersion ?? TokenPaceKit.version)
            AppLogger.lifecycle.notice("update: user opened release notes from update item (tag=\(tag, privacy: .public))")
            NSWorkspace.shared.open(GitHubReleaseClient.releaseNotesURL(tag: tag))
            PersistedConfig.pendingWhatsNewVersion = nil
            AppLogger.lifecycle.notice("update: cleared pending what's new (user opened it)")
            refreshUpdateMenuItem()
            return
        }
        AppLogger.lifecycle.notice("update: user opened About from update item (item=\(String(describing: self.currentUpdateItem), privacy: .public))")
        openSettings(section: .about)
    }

    /// The update menu item's title for `item`: a `circle.fill` dot tinted to the item's severity
    /// (reusing `PopupViewController.dotColor` so it matches the popup's service dots) followed by the
    /// label at `dropdownTextSize`. The dot is nudged up to sit on the text's optical centre
    /// (`Self.dotAttachment`), same as the popup rows.
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

    /// The dropdown label for each visible update state. `hidden` never renders a title, so it falls
    /// back to an empty string.
    private static func label(for item: UpdateMenuState.Item) -> String {
        switch item {
        case .hidden:          return ""
        case .updateFailed:    return "New version available (update failed)…"
        case .updateAvailable: return "New version available…"
        case .updatePending:   return "Update pending…"
        case .whatsNew:        return "What's new in the version…"
        }
    }

    /// The dot colour for each update state, taken from the popup's service-status palette: red for a
    /// failed install, blue for every other signal. `hidden` is never drawn; it maps to blue harmlessly.
    private static func dotColor(for item: UpdateMenuState.Item) -> NSColor {
        switch item {
        case .updateFailed: return PopupViewController.dotColor(.majorOutage)     // red
        default:            return PopupViewController.dotColor(.underMaintenance) // blue
        }
    }

    // MARK: - Awaiting-input cycle stub (ADR-0073)

    /// Arm the awaiting-input walk when `TOKENPACE_AWAITING_CYCLE` is set. Like the colour walk this
    /// cannot ride on polling — the cadence floor is 60 s, far too slow to inspect a 0.8 s slide — so
    /// it runs on its own timer and simply flips which half of the cycle ``awaitingInputForDisplay``
    /// reports.
    private func startAwaitingCycleIfRequested() {
        guard let interval = awaitingCycleInterval, awaitingInputStub != nil else { return }
        AppLogger.lifecycle.notice("dev: awaiting-input cycle stub armed")
        // `.common` run-loop mode so the walk keeps stepping while the dropdown is open — an `NSMenu`
        // runs a modal tracking loop that would starve a `.default` timer.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.awaitingCycleOn.toggle()
                // `reRenderForCurrentTime()`, never a bare `refreshStatusImage()`: only `render(_:at:)`
                // advances `ColorAnimator.frameTime` (ADR-0070).
                self.reRenderForCurrentTime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        awaitingCycleTimer = timer
    }

    // MARK: - Colour-cycle stub (ADR-0070)

    /// Which step of the colour walk is showing. Advanced by ``colorCycleTimer``.
    private var colorCycleStep = 0

    /// Arm or tear down the `color-cycle` colour walk for `scenario`. The walk cannot be driven by
    /// polling — the cadence floor is 60 s (`PollingEngine.minInterval`), far too slow to inspect a
    /// 450 ms fade — so it runs on its own short timer and overlays the retained snapshot, the same
    /// technique `fireOptimisticReset` uses.
    private func updateColorCycle(for scenario: StubScenario) {
        colorCycleTimer?.invalidate()
        colorCycleTimer = nil
        colorCycleStep = 0
        // Pin the bar geometry so the colour is the only thing that moves (nil clears it again when
        // switching away from the stub).
        let frozen = scenario == .colorCycle ? ColorCycleStub.stripFraction : nil
        statusView?.frozenStripFraction = frozen
        popupVC.frozenStripFraction = frozen
        guard scenario == .colorCycle else { return }

        AppLogger.lifecycle.notice("dev: colour-cycle stub armed")
        // `.common` run-loop mode so the walk keeps stepping while the dropdown is open — the popup
        // is an NSMenu-hosted view and its modal tracking loop would starve a `.default` timer.
        let timer = Timer(timeInterval: ColorCycleStub.stepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceColorCycle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        colorCycleTimer = timer
        advanceColorCycle()   // show the first zone immediately rather than after a full step
    }

    /// Move the walk on one zone and repaint. Rewrites only the 5-hour window's utilisation (and the
    /// worst-service status), leaving the 7-day bar untouched as a stationary reference.
    private func advanceColorCycle() {
        guard let output = lastOutput, let snapshot = output.snapshot else { return }
        let now = currentDate()
        let zone = ColorCycleStub.zones[colorCycleStep % ColorCycleStub.zones.count]
        let status = ColorCycleStub.statuses[colorCycleStep % ColorCycleStub.statuses.count]
        colorCycleStep += 1

        // Where the time marker would sit, so the target utilisation can be placed relative to it.
        let window = LimitWindow.fiveHour
        let remaining = ResetClock.parse(snapshot.fiveHour.resetsAt)
            .map { $0.timeIntervalSince(now) } ?? Double(window.durationSeconds) / 2
        let elapsed = Double(window.durationSeconds) - remaining
        let timeFraction = min(1, max(0, elapsed / Double(window.durationSeconds)))

        let utilization = ColorCycleStub.utilization(
            for: zone, timeFraction: timeFraction,
            windowDurationSeconds: window.durationSeconds)

        let overlay = PollOutput(
            snapshot: UsageSnapshot(
                fiveHour: UsageWindow(utilization: utilization, resetsAt: snapshot.fiveHour.resetsAt),
                sevenDay: snapshot.sevenDay,
                sevenDayOpus: snapshot.sevenDayOpus,
                sevenDaySonnet: snapshot.sevenDaySonnet,
                limits: snapshot.limits,
                sessionIdle: snapshot.sessionIdle,
                spend: snapshot.spend,
                // Only the five-hour utilization is overlaid; the weekly date and its provenance
                // belong to the underlying snapshot and must survive the dev-tools cycle.
                sevenDayResetSource: snapshot.sevenDayResetSource),
            health: output.health, interval: output.interval, diagnostics: output.diagnostics)
        lastOutput = overlay
        colorCycleStatus = status
        render(overlay, at: now)
    }

    /// The service status the colour walk is currently forcing, or `nil` when the stub is inactive.
    /// Read by ``render(_:at:)`` in place of the real worst-problem pick.
    private var colorCycleStatus: ServiceStatus?

    /// Re-render the retained last poll against the current time — grows the "Last update" age and
    /// advances the menu bar's stale thresholds. No-op before the first poll. **Never fetches.**
    private func reRenderForCurrentTime() {
        guard let output = lastOutput else { return }
        render(output, at: currentDate())
    }

    /// Bring the awaiting-input watcher in line with the current feature state and screen
    /// availability. Creates the watcher lazily when the master toggle is on and drives it via
    /// `setActive`; tears it down when off. Called at launch, whenever the toggle flips, and on every
    /// lock/unlock and system sleep/wake.
    ///
    /// Two kinds of "off", deliberately different: the **feature** being off destroys the watcher and
    /// clears the count, while a **locked screen** only parks it and keeps the last count for the
    /// unlock.
    ///
    /// The `TOKENPACE_AWAITING` stub short-circuits the watcher entirely — the forced count is read
    /// directly by `awaitingInputForDisplay`. A data stub also short-circuits it: on any scenario but
    /// `.realNetwork` the watcher stays down, mirroring the journal's gate — the watcher reads the
    /// *live* `~/.claude` trees, so a screenshot run under a stub would otherwise show whatever real
    /// sessions happen to be waiting.
    ///
    /// Live alone isn't enough: that live network must have been **explicitly** selected
    /// (``scenarioWasExplicit``) — `TOKENPACE_STUB=real`, a plain `.app`, or the dev-tools dropdown. A
    /// dev build that merely *ended up* live must never have the hand indicator report the
    /// maintainer's real sessions in a run everyone reads as stubbed.
    private func updateAwaitingInputWatcher() {
        // The feature itself is off (toggle, stub, or a non-live scenario): there is nothing to watch
        // and nothing to show, so tear the watcher down and clear the count.
        let featureWanted = PersistedConfig.awaitingInputEnabled
            && awaitingInputStub == nil
            && currentScenario == .realNetwork
            && scenarioWasExplicit
        guard featureWanted else {
            if awaitingInputWatcher != nil {
                awaitingInputWatcher?.setActive(false, reason: "feature off")
                awaitingInputWatcher = nil
            }
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
        // The screen gate. Parking here keeps the watcher object alive and, deliberately, keeps the
        // last known count on screen: the user cannot see the menu bar while the screen is locked, and
        // `setActive(true)` runs a catch-up scan on resume that either confirms or corrects it.
        // Clearing the count would only make the indicator blink on every unlock.
        //
        // Not gated on `claude` running: with no `claude` alive nothing writes to the watched trees,
        // so FSEvents is already silent and the only cost is a ~0.18 ms scan per 45 s safety tick.
        guard screenAvailable && systemAwake else {
            awaitingInputWatcher?.setActive(false, reason: screenAvailable ? "system sleep" : "screen locked")
            return
        }
        awaitingInputWatcher?.setActive(true, reason: "screen available")
    }

    /// Render a poll result into the menu-bar image and popup model at instant `now`.
    private func render(_ output: PollOutput, at now: Date) {
        // Open an animation frame: pin the instant every colour is sampled at (so bars drawn later in
        // this pass don't sit further along the curve than their neighbours) and expire elements that
        // have gone off screen. ADR-0070.
        colorAnimator.beginFrame()
        // Roll any window whose reset boundary has already passed forward to its next window *before*
        // formatting, so a countdown never computes `remaining <= 0`. The exact `resetTimer` normally
        // fires the roll-forward at the boundary (`fireOptimisticReset`), but a render driven by
        // another timer can land in the sub-second gap before it fires — so we apply the same pure
        // overlay here on every render. No-op when nothing has crossed a boundary; the next
        // authoritative poll overwrites it wholesale (ADR-0043).
        //
        // Swap the API's quantised 7-day utilization for the value reconstructed from the five-hour
        // counter, so every surface downstream reads one consistent number. Applied **before** the
        // optimistic reset: that overlay may zero the weekly window locally ahead of the server, and
        // `applied(to:)` refuses to touch a window whose raw value no longer matches what the
        // interpolator measured — running it second would make it a silent no-op on boundary polls.
        let snapshot = output.snapshot
            .map { output.weekly?.applied(to: $0) ?? $0 }
            .map { ResetClock.optimisticReset($0, now: now) }
        // The awaiting-input count is `nil` (hidden) unless the feature is on and ≥ 1 session is
        // waiting. Sourced from the watcher (or the `TOKENPACE_AWAITING` stub), independent of the poll.
        let awaitingInput = awaitingInputForDisplay
        statusView?.layout = MenuBarLayout.make(
            from: snapshot, health: output.health, now: now,
            // The colour-cycle stub forces the dot through its own palette (ADR-0070); otherwise the
            // real worst problem, subject to the "Show service status dot" toggle.
            serviceProblem: PersistedConfig.showServiceStatusDot
                ? (colorCycleStatus ?? renderedStatusHealth?.worstProblem) : nil,
            // ADR-0086: honour the "Hide the calm bar" choice — drops whichever bar the user picked
            // while it is calm, centring the one that remains. `.never` keeps both.
            hideTopBar: PersistedConfig.hideTop5hBar,
            // The ¤ icon shows whenever credits are active and a base limit is exhausted — the data
            // decides, and it is already silent until money is in play (ADR-0090).
            showCredits: true,
            // With nothing monitored the widget reports that, rather than the last thing it saw.
            monitoringAnything: isMonitoringAnything)
            .withAwaitingInput(awaitingInput)
        refreshStatusImage()   // the menu-bar image is snapshotted, not auto-rendered, on layout change
        setPopupLayout(PopupLayout.make(
            from: snapshot, health: output.health, now: now, interval: output.interval,
            serviceStatus: renderedStatusHealth,
            // The per-model rows are always built here; whether they're drawn is the popup VC's call
            // (it owns the live ⌥ Option state — see `PopupSectionVisibility`).
            monitoringAnything: isMonitoringAnything)
            .withAwaitingInput(awaitingInput)
            // In the services-only mode the age shown is the **status** poll's, since that is the only
            // thing being fetched. A no-op in every other mode.
            .withStatusAge(lastStatusSuccess.map { max(0, now.timeIntervalSince($0)) })
            .withGitHubStatusAge(lastGitHubSuccess.map { max(0, now.timeIntervalSince($0)) })  // separate cadence
            .withGitHubIncidents(lastGitHubIncidents)
            // Claude's plate gets Claude's incidents only; GitHub's ride `withGitHubIncidents` above.
            // The concatenated `lastVisibleIncidents` is for the episode subscription and its
            // notifications, where the provider does not change what the banner says.
            .withIncidents(lastClaudeIncidents)
            .withSubscription(currentSubscriptionState())
            // Graft the brand-coloured plan label ("Max (5x)") from the Keychain rate-limit tier — a
            // plan mark, not a secret. `nil` (no tier / unreadable creds) draws just "Claude".
            .withPlanLabel(claudePlanLabel(rateLimitTier: output.diagnostics?.token?.rateLimitTier)))
    }

    /// Set the popup model **and** resize the hosted view to fit. A menu item's hosted view must
    /// carry a concrete non-zero frame — `NSMenu` lays the item out from `frame`, not Auto Layout —
    /// and it does **not** re-measure when the content rebuilds. So every layout change must re-fit
    /// the frame, otherwise sections added later are clipped to the older, smaller frame.
    private func setPopupLayout(_ layout: PopupLayout) {
        popupVC.layout = layout
        popupVC.view.frame = NSRect(origin: .zero, size: popupVC.view.fittingSize)
        // Latched for a Settings window opened *between* renders: without it the preview would sit
        // empty until the next poll or age tick (up to 30 s).
        lastPopupLayout = layout
        settingsWC?.updatePreview(layout)   // mirror into the Settings window's live preview (ADR-0083)
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
    /// by menu tracking, so a modifier-polling timer drives the reveal instead. Seed visibility from
    /// the modifiers already held at open time (the user may open the menu with ⌥ down).
    func menuWillOpen(_ menu: NSMenu) {
        // Re-read the ⌥-caption switch on every open: the menu is built once at launch and never
        // rebuilt, so a Settings change would otherwise not land until a restart. Set before the
        // visibility seed, which draws the caption.
        popupVC.optionHintEnabled = PersistedConfig.showOptionHint
        // Seed visibility from the modifiers held at open time. Force the first sync by desyncing
        // `lastOptionHeld`.
        lastOptionHeld = !NSEvent.modifierFlags.contains(.option)
        updateTroubleshootVisibility(NSEvent.modifierFlags.contains(.option))
        // Poll the live modifier state while the menu tracks. Added in `.common` modes so it fires
        // during the modal tracking loop, which would otherwise starve a `.default` timer. The fire
        // runs on the main run loop, so the main-actor hop is a known-safe assumption.
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
