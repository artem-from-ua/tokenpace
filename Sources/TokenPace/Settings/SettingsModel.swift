import Foundation
import Observation
import TokenPaceKit

// MARK: - SettingsModel (#168, ADR-0042)

/// The observable state behind the Settings window. It lives as long as `SettingsWindowController`
/// (created in its `init`, **not** inside any SwiftUI view), so the background poll/archive callbacks
/// always have somewhere to write even while the window is closed.
///
/// **Ordering invariant:** every setter writes `PersistedConfig` *first*, then fires the callback.
/// Views never bind `PersistedConfig` directly; they call these `set…` methods (via
/// `Binding(get:set:)`), so SwiftUI can't reorder persist vs callback. `syncFromConfig()` reads the
/// store back into the model without going through the setters, so a re-sync never re-persists or
/// re-fires a callback.
@MainActor
@Observable
final class SettingsModel {

    // MARK: Callbacks (the AppDelegate contract — set by the window controller's forwarders)

    var onProviderMonitoringChange: ((ProviderMonitoring) -> Void)?
    /// Separate from `onProviderMonitoringChange`, which carries Claude's config only (#454).
    var onGitHubMonitoringChange: ((GitHubMonitoring) -> Void)?
    var onCodexMonitoringChange: ((CodexMonitoring) -> Void)?
    var onCheckForUpdatesNow: (() -> Void)?
    var onInstallUpdateNow: (() -> Void)?
    var onColorAdviceChange: ((ColorAdvice) -> Void)?
    var onMenuBarStyleChange: ((BarStyle) -> Void)?
    var onDropdownStyleChange: ((BarStyle) -> Void)?
    var onServiceDotChange: ((Bool) -> Void)?
    /// The menu-bar "Providers to display" checkboxes changed — the widget's block set and width follow.
    var onMenuBarProvidersChange: ((Set<ProviderID>) -> Void)?
    var onModelLimitsVisibilityChange: ((PopupSectionVisibility) -> Void)?
    var onExtraUsageVisibilityChange: ((PopupSectionVisibility) -> Void)?
    var onTopBarHidingChange: ((TopBarHiding) -> Void)?
    var onPausePollingChange: ((Bool) -> Void)?
    /// Starts/stops the `AwaitingInputWatcher` and re-renders (#233).
    var onAwaitingInputEnabledChange: ((Bool) -> Void)?
    /// An appearance-only option changed — re-render from the last snapshot, no watcher restart.
    var onAwaitingInputAppearanceChange: (() -> Void)?
    var onArchiveNow: (() -> Void)?
    var onBackToWorkEnabled: ((@escaping @MainActor (BackToWorkNotifier.AuthState) -> Void) -> Void)?
    /// Settings "Try" button (#193): posts immediately, bypassing edge-detection and quiet hours.
    var onTryBackToWork: (() -> Void)?
    var onTryExtraUsage: (() -> Void)?
    /// "Preview" button beside the incident hint (#279): fires one of every incident banner.
    var onPreviewIncidents: (() -> Void)?
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)?

    // MARK: Selection (dev hook)

    /// Bound straight to the sidebar's `List(selection:)`. Writes coming from ``goBack()`` /
    /// ``goForward()`` are excluded from history — a replay must not itself become history.
    var selection: SettingsSection = .about {
        didSet {
            guard selection != oldValue, !isReplayingHistory else { return }
            // A different sidebar row always re-enters at the section's own root (#341).
            childPage = nil
            history.visit(SettingsRoute(selection))
        }
    }

    /// The child page drilled into from ``selection``, or `nil` at the section's own page (#341).
    /// The sidebar keeps highlighting the parent section while this is set, as System Settings does.
    private(set) var childPage: SettingsChildPage?

    /// Where the window is: the section, plus the child page if one is open.
    var route: SettingsRoute {
        childPage.map { SettingsRoute(selection).drilling(into: $0) } ?? SettingsRoute(selection)
    }

    /// History over **routes**, not sections, so a parent and its child are two distinct stops: ‹
    /// from `Providers › Claude` lands on `Providers` rather than skipping past it.
    private var history = NavigationHistory<SettingsRoute>(current: SettingsRoute(.about))

    /// Set while ``goBack()``/``goForward()`` write the route, so `didSet` above can tell a replay
    /// from a user's own pick.
    private var isReplayingHistory = false

    /// The title the toolbar shows — the child page's name while one is open, else the section's.
    var currentPaneTitle: String { route.title }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// A click landed somewhere in the sidebar column — leave any open child page. Clicking a
    /// **different** row already clears `childPage` via `selection`'s `didSet`, so this only matters
    /// for a click on the **current** row or the empty space below the rows (SwiftUI's `List`
    /// consumes clicks on the already-selected row, so `SettingsWindowController`'s local mouse
    /// monitor is what calls this).
    ///
    /// `openAt` guards against the click arriving after the List has already switched to another
    /// section: comparing against the page that was open *when the click happened* stops this from
    /// popping a child page the new section legitimately opened.
    func popFromSidebarClick(openAt page: SettingsChildPage?) {
        guard let page, childPage == page else { return }
        popToRoot()
    }

    /// Open a child page of the current section, recording it as its own history stop (#341).
    func drill(into page: SettingsChildPage) {
        guard childPage != page else { return }
        childPage = page
        history.visit(route)
    }

    /// Leave the child page for its parent section's own page.
    func popToRoot() {
        guard childPage != nil else { return }
        childPage = nil
        history.visit(route)
    }

    /// Seat the window on a pane **without recording a visit** — the `TOKENPACE_SETTINGS_SECTION`
    /// dev hook's entry point. Seeds the history rather than appending to it, so ‹ does not light up
    /// on a freshly opened window and step "back" to a pane never shown.
    func openAtLaunch(_ section: SettingsSection) {
        seat(SettingsRoute(section))
    }

    /// Same no-visit semantics for a **child page** — both toolbar chevrons stay dimmed.
    func openAtLaunch(_ page: SettingsChildPage) {
        seat(SettingsRoute(page.section).drilling(into: page))
    }

    private func seat(_ route: SettingsRoute) {
        isReplayingHistory = true
        selection = route.section
        childPage = route.child
        isReplayingHistory = false
        history = NavigationHistory(current: route)
    }

    /// Step back to the previously visited pane.
    func goBack() {
        guard history.canGoBack else { return }
        history.goBack()
        applyHistorySelection()
    }

    /// Step forward to the most recently popped pane.
    func goForward() {
        guard history.canGoForward else { return }
        history.goForward()
        applyHistorySelection()
    }

    private func applyHistorySelection() {
        isReplayingHistory = true
        selection = history.current.section
        childPage = history.current.child
        isReplayingHistory = false
    }

    /// Whether a data stub (`TOKENPACE_STUB`, or the dev-tools selector) is driving the app rather than
    /// the real network. Pushed by the shell on every `openSettings` and on each dev-tools scenario
    /// switch (#187) — can't be derived from `ProcessInfo` since the launch env goes stale once the
    /// selector is used.
    ///
    /// Drives the ⚠️ "Stubbed in this development build." hints: under a stub the service statuses are
    /// canned and the awaiting-input watcher doesn't run. Toggles stay enabled for the next real run.
    var stubScenarioActive = false

    /// Live sidebar icon sizing, keyed off the system "Sidebar icon size". Lives here so it persists
    /// with the window and keeps observing while open.
    let sidebarIcons = SidebarIconMetrics()

    // MARK: General

    private(set) var launchAtLogin = false
    /// Drives the recovery hint (#69); reset on a successful toggle or a fresh `show()`.
    private(set) var launchToggleFailed = false
    var pausePolling = false

    // MARK: Appearance (menu-bar widget)

    /// The "Colors tell me" row (#381). Governs the pacing bars only; the service dot, credits glyph
    /// and idle pill don't read it.
    var colorsTell: ColorAdvice = .slowDown

    /// What the "Colors tell me" control should show — ``colorsTell`` normally, forced to
    /// ``ColorAdvice/slowDown`` while the menu bar is on **Pressure**, since that style mutes the
    /// entire quiet side to white and only the "too fast" orange keeps its color. Read-only and not
    /// stored back: the user's own choice stays untouched and returns on Balance/Progress.
    var displayedColorAdvice: ColorAdvice { menuBarStyle == .pressure ? .slowDown : colorsTell }

    /// Whether the **top (5-hour)** bar steps aside until it needs attention (ADR-0086).
    var hideTop5hBar: TopBarHiding = .untilItNeedsAttention
    /// Per-model 7-day limit rows in the popup (Opus/Sonnet/scoped, #211) — lives on the `Dropdown`
    /// child page, not the menu-bar one.
    var showPerModelLimits: PopupSectionVisibility = .whenItNeedsAttention
    /// The popup's "Extra usage" credits section. The menu-bar credits icon has no user gate
    /// (ADR-0090).
    var showExtraUsage: PopupSectionVisibility = .onceUsed
    var showServiceDot = false
    /// Providers whose menu-bar block the user unchecked (ADR-0128). Stored as the hidden set so a
    /// provider added later is checked out of the box.
    var menuBarHiddenProviders: Set<ProviderID> = []
    /// The **menu-bar widget**'s bar style (#224, per-surface since #329).
    var menuBarStyle: BarStyle = .progress
    /// The **dropdown popup**'s bar style, independent of ``menuBarStyle`` (#329).
    var dropdownStyle: BarStyle = .progress

    // MARK: Provider monitoring (#89, #341)

    /// Whether the usage API is polled. Separate from the status-page services below: turning it off
    /// leaves them monitored.
    var usageApiEnabled = true
    var claudeCodeEnabled = true
    var webDesktopEnabled = true
    var webDesktopMode: WebDesktopMode = .chatOnly

    /// What the provider pages currently describe — the value the callback carries.
    var providerMonitoring: ProviderMonitoring {
        ProviderMonitoring(
            usageApiEnabled: usageApiEnabled,
            services: MonitoredServices(
                claudeCodeEnabled: claudeCodeEnabled,
                webDesktopEnabled: webDesktopEnabled,
                webDesktopMode: webDesktopMode))
    }

    /// Whether the `Claude API` row is forced on and locked — derived, never stored (#341).
    var claudeApiLocked: Bool { providerMonitoring.claudeApiLocked }

    /// The state line under the `Claude` row on the Providers page (#341). Counts the services
    /// actually resolved (`Claude API` included, `Cowork` when the mode adds it), not the switches,
    /// so the number matches the rows the popup draws.
    var claudeProviderSummary: String {
        let services = StatusHealth.monitoredComponentNames(
            for: providerMonitoring.services, usageApiEnabled: usageApiEnabled).count
        guard services > 0 else { return "Off" }
        let servicesText = "\(services) service\(services == 1 ? "" : "s") monitored"
        return usageApiEnabled ? "Usage API · \(servicesText)" : servicesText
    }

    // MARK: GitHub provider (#454)

    /// Whether GitHub's `Development services` group is monitored. On by default; placeholder until
    /// `resync()` reads the stored value.
    var githubDevelopmentServicesEnabled = true

    /// What the GitHub page currently describes — the value its callback carries.
    var githubMonitoring: GitHubMonitoring {
        GitHubMonitoring(developmentServicesEnabled: githubDevelopmentServicesEnabled)
    }

    /// The state line under the `GitHub` row on the Providers page. Names the group rather than
    /// counting components — `Development services` is one switch over five constituents, so a count
    /// would promise a granularity the page doesn't offer.
    var githubProviderSummary: String {
        githubDevelopmentServicesEnabled ? "Development services" : "Off"
    }

    // MARK: Codex provider (#503)

    /// Codex's status config. Placeholder until `resync()` reads the stored value.
    var codexMonitoring: CodexMonitoring = .default

    /// The state line under the `Codex` row. Counts services, like Claude's, because Codex's five
    /// **are** five switches — a group name would promise a granularity that is the opposite of what
    /// the page offers.
    var codexProviderSummary: String {
        let count = StatusHealth.monitoredCodexComponentNames(for: codexMonitoring).count
        guard count > 0 else { return "Off" }
        return "\(count) service\(count == 1 ? "" : "s") monitored"
    }

    /// The state line under one provider's row — the accessor the generated Providers list reads, so
    /// a provider added to `ProviderID` gets a row without an edit here.
    func providerSummary(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: return claudeProviderSummary
        case .github: return githubProviderSummary
        case .codex:  return codexProviderSummary
        }
    }

    /// The state line under a surface's navigator row on the Appearance page — labelled
    /// `Style: Balance` using the child page's own control label, from the same
    /// `AppearanceBarStyle.segments` table the picker reads.
    func surfaceSummary(for page: SettingsChildPage) -> String? {
        let style: BarStyle
        switch page {
        case .appearanceMenuBar: style = menuBarStyle
        case .appearanceDropdown: style = dropdownStyle
        // Provider pages report their own state via `providerSummary(_:)`.
        case .providersClaude, .providersGitHub, .providersCodex: return nil
        // Legend configures nothing; its row carries a fixed subtitle instead.
        case .appearanceLegend: return nil
        }
        guard let name = AppearanceBarStyle.segments.first(where: { $0.value == style })?.title else {
            return nil
        }
        return "Style: \(name)"
    }

    // MARK: Notifications (#160)

    var backToWorkEnabled = false
    var extraUsageNotifyEnabled = false
    /// Hide incidents older than this many hours in the popup; `0` = no limit (#279).
    var incidentMaxAgeHours = 0
    var notifyStartMinute = 0
    var notifyEndMinute = 0
    var suppressDays: SuppressDays = .never
    /// Updated asynchronously by `refreshAuthState()` / the `onBackToWorkEnabled` completion.
    private(set) var authState: BackToWorkNotifier.AuthState = .notDetermined

    // MARK: Session Logs (#110)

    var archiveEnabled = false
    private(set) var archiveDestination: String?
    private(set) var archiveStatusText = ""

    /// Whether the last archive run refused for lack of free space (#306), pushed by the shell after
    /// each run. Seeded from the stub so a forced verification state survives the first push.
    private(set) var archiveSpaceBlock: ArchiveSpaceVerdict =
        SettingsModel.forcedArchiveGate?.space ?? .proceed

    // MARK: Insights — usage journal (#242)

    /// Whether the usage journal records each poll to an append-only JSONL file. Default-off (opt-in).
    var journalEnabled = false

    // MARK: Dropdown — the ⌥ caption (#475) and the pinned action items (#521)

    /// Whether the dropdown draws "hold ⌥ Option for more". Default-**on**: the only thing announcing
    /// that ⌥ has anything to show.
    var showOptionHint = true

    /// Whether `Settings…` and `Quit` stay in the dropdown with ⌥ up. Default-**on**. Independent of
    /// ``showOptionHint`` — the caption is about what ⌥ expands on the widgets, not about the menu's
    /// actions, so both rows act on their own in every combination.
    var alwaysShowActionItems = true

    // MARK: Awaiting-input indicator (#233, ADR-0066)

    /// Master toggle for the "N sessions awaiting input" indicator. Default-off. Placement is
    /// configured separately in Appearance.
    var awaitingInputEnabled = false
    /// Also show the indicator in the menu bar (bare icon, no count), in addition to the popup.
    /// Default-off. Only meaningful while ``awaitingInputEnabled`` is on.

    // MARK: About / Updates (#37)

    var automaticUpdateChecks = false
    var installAutomatically = false
    private(set) var latestRelease: GitHubRelease?
    /// The most recent failed auto-install (#210), or `nil`. Read from `PersistedConfig` in
    /// `syncFromConfig()`; drives the ⚠️ "Update … failed" row on the About pane.
    private(set) var lastUpdateFailure: LastUpdateFailure?
    /// Every environment condition currently holding back an available update (#221), or `[]`. Pushed
    /// by the AppDelegate on each install evaluation. Drives the ⚠️ "Update pending because …" row.
    private(set) var deferralReasons: [UpdateDeferralReason] = SettingsModel.forcedDeferralReasons ?? []

    // MARK: Static build facts

    /// A real `.app` bundle (not a `swift run` dev build). Gates launch-at-login, auto-install, and the
    /// "Back to work" master switch (ADR-0012 §4, ADR-0018).
    let inAppBundle = LaunchAtLoginController.isAppBundle
    let versionText = SettingsModel.makeVersionText()
    /// The GitHub release tag of the **installed** version (`vX.Y.Z`), for the About pane's "release
    /// notes" link (#224). Shown only in a real `.app` bundle — a dev build has no published release.
    let currentVersionTag = "v\(TokenPaceKit.version)"

    /// A forced install-failure for live verification of the About pane (#210), from
    /// `TOKENPACE_FAKE_FAILURE=<stage>:<reason>`; the tag comes from `TOKENPACE_FAKE_LATEST` or a
    /// placeholder. Never writes UserDefaults; `nil` for a normal run or an unparsable value.
    static let forcedUpdateFailure: LastUpdateFailure? = {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TOKENPACE_FAKE_FAILURE"], !raw.isEmpty,
              let sep = raw.firstIndex(of: ":") else { return nil }
        let stageRaw = String(raw[raw.startIndex..<sep])
        let reason = String(raw[raw.index(after: sep)...])
        guard let stage = LastUpdateFailure.Stage(rawValue: stageRaw), !reason.isEmpty else { return nil }
        let tag = env["TOKENPACE_FAKE_LATEST"].flatMap { $0.isEmpty ? nil : $0 } ?? "v\(TokenPaceKit.version)"
        return LastUpdateFailure(tag: tag, stage: stage, reason: reason)
    }()

    /// Forced deferral reasons for live verification of the About pane (#221), from
    /// `TOKENPACE_FAKE_DEFERRAL=battery,metered,space` (any subset; the row renders them in
    /// `allCases` order regardless). Never writes UserDefaults. `nil` for a normal run; unknown
    /// tokens are ignored.
    static let forcedDeferralReasons: [UpdateDeferralReason]? = {
        guard let raw = ProcessInfo.processInfo.environment["TOKENPACE_FAKE_DEFERRAL"], !raw.isEmpty
        else { return nil }
        let tokens = Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        let reasons = UpdateDeferralReason.allCases.filter { reason in
            switch reason {
            case .onBattery:         return tokens.contains("battery")
            case .meteredNetwork:    return tokens.contains("metered")
            case .insufficientSpace: return tokens.contains("space")
            }
        }
        return reasons.isEmpty ? nil : reasons
    }()

    /// Forced archive gates for live verification of the Sessions-backup hints (#306), from
    /// `TOKENPACE_FAKE_ARCHIVE_GATE=battery,space` (either, both). Never writes UserDefaults; `nil`
    /// for a normal run. Forces only the **display** — the poll still runs and "Archive now" still
    /// archives, so the button stays testable.
    static let forcedArchiveGate: (battery: Bool, space: ArchiveSpaceVerdict)? = {
        guard let raw = ProcessInfo.processInfo.environment["TOKENPACE_FAKE_ARCHIVE_GATE"], !raw.isEmpty
        else { return nil }
        let tokens = Set(raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        // Plausible figures, so the forced state reads like a real one in the log line beside it.
        let space: ArchiveSpaceVerdict = tokens.contains("space")
            ? .blockedInsufficientSpace(needBytes: 12_000_000_000, freeBytes: 3_000_000_000)
            : .proceed
        let battery = tokens.contains("battery")
        guard battery || space != .proceed else { return nil }
        return (battery, space)
    }()

    // MARK: Computed enablement

    var launchToggleEnabled: Bool { inAppBundle }
    /// The hint under the launch-at-login switch. On a dev build the feature can never work, so it
    /// shows the shared "Unavailable in development builds." line; in a real `.app` it is empty
    /// unless a toggle failed, then a recovery hint.
    var launchHint: (text: String, devBuild: Bool) {
        if !inAppBundle {
            return ("Unavailable in development builds.", true)
        }
        if launchToggleFailed {
            return ("Couldn't enable launch at login. Reinstall TokenPace.app in /Applications and "
                  + "open it from Finder/Launchpad, or add it manually in System Settings → General → "
                  + "Login Items.", false)
        }
        return ("", false)
    }

    var webDesktopRadioEnabled: Bool { webDesktopEnabled }

    /// The live Appearance config assembled from the model's own (observable) fields, so it stays
    /// reactive under `@Observable` and re-lights the preset control on any toggle/picker change.
    private var liveAppearanceValues: AppearancePresetValues {
        AppearancePresetValues(
            colorsTell: colorsTell,
            hideTop5hBar: hideTop5hBar,
            showServiceStatusDot: showServiceDot,
            modelLimitsVisibility: showPerModelLimits,
            extraUsageVisibility: showExtraUsage,
            menuBarStyle: menuBarStyle,
            dropdownStyle: dropdownStyle)
    }

    // MARK: Appearance presets — preview, then apply

    /// The preset currently being **previewed**, or `nil` when the widget shows the stored setup.
    /// Mirrors `PersistedConfig`'s overlay so `@Observable` (invisible to a plain enum's static var)
    /// has something to observe and the radio list re-lights on every click.
    private(set) var previewedPreset: AppearancePreset?

    /// Which radio row is selected — a previewed preset, or the stored setup.
    var selectedAppearanceChoice: AppearanceChoice {
        AppearanceChoice.selected(stored: storedAppearanceValues, previewing: previewedPreset)
    }

    /// The preset the **stored** setup happens to equal, for the `· same as Chill preset` suffix.
    /// `nil` once the user has made a combination of their own.
    var storedPresetName: AppearancePreset? {
        AppearanceChoice.storedPresetName(storedAppearanceValues)
    }

    /// Whether `Apply` on the previewed row would change anything.
    var canApplyPreviewedPreset: Bool {
        AppearanceChoice.canApply(stored: storedAppearanceValues, previewing: previewedPreset)
    }

    /// The stored Appearance values, read past the preview overlay — everything this screen asks
    /// (selected row, suffix, whether `Apply` does anything) is about the *stored* setup.
    private var storedAppearanceValues: AppearancePresetValues {
        // Touch the observable fields so SwiftUI re-evaluates after an edit on a child page;
        // `PersistedConfig` alone is not observable.
        _ = liveAppearanceValues
        return PersistedConfig.persistedAppearanceValues
    }

    /// Disabled on a dev build — authorization is impossible there.
    var backToWorkMasterEnabled: Bool { authState != .dev }
    var notifyDependentsEnabled: Bool { backToWorkMasterEnabled && backToWorkEnabled }
    /// The Notifications pane surfaces this once as a banner above the whole section, since it gates
    /// every notification alike.
    var notificationsDevBuild: Bool { authState == .dev }
    /// Empty in the authorized / not-yet-decided case. The dev-build case is handled by
    /// `notificationsDevBuild`, not here.
    var backToWorkHint: String {
        switch authState {
        case .denied:
            return "Notifications are turned off for TokenPace. Enable them in System Settings → "
                 + "Notifications → TokenPace."
        case .dev, .authorized, .notDetermined:
            return ""
        }
    }
    /// Live "Nh window" / "Nh Mm window" duration label from the two pickers (handles wrap + whole-day).
    var notifyWindowLengthText: String {
        let minutes = NotificationSchedule.windowLengthMinutes(
            startMinute: notifyStartMinute, endMinute: notifyEndMinute)
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h window" : "\(h)h \(m)m window"
    }

    var installAutoEnabled: Bool { automaticUpdateChecks && inAppBundle }
    /// Shown only when periodic checks are on. A non-empty `devBuild` flag drives the ⚠️ styling.
    var installAutoHint: (text: String, devBuild: Bool) {
        if !inAppBundle {
            return ("Unavailable in development builds.", true)
        }
        return ("On by default: downloads and installs a newer release in the background, then "
              + "restarts. If anything fails, the menu shows a \u{201C}New version available\u{201D} "
              + "item linking to the release instead.", false)
    }

    /// The ⚠️ line explaining why an available update hasn't installed (#221), or `nil`.
    var deferralExplanation: String? {
        UpdateDeferralReason.pendingExplanation(for: deferralReasons)
    }

    /// `""` when nothing blocks — the empty-string idiom, so `SettingsHint` renders nothing.
    var archiveSpaceHint: String {
        ArchiveSpacePlan.blockedExplanation(for: archiveSpaceBlock) ?? ""
    }

    /// Read live rather than pushed: the gate lives in `pollArchiveIfDue` and returns before the
    /// archiver runs, so there's no outcome to carry it back. `@Observable` won't re-render on a power
    /// change; the line refreshes on the next `refreshArchiveStatus()`. Don't add an IOKit observer
    /// for this — a few seconds of lag isn't worth a new subscription lifecycle here.
    var archiveOnBattery: Bool {
        if let forced = SettingsModel.forcedArchiveGate { return forced.battery }
        return archiveEnabled && archiveDestination != nil && !PowerSource.isOnACPower
    }

    /// Suppressed while a space block is showing — a full disk is a hard stop and the battery is a
    /// soft one, so showing both would imply plugging in helps, which it does not.
    var archiveBatteryHint: String {
        guard archiveSpaceHint.isEmpty, archiveOnBattery else { return "" }
        return "Backup will resume when you plug in."
    }

    /// Power/metered gates are deliberately **not** consulted: bypassing them is the button's whole
    /// purpose. A disk too full still lets the user click; the install then declines and logs why.
    var canInstallNow: Bool {
        // `TOKENPACE_FAKE_DEFERRAL` shows the button regardless of build, so the row under
        // verification isn't hidden by the real bundle check. Clicking it still declines and logs.
        if SettingsModel.forcedDeferralReasons != nil { return true }
        guard inAppBundle, let release = latestRelease else { return false }
        return UpdateAssetSelector.selectZIP(from: release) != nil
    }

    // MARK: Sync from config / system (called by the controller's show())

    /// Re-read every field from `PersistedConfig` / the system into the model. Goes straight to the
    /// stored properties, bypassing the `set…` methods, so a re-sync never re-persists or re-fires a
    /// callback.
    func syncFromConfig() {
        launchToggleFailed = false
        let status = LaunchAtLoginController.currentStatus()
        launchAtLogin = LaunchAtLogin.toggleState(for: status)
        pausePolling = PersistedConfig.pausePollingWhenScreenLocked

        colorsTell = PersistedConfig.colorsTell
        hideTop5hBar = PersistedConfig.hideTop5hBar
        showPerModelLimits = PersistedConfig.showPerModelLimits
        showExtraUsage = PersistedConfig.showExtraUsage
        showServiceDot = PersistedConfig.showServiceStatusDot
        menuBarHiddenProviders = PersistedConfig.menuBarHiddenProviders
        menuBarStyle = PersistedConfig.menuBarStyle
        dropdownStyle = PersistedConfig.dropdownStyle

        // Straight assignments, not `set…` methods: a re-sync must not re-fire
        // `onProviderMonitoringChange`/`onGitHubMonitoringChange`/`onCodexMonitoringChange`, or
        // opening Settings would kick a poll.
        let pm = PersistedConfig.providerMonitoring
        usageApiEnabled = pm.usageApiEnabled
        claudeCodeEnabled = pm.services.claudeCodeEnabled
        webDesktopEnabled = pm.services.webDesktopEnabled
        webDesktopMode = pm.services.webDesktopMode
        githubDevelopmentServicesEnabled = PersistedConfig.githubMonitoring.developmentServicesEnabled
        codexMonitoring = PersistedConfig.codexMonitoring

        backToWorkEnabled = PersistedConfig.backToWorkEnabled
        extraUsageNotifyEnabled = PersistedConfig.extraUsageNotifyEnabled
        incidentMaxAgeHours = PersistedConfig.incidentMaxAge.map { Int(($0 / 3600).rounded()) } ?? 0
        notifyStartMinute = PersistedConfig.notifyWindowStartMinute
        notifyEndMinute = PersistedConfig.notifyWindowEndMinute
        suppressDays = PersistedConfig.notifySuppressDays
        refreshAuthState()

        automaticUpdateChecks = PersistedConfig.automaticUpdateChecks
        installAutomatically = PersistedConfig.installUpdatesAutomatically
        lastUpdateFailure = Self.forcedUpdateFailure ?? PersistedConfig.lastUpdateFailure

        archiveEnabled = PersistedConfig.archiveEnabled
        refreshArchiveStatus()

        awaitingInputEnabled = PersistedConfig.awaitingInputEnabled

        journalEnabled = PersistedConfig.journalEnabled
        showOptionHint = PersistedConfig.showOptionHint
        alwaysShowActionItems = PersistedConfig.alwaysShowActionItems
    }

    // MARK: Setters (persist first, then fire the callback — the ordering invariant)

    func setPausePolling(_ on: Bool) {
        pausePolling = on
        PersistedConfig.pausePollingWhenScreenLocked = on
        AppLogger.lifecycle.notice("screen-lock-pause: setting set \(on, privacy: .public)")
        onPausePollingChange?(on)
    }

    func setAwaitingInputEnabled(_ on: Bool) {
        awaitingInputEnabled = on
        PersistedConfig.awaitingInputEnabled = on
        onAwaitingInputEnabledChange?(on)
    }

    /// No callback: the poll seam reads `PersistedConfig.journalEnabled` live on each write.
    func setJournalEnabled(_ on: Bool) {
        journalEnabled = on
        PersistedConfig.journalEnabled = on
        AppLogger.lifecycle.notice("journal: enabled set \(on, privacy: .public)")
    }

    /// No callback: `menuWillOpen` re-reads `PersistedConfig.showOptionHint` on every open.
    func setShowOptionHint(_ on: Bool) {
        showOptionHint = on
        PersistedConfig.showOptionHint = on
        AppLogger.lifecycle.notice("dropdown: option hint set \(on, privacy: .public)")
    }

    /// No callback either, for the same reason: `menuWillOpen` re-reads the key on every open, and the
    /// menu built at launch is seeded from it. No `dropPreviewBeforeEdit()` — that belongs to the
    /// preset-backed setters, and this key is deliberately not one of them.
    func setAlwaysShowActionItems(_ on: Bool) {
        alwaysShowActionItems = on
        PersistedConfig.alwaysShowActionItems = on
        AppLogger.lifecycle.notice("dropdown: always show actions set \(on, privacy: .public)")
    }

    func setColorAdvice(_ mode: ColorAdvice) {
        dropPreviewBeforeEdit()
        colorsTell = mode
        PersistedConfig.colorsTell = mode
        AppLogger.lifecycle.notice("colors-tell: set \(mode.rawValue, privacy: .public)")
        onColorAdviceChange?(mode)
    }

    func setTopBarHiding(_ mode: TopBarHiding) {
        dropPreviewBeforeEdit()
        hideTop5hBar = mode
        PersistedConfig.hideTop5hBar = mode
        AppLogger.lifecycle.notice("hide-top-5h-bar: set \(mode.rawValue, privacy: .public)")
        onTopBarHidingChange?(mode)
    }

    func setModelLimitsVisibility(_ mode: PopupSectionVisibility) {
        dropPreviewBeforeEdit()
        showPerModelLimits = mode
        PersistedConfig.showPerModelLimits = mode
        AppLogger.lifecycle.notice("show-per-model-limits: set \(mode.rawValue, privacy: .public)")
        onModelLimitsVisibilityChange?(mode)
    }

    func setExtraUsageVisibility(_ mode: PopupSectionVisibility) {
        dropPreviewBeforeEdit()
        showExtraUsage = mode
        PersistedConfig.showExtraUsage = mode
        AppLogger.lifecycle.notice("show-extra-usage: set \(mode.rawValue, privacy: .public)")
        onExtraUsageVisibilityChange?(mode)
    }

    func setShowServiceDot(_ on: Bool) {
        dropPreviewBeforeEdit()
        showServiceDot = on
        PersistedConfig.showServiceStatusDot = on
        AppLogger.lifecycle.notice("service-status-dot: set \(on, privacy: .public)")
        onServiceDotChange?(on)
    }

    /// The providers the "Providers to display" checkboxes list — those collecting usage, in
    /// ``ProviderID/displayOrder``. A status-only provider draws no bars, so it gets no row.
    var menuBarProviderChoices: [ProviderID] {
        ProviderID.displayOrder.filter { provider in
            switch provider {
            case .claude: return usageApiEnabled
            case .codex:  return codexMonitoring.usageEnabled
            case .github: return false
            }
        }
    }

    /// Check or uncheck one provider's menu-bar block (ADR-0128). Unchecking every provider is
    /// allowed here; the widget still draws the first block, since an empty item reads as a crash.
    func setShowsInMenuBar(_ provider: ProviderID, _ shown: Bool) {
        dropPreviewBeforeEdit()
        if shown { menuBarHiddenProviders.remove(provider) }
        else     { menuBarHiddenProviders.insert(provider) }
        PersistedConfig.menuBarHiddenProviders = menuBarHiddenProviders
        AppLogger.lifecycle.notice(
            "menu-bar-providers: \(provider.rawValue, privacy: .public) set \(shown, privacy: .public)")
        onMenuBarProvidersChange?(menuBarHiddenProviders)
    }

    /// Touches the menu-bar surface only (#224, #329) — the dropdown keeps whatever it was set to.
    func setMenuBarStyle(_ style: BarStyle) {
        dropPreviewBeforeEdit()
        menuBarStyle = style
        PersistedConfig.menuBarStyle = style
        AppLogger.lifecycle.notice("menu-bar-style: set \(style.rawValue, privacy: .public)")
        onMenuBarStyleChange?(style)
    }

    /// Mirror of ``setMenuBarStyle(_:)`` for the popup's own segmented control (#329).
    func setDropdownStyle(_ style: BarStyle) {
        dropPreviewBeforeEdit()
        dropdownStyle = style
        PersistedConfig.dropdownStyle = style
        AppLogger.lifecycle.notice("dropdown-style: set \(style.rawValue, privacy: .public)")
        onDropdownStyleChange?(style)
    }

    /// **Preview** a preset: draw it on the live widget without writing anything. Goes into
    /// `PersistedConfig`'s overlay, which every Appearance getter consults, so the menu-bar widget,
    /// dropdown and preview window all pick it up from ``fireAppearanceCallbacks()``.
    func previewPreset(_ preset: AppearancePreset) {
        previewedPreset = preset
        PersistedConfig.beginAppearancePreview(preset.values)
        syncFromConfig()
        AppLogger.lifecycle.notice("appearance preview: \(preset.rawValue, privacy: .public)")
        fireAppearanceCallbacks()
    }

    /// What closing the Settings window does, and clicking the "My setup" row. No-op when nothing is
    /// being previewed.
    func endPreview() {
        guard previewedPreset != nil else { return }
        previewedPreset = nil
        PersistedConfig.endAppearancePreview()
        syncFromConfig()
        AppLogger.lifecycle.notice("appearance preview: ended")
        fireAppearanceCallbacks()
    }

    /// The `Apply` button. Writes all seven keys, then drops the overlay — **in that order**: dropping
    /// it first would repaint both surfaces with the old stored setup for one frame (a flicker back).
    func applyPreviewedPreset() {
        guard let preset = previewedPreset else { return }
        PersistedConfig.apply(preset)
        previewedPreset = nil
        PersistedConfig.endAppearancePreview()
        syncFromConfig()
        AppLogger.lifecycle.notice("appearance preset applied: \(preset.rawValue, privacy: .public)")
        fireAppearanceCallbacks()
    }

    /// Drop a live preview before an individual Appearance option is written. Without this, a setter
    /// called during a preview would persist its own field while the other six stayed shadowed by the
    /// overlay — the screen would show a mixture. No-op when no preview is up.
    private func dropPreviewBeforeEdit() {
        guard previewedPreset != nil else { return }
        previewedPreset = nil
        PersistedConfig.endAppearancePreview()
        syncFromConfig()
        AppLogger.lifecycle.notice("appearance preview: ended")
    }

    /// The **stored** Appearance config as clipboard-ready pretty-printed JSON (#257), behind the copy
    /// button on the "My setup" row. Returns the string rather than writing the pasteboard, keeping
    /// this class free of AppKit; the pane owns the `NSPasteboard` write. Reads past the preview
    /// overlay on purpose — copying a preset the user is merely trying on would contradict the row.
    func appearanceConfigJSON() -> String {
        let stored = PersistedConfig.persistedAppearanceValues
        return AppearanceConfigExport.json(
            values: stored,
            preset: AppearancePreset.matching(stored),
            appVersion: TokenPaceKit.version)
    }

    /// Shared by the reset and preset paths, which both mutate all keys at once and re-render as a
    /// batch.
    private func fireAppearanceCallbacks() {
        onColorAdviceChange?(colorsTell)
        onTopBarHidingChange?(hideTop5hBar)
        onModelLimitsVisibilityChange?(showPerModelLimits)
        onExtraUsageVisibilityChange?(showExtraUsage)
        onServiceDotChange?(showServiceDot)
        onMenuBarProvidersChange?(menuBarHiddenProviders)
        onMenuBarStyleChange?(menuBarStyle)
        onDropdownStyleChange?(dropdownStyle)
        onAwaitingInputAppearanceChange?()   // #233: a preset/reset may flip the menu-bar copy
    }

    /// One commit for both halves on purpose: `Claude API`'s locked state is derived from the two of
    /// them together, so the shell must never see one without the other.
    func commitProviderMonitoring() {
        let config = providerMonitoring
        PersistedConfig.providerMonitoring = config
        onProviderMonitoringChange?(config)
    }

    func toggleLaunchAtLogin(_ wantOn: Bool) {
        do {
            if wantOn { try LaunchAtLoginController.enable() }
            else      { try LaunchAtLoginController.disable() }
            launchToggleFailed = false
            AppLogger.lifecycle.notice("launch-at-login: user set \(wantOn, privacy: .public)")
        } catch {
            // Remember the failure so the hint explains it (#69); the status re-read below rolls it back.
            launchToggleFailed = true
            AppLogger.lifecycle.error(
                "launch-at-login: toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        let status = LaunchAtLoginController.currentStatus()
        if LaunchAtLogin.needsSystemSettings(status) {
            LaunchAtLoginController.openLoginItemsSettings()
        }
        launchAtLogin = LaunchAtLogin.toggleState(for: status)
    }

    /// Not routed through `commitProviderMonitoring()` — that one exists to write Claude's two halves
    /// atomically because `claudeApiLocked` is derived from both; GitHub has no such derived state,
    /// and sharing the path would re-fire Claude's callback on every GitHub toggle.
    func setGitHubDevelopmentServices(_ on: Bool) {
        githubDevelopmentServicesEnabled = on
        let config = githubMonitoring
        PersistedConfig.githubMonitoring = config
        AppLogger.lifecycle.notice("github: development services set \(on, privacy: .public)")
        onGitHubMonitoringChange?(config)
    }

    /// Turn one Codex service on or off. Takes the ``ServiceID`` rather than a per-flag setter, so
    /// the page can generate a row per service from `StatusHealth.codexServices` — five hand-written
    /// setters would be five chances for a switch and its flag to disagree.
    func setCodexService(_ id: ServiceID, _ on: Bool) {
        codexMonitoring.setEnabled(id, on)
        let config = codexMonitoring
        PersistedConfig.codexMonitoring = config
        AppLogger.lifecycle.notice(
            "codex: service \(String(describing: id), privacy: .public) set \(on, privacy: .public)")
        onCodexMonitoringChange?(config)
    }

    /// Turn the Codex quota collection on or off. Its own setter rather than a sixth `ServiceID`:
    /// this switch governs a local subprocess, not a status-page component, and `isEnabled` answers
    /// only for the latter.
    func setCodexUsage(_ on: Bool) {
        codexMonitoring.usageEnabled = on
        let config = codexMonitoring
        PersistedConfig.codexMonitoring = config
        AppLogger.lifecycle.notice("codex: quota collection set \(on, privacy: .public)")
        onCodexMonitoringChange?(config)
    }

    func setBackToWork(_ on: Bool) {
        backToWorkEnabled = on
        PersistedConfig.backToWorkEnabled = on
        AppLogger.lifecycle.notice("back-to-work: enabled set \(on, privacy: .public)")
        if on {
            // Lazily request authorization on first enable, then refresh the hint with the result.
            onBackToWorkEnabled?({ [weak self] state in self?.applyAuthState(state) })
        } else {
            refreshAuthState()
        }
    }

    /// Fire the "Back to work!" notification on demand from the Settings "Try" button (#193). Forces a
    /// post through the normal delivery channel, bypassing the edge-detection and quiet-hours gates.
    func tryBackToWork() {
        AppLogger.lifecycle.notice("back-to-work: try (forced) notification")
        onTryBackToWork?()
    }

    /// Fire the "Switching to Extra usage" notification on demand from its Settings "Try" button.
    /// Forces a post through the normal delivery channel, bypassing edge-detection and quiet hours.
    func tryExtraUsage() {
        AppLogger.lifecycle.notice("extra-usage: try (forced) notification")
        onTryExtraUsage?()
    }

    /// Fires **three** notifications — update, fix-deployed ending, recovered ending — since judging
    /// their wording means seeing them together.
    func previewIncidentNotifications() {
        onPreviewIncidents?()
    }

    func setExtraUsageNotify(_ on: Bool) {
        extraUsageNotifyEnabled = on
        PersistedConfig.extraUsageNotifyEnabled = on
        AppLogger.lifecycle.notice("extra-usage: notify enabled set \(on, privacy: .public)")
        if on {
            // Shares one authorization grant with "Back to work" — request lazily on first enable.
            onBackToWorkEnabled?({ [weak self] state in self?.applyAuthState(state) })
        } else {
            refreshAuthState()
        }
    }

    /// `0` means no limit (#279).
    func setIncidentMaxAgeHours(_ hours: Int) {
        incidentMaxAgeHours = hours
        PersistedConfig.incidentMaxAge = hours > 0 ? TimeInterval(hours) * 3600 : nil
        AppLogger.lifecycle.notice("incident: max age set \(hours, privacy: .public)h")
        // Reuse the provider-monitoring callback: it re-resolves the status, and with it the
        // visible incidents.
        commitProviderMonitoring()
    }

    func setNotifyWindow(start: Int, end: Int) {
        notifyStartMinute = start
        notifyEndMinute = end
        PersistedConfig.notifyWindowStartMinute = start
        PersistedConfig.notifyWindowEndMinute = end
        AppLogger.lifecycle.notice(
            "back-to-work: time window set \(start, privacy: .public)–\(end, privacy: .public)")
    }

    func setSuppressDays(_ days: SuppressDays) {
        suppressDays = days
        PersistedConfig.notifySuppressDays = days
        AppLogger.lifecycle.notice("back-to-work: suppress set \(days.rawValue, privacy: .public)")
    }

    func setAutomaticUpdateChecks(_ on: Bool) {
        automaticUpdateChecks = on
        PersistedConfig.automaticUpdateChecks = on
        AppLogger.lifecycle.notice("update: automatic checks set \(on, privacy: .public)")
    }

    func setInstallAutomatically(_ on: Bool) {
        installAutomatically = on
        PersistedConfig.installUpdatesAutomatically = on
        AppLogger.lifecycle.notice("update-install: auto set \(on, privacy: .public)")
    }

    func checkForUpdatesNow() { onCheckForUpdatesNow?() }

    func installUpdateNow() {
        AppLogger.lifecycle.notice("update-install: user requested an immediate install")
        onInstallUpdateNow?()
    }

    func setArchiveEnabled(_ on: Bool) {
        if on, PersistedConfig.archiveDestination == nil {
            // No folder yet → prompt; if the user cancels, flip the toggle back off.
            chooseArchiveFolder()
            if PersistedConfig.archiveDestination == nil {
                archiveEnabled = false
                PersistedConfig.archiveEnabled = false
                refreshArchiveStatus()
                return
            }
        }
        archiveEnabled = on
        PersistedConfig.archiveEnabled = on
        AppLogger.lifecycle.notice("archive: enabled set \(on, privacy: .public)")
        refreshArchiveStatus()
    }

    /// Present the folder picker (imperative `NSOpenPanel`, invoked from a SwiftUI button action).
    func chooseArchiveFolder() {
        guard let path = FolderPicker.choose(current: PersistedConfig.archiveDestination) else { return }
        PersistedConfig.archiveDestination = path
        AppLogger.lifecycle.notice("archive: destination chosen")
        refreshArchiveStatus()
        // Sync into the newly chosen folder right away, so the status doesn't sit at "Not archived
        // yet". The sync runs in the shell; its completion refreshes the status.
        onArchiveNow?()
    }

    func archiveNow() { onArchiveNow?() }

    func openRepo() { NSWorkspaceOpener.open(SettingsLinks.repoURL) }

    /// `"v0.55.0"` → `"0.55.0"` — the About pane shows bare `X.Y.Z` (#210), URLs keep the real tag.
    static func displayTag(_ tag: String) -> String {
        guard let first = tag.first, first == "v" || first == "V" else { return tag }
        return String(tag.dropFirst())
    }

    /// Also the manual fallback since the "Download" button was dropped (#221) — the release page is
    /// where a hand-download starts.
    func openReleaseNotes(tag: String) {
        NSWorkspaceOpener.open(GitHubReleaseClient.releaseNotesURL(tag: tag).absoluteString)
    }

    // MARK: Background-driven mutators (safe while the window is closed — they touch model state only)

    func updateAvailability(_ release: GitHubRelease?) {
        latestRelease = release
    }

    /// A forced set from `TOKENPACE_FAKE_DEFERRAL` wins, so live verification isn't overwritten by
    /// the real (unblocked) environment on the next check.
    func updateDeferral(_ reasons: [UpdateDeferralReason]) {
        deferralReasons = SettingsModel.forcedDeferralReasons ?? reasons
    }

    /// Reflect the last archive run's low-space verdict (#306). A forced value from
    /// `TOKENPACE_FAKE_ARCHIVE_GATE` wins, so a real (unblocked) run can't wipe the state being
    /// verified — the same contract as `updateDeferral`.
    func updateArchiveBlock(_ verdict: ArchiveSpaceVerdict) {
        archiveSpaceBlock = SettingsModel.forcedArchiveGate?.space ?? verdict
    }

    func refreshArchiveStatus() {
        archiveDestination = PersistedConfig.archiveDestination
        archiveStatusText = Self.composeArchiveStatus(
            destination: PersistedConfig.archiveDestination,
            lastSync: PersistedConfig.lastArchiveSync,
            summary: archiveSummaryProvider?())
    }

    // MARK: Auth-state plumbing

    private func refreshAuthState() {
        BackToWorkNotifier.currentAuthState { [weak self] state in self?.applyAuthState(state) }
    }

    private func applyAuthState(_ state: BackToWorkNotifier.AuthState) {
        authState = state
        // On a dev build authorization is impossible, so force both notification toggles off.
        if state == .dev {
            if backToWorkEnabled {
                backToWorkEnabled = false
                PersistedConfig.backToWorkEnabled = false
            }
            if extraUsageNotifyEnabled {
                extraUsageNotifyEnabled = false
                PersistedConfig.extraUsageNotifyEnabled = false
            }
        }
    }
}
