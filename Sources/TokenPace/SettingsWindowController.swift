import AppKit
import TokenPaceKit

// MARK: - SettingsWindowController

/// The "Settings…" window (#14): a small, single-instance panel reached from the bottom
/// of the popup menu. It carries the minimal Phase-1 settings the user asked for — a launch-at-login
/// toggle, the app version, and a link to the repository.
///
/// This window intentionally exists despite SPEC.md's "Без екрана налаштувань" (no settings screen):
/// a launch-at-login toggle needs *some* affordance, and a window reads more discoverably than a
/// menu-item checkbox (ADR-0012).
///
/// Opened from an accessory (menu-bar) app, so it relies on `NSApp.activate` + a floating window
/// level to come to the front, rather than switching the activation policy to `.regular` (which
/// would flash a Dock icon for one window — see `show()`).
@MainActor
final class SettingsWindowController: NSWindowController {

    private static let repoURL = URL(string: "https://github.com/artem-from-ua/tokenpace")!

    /// The scroll view wrapping all settings content (#110) — the window scrolls when the content is
    /// taller than the capped window height. Retained so `resizeToFit()` can read its document view.
    private var scrollView: NSScrollView!

    private enum Metrics {
        static let width: CGFloat = 400
        static let padding: CGFloat = 20
        static let rowSpacing: CGFloat = 12
        /// Leading inset of the radio group nested under the "Claude WEB/Desktop" checkbox (#89).
        static let nestIndent: CGFloat = 18
    }

    /// Called when the user changes the monitored-services selection (#89), with the new config —
    /// wired by `AppDelegate.openSettings` to re-poll the status page immediately. The config is
    /// already persisted (via `PersistedConfig`) by the time this fires.
    var onMonitoredServicesChange: ((MonitoredServices) -> Void)?

    /// Called when the user clicks "Check now" (#37) — wired by `AppDelegate.openSettings` to run an
    /// immediate update check that bypasses the 12 h cadence.
    var onCheckForUpdatesNow: (() -> Void)?

    /// Called when the user toggles "Calm MenuBar Widget colors" (#105), with the new on/off state —
    /// wired by `AppDelegate.openSettings` to re-render the menu-bar image immediately. The choice is
    /// already persisted (via `PersistedConfig`) by the time this fires.
    var onCalmColorsChange: ((Bool) -> Void)?

    /// Called when the user changes the menu-bar "Reset countdown" mode (#103), with the new mode —
    /// wired by `AppDelegate.openSettings` to re-render the menu-bar image immediately. Already
    /// persisted (via `PersistedConfig`) by the time this fires.
    var onResetCountdownModeMenuBarChange: ((ResetCountdownMode) -> Void)?

    /// Called when the user toggles "Show service status dot on issues" (#31), with the new on/off
    /// state — wired by `AppDelegate.openSettings` to re-render the menu-bar image immediately (the
    /// dot changes both what is drawn and the item width). Already persisted (via `PersistedConfig`)
    /// by the time this fires.
    var onServiceDotChange: ((Bool) -> Void)?

    /// Called when the user toggles "Hide 7-day bar when calm" (#94), with the new on/off state —
    /// wired by `AppDelegate.openSettings` to re-render the menu-bar image immediately (the toggle
    /// changes what is drawn — the 7-day bar and the 5h bar's vertical centring). Already persisted
    /// (via `PersistedConfig`) by the time this fires.
    var onHideCalmSevenDayChange: ((Bool) -> Void)?

    /// Called when the user toggles "Pause polling while the screen is locked" (#114), with the new
    /// on/off state — wired by `AppDelegate.openSettings` to un-park the loop when turned off. Already
    /// persisted (via `PersistedConfig`) by the time this fires; the observer reads the pref live.
    var onPausePollingChange: ((Bool) -> Void)?

    /// Called when the user clicks "Archive now" (#110) — wired by `AppDelegate.openSettings` to run
    /// an immediate archive sync that bypasses the daily cadence.
    var onArchiveNow: (() -> Void)?

    /// Provides the last archive summary for the status line (#110), read from the app on each
    /// `show()` / `updateArchiveStatus()`. `nil` until the first sync of the session completes.
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)?

    /// The "Archive session logs to a folder" checkbox (#110), synced from `PersistedConfig` on every
    /// `show()`.
    private var archiveToggle: NSButton!
    /// The "Choose…" button that opens an `NSOpenPanel` to pick the archive folder (#110).
    private var archiveChooseButton: NSButton!
    /// The "Archive now" button (#110), enabled only when the feature is on and a folder is set.
    private var archiveNowButton: NSButton!
    /// Shows the chosen destination path, or "No folder selected" (#110).
    private var archivePathLabel: NSTextField!
    /// Shows "Last archived: … · N updated · M files · <size>", or a pending hint (#110). Files and
    /// size come from a live scan of the archive folder; "N updated" only when a fresh sync summary
    /// is available.
    private var archiveStatusLabel: NSTextField!

    /// The "Check for updates automatically" checkbox (#37), synced from `PersistedConfig` on every
    /// `show()`.
    private var updatesToggle: NSButton!
    /// The "Install updates automatically" checkbox (#122), nested under `updatesToggle`; synced from
    /// `PersistedConfig` on every `show()`. Enabled only while the parent is on and this is a real
    /// `.app` bundle.
    private var installAutomaticallyToggle: NSButton!
    /// Explanatory line under `installAutomaticallyToggle` (#122): what it does and its `/Applications`
    /// precondition, or why it is unavailable on a dev build. Text set in `syncUpdatesFromConfig`.
    private var installAutomaticallyHint: NSTextField!
    /// The "Check now" button (#37).
    private var checkNowButton: NSButton!
    /// The "Update available: vX.Y.Z — Download" line (#37), hidden until a newer release is known.
    private var updateLineLabel: NSTextField!
    /// The "Download" link button next to `updateLineLabel` (#37); hidden alongside it.
    private var updateDownloadLink: NSButton!
    /// The row holding the update-available label + Download link; hidden as a whole when up to date so
    /// the stack drops it from layout (no empty gap under "Check now").
    private var updateRow: NSStackView!
    /// The release currently offered by the update line, or `nil` when up to date. Drives the
    /// Download link's target.
    private var latestRelease: GitHubRelease?

    /// The launch-at-login checkbox — its state is synced from the live `SMAppService` status every
    /// time the window is shown (the user may have changed it in System Settings meanwhile).
    private var launchToggle: NSButton!

    /// The "Pause polling while the screen is locked" checkbox (#114), synced from `PersistedConfig`
    /// on every `show()`.
    private var pausePollingToggle: NSButton!

    /// The "Calm MenuBar Widget colors" checkbox (#105), synced from `PersistedConfig` on every
    /// `show()`.
    private var calmColorsToggle: NSButton!

    /// The "Hide 7-day bar when calm" checkbox (#94), synced from `PersistedConfig` on every `show()`.
    private var hideCalmSevenDayToggle: NSButton!

    /// The "Display reset countdown" controls (#103): a three-radio exclusive group plus one nested
    /// checkbox. The radios pick the coarse intent — always show / smart / never — and the checkbox
    /// under the middle ("smart") radio decides the one bit that separates ``ResetCountdownMode``'s
    /// two smart cases: whether a *distant* (≥24 h) well-ahead-of-pace 7d reset is included
    /// (``ResetCountdownMode/showDistant7d``) or dropped (``ResetCountdownMode/hideDistant7d``).
    /// Collapsing the four flat radios this way makes the sole difference between the two smart modes
    /// a single toggle instead of two near-identical long labels. Synced from `PersistedConfig` on
    /// every `show()`.
    private var resetAlwaysRadio: NSButton!
    private var resetSmartRadio: NSButton!
    /// Enabled only while `resetSmartRadio` is on; gates ``showDistant7d`` ↔ ``hideDistant7d``.
    private var resetIncludeDistantCheckbox: NSButton!
    private var resetNeverRadio: NSButton!

    /// The "Show service status dot on issues" checkbox (#31), synced from `PersistedConfig` on every
    /// `show()`.
    private var serviceDotToggle: NSButton!

    /// The "Claude Code" monitoring checkbox (#89).
    private var claudeCodeToggle: NSButton!
    /// The "Claude WEB/Desktop" monitoring checkbox (#89); gates the mode radios below it.
    private var webDesktopToggle: NSButton!
    /// The WEB/Desktop mode radios (#89): "Chat only" / "Chat and Cowork". Enabled only while
    /// `webDesktopToggle` is on.
    private var chatOnlyRadio: NSButton!
    private var chatAndCoworkRadio: NSButton!

    /// Explanatory line under the checkbox (`hintText(inAppBundle:)`). Three states: a `swift run`
    /// dev build is unavailable; an `.app` where a click just failed points at recovery; otherwise
    /// a neutral note.
    private var hintLabel: NSTextField!

    /// Whether the last toggle click failed to register in an `.app` bundle (e.g. an ad-hoc bundle
    /// SMAppService refuses). Drives the recovery hint; reset on a successful toggle or a fresh
    /// `show()` so a state the user has since fixed in System Settings is not shadowed by a stale
    /// failure. Only meaningful when the checkbox is enabled (i.e. in an `.app` bundle).
    private var lastToggleFailed = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 160),
            styleMask: [.titled, .closable],   // not .resizable — content is fixed-size
            backing: .buffered,
            defer: false)
        window.title = "TokenPace"
        window.level = .floating               // float above other apps' windows from a menu-bar app
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        self.init(window: window)
        buildContent()
    }

    /// Show or re-focus the window. Re-syncs the toggle from the system, brings the app forward, and
    /// centres on first display. Calling this while the window is already on screen just focuses it —
    /// the single instance is never duplicated (see `AppDelegate.openSettings`).
    func show() {
        lastToggleFailed = false   // a fresh open starts from the status-derived hint (#69)
        syncToggleFromSystem()
        pausePollingToggle.state = PersistedConfig.pausePollingWhenScreenLocked ? .on : .off
        syncMonitoredServicesFromConfig()
        calmColorsToggle.state = PersistedConfig.calmMenuBarColors ? .on : .off
        hideCalmSevenDayToggle.state = PersistedConfig.hideCalmSevenDayBar ? .on : .off
        syncResetCountdownFromConfig()
        serviceDotToggle.state = PersistedConfig.showServiceStatusDot ? .on : .off
        syncUpdatesFromConfig()
        archiveToggle.state = PersistedConfig.archiveEnabled ? .on : .off
        updateArchiveStatus()
        NSApp.activate(ignoringOtherApps: true)
        if !(window?.isVisible ?? false) { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Content

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ── General ───────────────────────────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("General"))

        launchToggle = NSButton(
            checkboxWithTitle: "Launch TokenPace at login",
            target: self,
            action: #selector(toggleLaunchAtLogin(_:)))
        stack.addArrangedSubview(launchToggle)

        // Explains the launch-at-login state; text is set in `syncToggleFromSystem` from the live
        // availability (a fixed-width wrap so the longer "unavailable" message stays readable).
        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hintLabel)
        hintLabel.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        pausePollingToggle = NSButton(
            checkboxWithTitle: "Pause polling while the screen is locked",
            target: self,
            action: #selector(togglePausePolling(_:)))
        stack.setCustomSpacing(12, after: hintLabel)   // separate from the launch-at-login group
        stack.addArrangedSubview(pausePollingToggle)

        // Explains the toggle: no usage-API calls while the screen is off; resumes on wake.
        let pausePollingHint = NSTextField(wrappingLabelWithString:
            "Skips usage polls while the screen is locked, off, or the screensaver is running, "
            + "and refreshes right away on unlock. System sleep always pauses regardless.")
        pausePollingHint.font = .systemFont(ofSize: 11)
        pausePollingHint.textColor = .secondaryLabelColor
        pausePollingHint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(pausePollingHint)
        pausePollingHint.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        stack.addArrangedSubview(sectionSeparator())

        // ── Menu bar widget (#105) ────────────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Menu bar widget"))

        calmColorsToggle = NSButton(
            checkboxWithTitle: "Calm MenuBar Widget colors",
            target: self,
            action: #selector(toggleCalmColors(_:)))
        stack.addArrangedSubview(calmColorsToggle)

        // Explains what the toggle does — warning colours and the service dot are deliberately spared.
        let calmHint = NSTextField(wrappingLabelWithString:
            "Shows blue/green/yellow pacing bars as white in the menu bar. "
            + "Warning colours and the service dot stay coloured.")
        calmHint.font = .systemFont(ofSize: 11)
        calmHint.textColor = .secondaryLabelColor
        calmHint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(calmHint)
        calmHint.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        // "Hide 7-day bar when calm" (#94): drop the 7-day bar while it is green/mild-yellow, leaving
        // the 5h bar centred alone — one fewer element on the tiny widget when the week is on track.
        hideCalmSevenDayToggle = NSButton(
            checkboxWithTitle: "Hide 7-day bar when calm",
            target: self,
            action: #selector(toggleHideCalmSevenDay(_:)))
        stack.setCustomSpacing(12, after: calmHint)   // separate this toggle from the calm-colours hint
        stack.addArrangedSubview(hideCalmSevenDayToggle)

        // Explains what stays visible — an orange/red 7-day bar is never hidden.
        let hideCalmHint = NSTextField(wrappingLabelWithString:
            "When the 7-day bar is green or mild-yellow, hides it and centres the 5-hour bar alone. "
            + "An orange or red 7-day bar always stays visible.")
        hideCalmHint.font = .systemFont(ofSize: 11)
        hideCalmHint.textColor = .secondaryLabelColor
        hideCalmHint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hideCalmHint)
        hideCalmHint.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        // "Display reset countdown" (#103): three radios pick the coarse intent, and a checkbox nested
        // under the middle ("smart") radio flips the one bit between the two smart modes. AppKit groups
        // radios sharing an `action` in one superview into an exclusive set; the vertical stack keeps
        // them a single group. The checkbox shares that action too, so any change routes through
        // `resetCountdownModeChanged`, which reads the whole group back into a `ResetCountdownMode`.
        let resetLabel = NSTextField(labelWithString: "Display reset countdown:")
        resetLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(resetLabel)
        stack.setCustomSpacing(12, after: hideCalmHint)   // separate the countdown sub-section from the hide-calm hint

        resetAlwaysRadio = NSButton(
            radioButtonWithTitle: "Always",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        resetSmartRadio = NSButton(
            radioButtonWithTitle: "When well ahead or limit reached",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        resetNeverRadio = NSButton(
            radioButtonWithTitle: "Never",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        // The "smart" radio's sub-option: whether a distant (≥24 h) well-ahead 7d reset is included.
        // Nesting is the same `indented(_:)` treatment the WEB/Desktop mode radios use.
        resetIncludeDistantCheckbox = NSButton(
            checkboxWithTitle: "Include distant 7d limit reset (≥ 24 h away)",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        let resetGroup = NSStackView(views: [
            resetAlwaysRadio,
            resetSmartRadio,
            indented(resetIncludeDistantCheckbox),
            resetNeverRadio,
        ])
        resetGroup.orientation = .vertical
        resetGroup.alignment = .leading
        resetGroup.spacing = 4
        let resetGroupWrapper = indented(resetGroup)
        stack.addArrangedSubview(resetGroupWrapper)

        serviceDotToggle = NSButton(
            checkboxWithTitle: "Show service status dot on issues",
            target: self,
            action: #selector(toggleServiceDot(_:)))
        stack.setCustomSpacing(12, after: resetGroupWrapper)   // separate the service-dot toggle from the countdown group
        stack.addArrangedSubview(serviceDotToggle)

        // Explains the toggle: the dot is a coloured marker that appears only on a service issue.
        let serviceDotHint = NSTextField(wrappingLabelWithString:
            "Draws a small coloured dot in the menu bar when a monitored Claude service has issues.")
        serviceDotHint.font = .systemFont(ofSize: 11)
        serviceDotHint.textColor = .secondaryLabelColor
        serviceDotHint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(serviceDotHint)
        serviceDotHint.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        stack.addArrangedSubview(sectionSeparator())

        // ── Monitored services (#89) ──────────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Monitored services"))

        // Claude API — always monitored, not configurable (TokenPace's own usage API depends on it),
        // so the checkbox is shown on and disabled; the "(always monitored)" suffix says why. The
        // title is drawn in `secondaryLabelColor` (an `attributedTitle`, since a disabled NSButton
        // otherwise applies its own greying) — the same muted tone the explanatory hints use, rather
        // than the default disabled grey.
        let apiToggle = NSButton(checkboxWithTitle: "Claude API (always monitored)", target: nil, action: nil)
        apiToggle.attributedTitle = NSAttributedString(
            string: "Claude API (always monitored)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        apiToggle.state = .on
        apiToggle.isEnabled = false
        stack.addArrangedSubview(apiToggle)

        claudeCodeToggle = NSButton(
            checkboxWithTitle: "Claude Code", target: self, action: #selector(monitoredServicesToggled))
        stack.addArrangedSubview(claudeCodeToggle)

        webDesktopToggle = NSButton(
            checkboxWithTitle: "Claude WEB/Desktop", target: self, action: #selector(monitoredServicesToggled))
        stack.addArrangedSubview(webDesktopToggle)

        // Nested mode radios under the WEB/Desktop checkbox. AppKit groups radios with the same
        // action within one superview into an exclusive set; wrapping them in an indented vertical
        // stack gives the visual nesting and keeps them a single group.
        chatOnlyRadio = NSButton(
            radioButtonWithTitle: "Chat only", target: self, action: #selector(monitoredServicesToggled))
        chatAndCoworkRadio = NSButton(
            radioButtonWithTitle: "Chat and Cowork", target: self, action: #selector(monitoredServicesToggled))
        let radioGroup = NSStackView(views: [chatOnlyRadio, chatAndCoworkRadio])
        radioGroup.orientation = .vertical
        radioGroup.alignment = .leading
        radioGroup.spacing = 4
        stack.addArrangedSubview(indented(radioGroup))

        stack.addArrangedSubview(sectionSeparator())

        // ── Session logs (#110) ───────────────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Session logs"))

        archiveToggle = NSButton(
            checkboxWithTitle: "Archive session logs to a folder",
            target: self,
            action: #selector(toggleArchive(_:)))
        stack.addArrangedSubview(archiveToggle)

        // Explains what the archiver does and why — accumulate-only, survives Claude Code's cleanup.
        let archiveHint = NSTextField(wrappingLabelWithString:
            "Copies Claude Code's raw session logs to a folder you choose, daily. Files Claude Code "
            + "deletes after 30 days are kept in the archive.")
        archiveHint.font = .systemFont(ofSize: 11)
        archiveHint.textColor = .secondaryLabelColor
        archiveHint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(archiveHint)
        archiveHint.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        // The chosen-folder line + "Choose…" button on one row.
        archivePathLabel = NSTextField(labelWithString: "")
        archivePathLabel.font = .systemFont(ofSize: 11)
        archivePathLabel.textColor = .secondaryLabelColor
        archivePathLabel.lineBreakMode = .byTruncatingMiddle
        archiveChooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseArchiveFolder))
        archiveChooseButton.bezelStyle = .rounded
        let archiveFolderRow = NSStackView(views: [archiveChooseButton, archivePathLabel])
        archiveFolderRow.orientation = .horizontal
        archiveFolderRow.alignment = .firstBaseline
        archiveFolderRow.spacing = 8
        stack.addArrangedSubview(archiveFolderRow)

        archiveNowButton = NSButton(title: "Archive now", target: self, action: #selector(archiveNow))
        archiveNowButton.bezelStyle = .rounded
        stack.addArrangedSubview(archiveNowButton)
        stack.setCustomSpacing(8, after: archiveNowButton)

        archiveStatusLabel = NSTextField(labelWithString: "")
        archiveStatusLabel.font = .systemFont(ofSize: 11)
        archiveStatusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(archiveStatusLabel)

        stack.addArrangedSubview(sectionSeparator())

        // ── Updates (#37) ─────────────────────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Updates"))

        updatesToggle = NSButton(
            checkboxWithTitle: "Check for updates automatically",
            target: self,
            action: #selector(toggleAutomaticUpdates(_:)))
        stack.addArrangedSubview(updatesToggle)

        // Nested under "Check for updates automatically": whether a found update is also installed
        // automatically (#122). Indented via `indented(_:)` like the other sub-options. Enabled only
        // while the parent is on AND we are a real `.app` bundle (a `swift run` build can't self-
        // replace) — see `updateInstallAvailability`.
        installAutomaticallyToggle = NSButton(
            checkboxWithTitle: "Install updates automatically",
            target: self,
            action: #selector(toggleInstallAutomatically(_:)))
        stack.addArrangedSubview(indented(installAutomaticallyToggle))

        // Explains the toggle and its precondition (a real .app in /Applications). Text is set in
        // `syncUpdatesFromConfig` so a dev build can say why the option is unavailable.
        installAutomaticallyHint = NSTextField(wrappingLabelWithString: "")
        installAutomaticallyHint.font = .systemFont(ofSize: 11)
        installAutomaticallyHint.textColor = .secondaryLabelColor
        installAutomaticallyHint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(indented(installAutomaticallyHint))
        installAutomaticallyHint.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding - Metrics.nestIndent).isActive = true
        stack.setCustomSpacing(10, after: installAutomaticallyHint.superview ?? installAutomaticallyHint)

        checkNowButton = NSButton(title: "Check now", target: self, action: #selector(checkNow))
        checkNowButton.bezelStyle = .rounded
        stack.addArrangedSubview(checkNowButton)
        // Tighten the gap below the button — the update-available row that follows is usually hidden,
        // so the default row spacing leaves too much air under "Check now".
        stack.setCustomSpacing(8, after: checkNowButton)

        // The "Update available: vX.Y.Z" line + a "Download" link, both hidden until a newer release
        // is found. Kept as two controls on one row: a plain label and a link button (same inline
        // link style as the repo link in the About section).
        updateLineLabel = NSTextField(labelWithString: "")
        updateLineLabel.font = .systemFont(ofSize: 11)
        updateLineLabel.textColor = .secondaryLabelColor
        updateDownloadLink = NSButton(title: "Download", target: self, action: #selector(openDownload))
        updateDownloadLink.isBordered = false
        updateDownloadLink.bezelStyle = .inline
        updateDownloadLink.contentTintColor = .linkColor
        updateDownloadLink.font = .systemFont(ofSize: 11)
        updateRow = NSStackView(views: [updateLineLabel, updateDownloadLink])
        updateRow.orientation = .horizontal
        updateRow.alignment = .firstBaseline
        updateRow.spacing = 6
        updateRow.isHidden = true   // whole row hidden until an update is known (drops it from layout)
        stack.addArrangedSubview(updateRow)

        stack.addArrangedSubview(sectionSeparator())

        // ── About ─────────────────────────────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("About"))

        let versionLabel = NSTextField(labelWithString: Self.versionText())
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let link = NSButton(
            title: "github.com/artem-from-ua/tokenpace",
            target: self,
            action: #selector(openRepo))
        link.isBordered = false
        link.bezelStyle = .inline
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(link)

        // The settings have outgrown a short panel (#110 added a Session-logs section), so the
        // content lives in a document view inside a vertical scroll view: on a tall screen the window
        // sizes to fit (no scroller shows), on a short one it caps its height and the extra content
        // scrolls rather than running off-screen.
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Metrics.padding),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Metrics.padding),
            documentView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Metrics.padding),
            documentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Metrics.padding),
            documentView.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        self.scrollView = scrollView

        window?.contentView = scrollView
        resizeToFit()
    }

    /// Size the window to the content, but never taller than most of the visible screen — beyond that
    /// the scroll view takes over. Called after `buildContent` and whenever a status line grows/shrinks
    /// (the archive line, the launch hint, the update row) so the window keeps hugging its content.
    private func resizeToFit() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let contentHeight = documentView.fittingSize.height
        let maxHeight = (window?.screen ?? NSScreen.main)
            .map { $0.visibleFrame.height * 0.85 } ?? 900
        let height = min(contentHeight, maxHeight)
        window?.setContentSize(NSSize(width: Metrics.width, height: height))
    }

    /// A bold section heading (`General` / `Monitored services`), the visual anchor of each group.
    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        return label
    }

    /// A full-content-width horizontal rule between sections (same technique as the original one).
    private func sectionSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true
        return separator
    }

    /// Wrap a view in a leading-indented row, for controls nested under a parent checkbox (the
    /// WEB/Desktop mode radios). A fixed-width leading spacer gives the indent within the
    /// leading-aligned vertical stack.
    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Metrics.nestIndent).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    // MARK: Actions

    private func syncToggleFromSystem() {
        let status = LaunchAtLoginController.currentStatus()
        launchToggle.state = LaunchAtLogin.toggleState(for: status) ? .on : .off

        // Availability is gated on being a real `.app` bundle, not on status. A bare `swift run`
        // binary is a dev build we never launch at login: the checkbox stays disabled and greyed,
        // exactly as before (ADR-0012 §4). In a real `.app`, the checkbox is always enabled — even
        // on `.notFound`, which for an installed bundle means the login-item dropped with a replaced
        // bundle on update; clicking re-`register()`s and recovers it (#69, ADR-0018). We deliberately
        // do NOT try to read "signed + in /Applications" from status alone — `isAppBundle` is the one
        // reliable discriminator, and `register()` adjudicates the rest on click.
        let inAppBundle = LaunchAtLoginController.isAppBundle
        launchToggle.isEnabled = inAppBundle
        let hint = hintText(inAppBundle: inAppBundle)
        hintLabel.stringValue = hint
        // Hide the hint when empty (the neutral state) so the stack drops it from layout — otherwise an
        // empty wrapping label still claims a row's height plus spacing, leaving a gap under General.
        hintLabel.isHidden = hint.isEmpty

        // The hint wraps to a different height per message; refit so neither text is clipped.
        resizeToFit()
    }

    /// Load the persisted monitored-services config (#89) into the checkboxes and radios. Called on
    /// every `show()`, so the window always reflects the stored choice (which a prior session or the
    /// popup may have changed).
    private func syncMonitoredServicesFromConfig() {
        let config = PersistedConfig.monitoredServices
        claudeCodeToggle.state = config.claudeCodeEnabled ? .on : .off
        webDesktopToggle.state = config.webDesktopEnabled ? .on : .off
        chatOnlyRadio.state = config.webDesktopMode == .chatOnly ? .on : .off
        chatAndCoworkRadio.state = config.webDesktopMode == .chatAndCowork ? .on : .off
        updateRadioAvailability()
    }

    /// The radios are only meaningful while WEB/Desktop is monitored, so they enable/disable with
    /// the parent checkbox (the mode is still remembered in the config when disabled).
    private func updateRadioAvailability() {
        let enabled = webDesktopToggle.state == .on
        chatOnlyRadio.isEnabled = enabled
        chatAndCoworkRadio.isEnabled = enabled
    }

    /// Load the persisted reset-countdown mode (#103) into the radio group + nested checkbox. The two
    /// smart modes share the middle radio and differ only in the checkbox; `.always`/`.never` leave
    /// the checkbox at `.on` (the `showDistant7d` default) so returning to the smart radio lands on a
    /// predictable state. Called on every `show()`.
    private func syncResetCountdownFromConfig() {
        switch PersistedConfig.resetCountdownModeMenuBar {
        case .always:
            resetAlwaysRadio.state = .on
            resetIncludeDistantCheckbox.state = .on
        case .showDistant7d:
            resetSmartRadio.state = .on
            resetIncludeDistantCheckbox.state = .on
        case .hideDistant7d:
            resetSmartRadio.state = .on
            resetIncludeDistantCheckbox.state = .off
        case .never:
            resetNeverRadio.state = .on
            resetIncludeDistantCheckbox.state = .on
        }
        updateResetCheckboxAvailability()
    }

    /// The "include distant 7d reset" checkbox only distinguishes the two smart modes, so it is
    /// enabled only while the middle radio is on (the choice is still remembered when disabled).
    private func updateResetCheckboxAvailability() {
        resetIncludeDistantCheckbox.isEnabled = (resetSmartRadio.state == .on)
    }

    /// A monitored-services control changed (#89): read the current UI into a config, persist it,
    /// refresh the radio enablement, and notify the app so it re-polls the status page immediately.
    @objc private func monitoredServicesToggled() {
        updateRadioAvailability()
        let config = MonitoredServices(
            claudeCodeEnabled: claudeCodeToggle.state == .on,
            webDesktopEnabled: webDesktopToggle.state == .on,
            webDesktopMode: chatAndCoworkRadio.state == .on ? .chatAndCowork : .chatOnly)
        PersistedConfig.monitoredServices = config
        onMonitoredServicesChange?(config)
    }

    /// The explanatory line under the checkbox. A dev build (`swift run`) is not an `.app`, so
    /// launch-at-login is unavailable; an `.app` where a click just failed points the user at
    /// recovery; otherwise the hint is empty (the checkbox label speaks for itself).
    private func hintText(inAppBundle: Bool) -> String {
        if !inAppBundle {
            return "Unavailable in this build. Install TokenPace.app and launch it from "
                 + "Launchpad/Finder (not a developer build) for this option to work."
        }
        if lastToggleFailed {
            return "Couldn't enable launch at login. Reinstall TokenPace.app in /Applications and "
                 + "open it from Finder/Launchpad, or add it manually in System Settings → General → "
                 + "Login Items."
        }
        // Neutral state: no hint — the checkbox label already says what it does.
        return ""
    }

    /// The version line under the separator: just the version for an installed `.app`; a
    /// "— Dev Build" tag for a bare `swift run` binary; and, under a stub, the stub mode too —
    /// "Version 0.17.0 — Dev Build (stub: error)" — so a stubbed dev window is unmistakable.
    private static func versionText() -> String {
        let base = "Version \(TokenPaceKit.version)"
        guard !LaunchAtLoginController.isAppBundle else { return base }
        if let stub = ProcessInfo.processInfo.environment["TOKENPACE_STUB"] {
            return "\(base) — Dev Build (stub: \(stub))"
        }
        return "\(base) — Dev Build"
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let wantOn = sender.state == .on
        do {
            if wantOn { try LaunchAtLoginController.enable() }
            else      { try LaunchAtLoginController.disable() }
            lastToggleFailed = false
            AppLogger.lifecycle.notice("launch-at-login: user set \(wantOn, privacy: .public)")
        } catch {
            // Best-effort: a throw on an unsigned build must not crash — roll the checkbox back and
            // remember the failure so the hint explains it (#69). A deliberate user action, so this
            // stays `.error` (unlike the routine startup attempt, which logs `.notice`).
            lastToggleFailed = true
            AppLogger.lifecycle.error(
                "launch-at-login: toggle failed: \(error.localizedDescription, privacy: .public)")
            sender.state = wantOn ? .off : .on
        }
        // register() may resolve to .requiresApproval (user disabled it in Login Items) rather than
        // .enabled — send them to System Settings, then reflect the real status on the checkbox.
        if LaunchAtLogin.needsSystemSettings(LaunchAtLoginController.currentStatus()) {
            LaunchAtLoginController.openLoginItemsSettings()
        }
        syncToggleFromSystem()
    }

    /// Persist the "Calm MenuBar Widget colors" choice (#105) and notify the app so the menu-bar
    /// image repaints immediately.
    @objc private func toggleCalmColors(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.calmMenuBarColors = on
        AppLogger.lifecycle.notice("calm-colors: menu-bar set \(on, privacy: .public)")
        onCalmColorsChange?(on)
    }

    /// Persist the "Show service status dot on issues" choice (#31) and notify the app so the
    /// menu-bar image repaints immediately (the dot changes both the drawing and the item width).
    @objc private func toggleServiceDot(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.showServiceStatusDot = on
        AppLogger.lifecycle.notice("service-status-dot: menu-bar set \(on, privacy: .public)")
        onServiceDotChange?(on)
    }

    /// Persist the "Hide 7-day bar when calm" choice (#94) and notify the app so the menu-bar image
    /// repaints immediately (the toggle changes both the drawing and the vertical layout).
    @objc private func toggleHideCalmSevenDay(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.hideCalmSevenDayBar = on
        AppLogger.lifecycle.notice("hide-calm-7d: menu-bar set \(on, privacy: .public)")
        onHideCalmSevenDayChange?(on)
    }

    /// Persist the "Pause polling while the screen is locked" choice (#114) and notify the app so a
    /// loop already parked by a screen lock resumes when the pause is turned off.
    @objc private func togglePausePolling(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.pausePollingWhenScreenLocked = on
        AppLogger.lifecycle.notice("screen-lock-pause: setting set \(on, privacy: .public)")
        onPausePollingChange?(on)
    }

    /// A "Display reset countdown" control changed (#103): refresh the checkbox enablement, read the
    /// radio group + checkbox back into a `ResetCountdownMode`, persist it, and notify the app so the
    /// menu-bar image repaints immediately. The middle radio maps to one of the two smart modes per
    /// the checkbox; `Always`/`Never` map straight through.
    @objc private func resetCountdownModeChanged(_ sender: NSButton) {
        updateResetCheckboxAvailability()
        let mode: ResetCountdownMode
        if resetAlwaysRadio.state == .on {
            mode = .always
        } else if resetNeverRadio.state == .on {
            mode = .never
        } else {
            mode = resetIncludeDistantCheckbox.state == .on ? .showDistant7d : .hideDistant7d
        }
        PersistedConfig.resetCountdownModeMenuBar = mode
        AppLogger.lifecycle.notice("reset-countdown: menu-bar mode set \(mode.rawValue, privacy: .public)")
        onResetCountdownModeMenuBarChange?(mode)
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(Self.repoURL)
    }

    // MARK: Updates (#37)

    /// Load both update toggles from `PersistedConfig` and refresh the nested checkbox's enablement +
    /// hint. Called on every `show()`, so the window always reflects the stored choice.
    private func syncUpdatesFromConfig() {
        updatesToggle.state = PersistedConfig.automaticUpdateChecks ? .on : .off
        installAutomaticallyToggle.state = PersistedConfig.installUpdatesAutomatically ? .on : .off
        updateInstallAvailability()
    }

    /// The "Install updates automatically" checkbox is only meaningful when update checks are on and
    /// this is a real `.app` bundle (a `swift run` dev build cannot self-replace). Enable it only
    /// then; otherwise disable it and explain why in the hint. The stored choice is preserved either
    /// way — turning the parent back on re-enables it at its remembered state.
    ///
    /// Hint precedence puts the **`.app`-bundle** requirement first: in a dev build auto-install is
    /// permanently impossible, so "Available only for TokenPace.app in /Applications" is the honest
    /// message even with the parent toggle off — telling a dev user to "Turn on Check for updates"
    /// would imply the option would then work, which it never will. In a real `.app`
    /// (`inAppBundle == true`) that branch never fires, so a user only ever sees the parent-dependency
    /// hint or the enabled description — the two cases that actually differ for them.
    private func updateInstallAvailability() {
        let inAppBundle = LaunchAtLoginController.isAppBundle
        let checksOn = updatesToggle.state == .on
        installAutomaticallyToggle.isEnabled = checksOn && inAppBundle

        let hint: String
        if !inAppBundle {
            hint = "Available only for TokenPace.app installed in /Applications — a developer build "
                 + "can't replace itself."
        } else if !checksOn {
            hint = "Turn on \u{201C}Check for updates automatically\u{201D} to enable this."
        } else {
            hint = "Downloads and installs a newer release in the background, then restarts. "
                 + "Falls back to the manual download if anything fails."
        }
        installAutomaticallyHint.stringValue = hint
        resizeToFit()
    }

    /// Persist the "Check for updates automatically" choice. Turning it on also (re)requests
    /// notification authorization so a later banner can appear — a no-op outside a real `.app`.
    /// Refreshes the nested "Install updates automatically" enablement, which depends on this.
    @objc private func toggleAutomaticUpdates(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.automaticUpdateChecks = on
        AppLogger.lifecycle.notice("update: automatic checks set \(on, privacy: .public)")
        if on { UpdateNotifier.requestAuthorizationIfNeeded() }
        updateInstallAvailability()
    }

    /// Persist the "Install updates automatically" choice (#122). No immediate action — the decision
    /// to install rides the next found-update path (`AppDelegate.handleUpdateFound`).
    @objc private func toggleInstallAutomatically(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.installUpdatesAutomatically = on
        AppLogger.lifecycle.notice("update-install: auto set \(on, privacy: .public)")
    }

    /// Run an immediate update check (bypasses the 12 h cadence) via the app's shared path.
    @objc private func checkNow() {
        onCheckForUpdatesNow?()
    }

    /// Open the release page for the currently-offered update.
    @objc private func openDownload() {
        guard let release = latestRelease, let url = URL(string: release.htmlURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reflect the current update state in the window (#37): show "Update available: vX.Y.Z" + the
    /// Download link when `release` is non-nil, hide the line when up to date. Called by `AppDelegate`
    /// after each check and on window open. Re-fits the window so the appearing/disappearing line is
    /// not clipped.
    func updateAvailability(_ release: GitHubRelease?) {
        latestRelease = release
        if let release {
            updateLineLabel.stringValue = "Update available: \(release.tagName)"
            updateRow.isHidden = false
        } else {
            updateLineLabel.stringValue = ""
            updateRow.isHidden = true
        }
        resizeToFit()
    }

    // MARK: Session logs (#110)

    /// Persist the "Archive session logs" choice. A first-time enable with no folder yet chosen nudges
    /// the user straight into the folder picker, since the archiver stays inert without a destination.
    @objc private func toggleArchive(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.archiveEnabled = on
        AppLogger.lifecycle.notice("archive: enabled set \(on, privacy: .public)")
        if on, PersistedConfig.archiveDestination == nil {
            chooseArchiveFolder()   // no folder yet → prompt now, or the toggle does nothing
        }
        updateArchiveStatus()
    }

    /// Open an `NSOpenPanel` to pick (or create) the archive folder, and persist the chosen path.
    /// No security-scoped bookmark: the app isn't sandboxed, so a plain path suffices (ADR-0030).
    @objc private func chooseArchiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to archive Claude Code session logs into."
        if let current = PersistedConfig.archiveDestination {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PersistedConfig.archiveDestination = url.path
        AppLogger.lifecycle.notice("archive: destination chosen")
        updateArchiveStatus()
    }

    /// Run an immediate archive sync (bypasses the daily cadence) via the app's shared path.
    @objc private func archiveNow() {
        onArchiveNow?()
    }

    /// Reflect the current archive state in the window (#110): the chosen path (or "No folder
    /// selected"), the "Last archived …" line, and the enablement of the Choose…/Archive-now buttons.
    /// Called on `show()`, after each toggle/choose, and by `AppDelegate` when a sync finishes.
    func updateArchiveStatus() {
        let enabled = PersistedConfig.archiveEnabled
        let destination = PersistedConfig.archiveDestination

        archiveChooseButton.isEnabled = enabled
        archiveNowButton.isEnabled = enabled && destination != nil

        guard let destination else {
            archivePathLabel.stringValue = "No folder selected"
            archiveStatusLabel.stringValue = ""
            resizeToFit()
            return
        }
        archivePathLabel.stringValue = (destination as NSString).abbreviatingWithTildeInPath

        // Files + size come from a live scan of the archive folder, so they show on every window open
        // regardless of whether a sync has run this session (the in-memory Summary is lost across
        // relaunches; the folder on disk is not). "N updated" is only meaningful right after a sync,
        // so it's appended only when a fresh Summary is available.
        let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
        let stats = LogArchiver().archiveStats(at: destURL)
        let totals = "\(stats.files) files · \(ByteSize.humanReadable(stats.bytes))"

        if let last = PersistedConfig.lastArchiveSync {
            // Reuse the popup's data-age formatter — plain English ("just now" / "2h ago"), never a
            // locale-formatted string (the whole UI is English) and never a future "in 0 seconds"
            // when a sync just finished and `last ≈ now`.
            let when = PopupViewController.ageText(max(0, Date().timeIntervalSince(last)))
            if let summary = archiveSummaryProvider?() {
                archiveStatusLabel.stringValue = "Last archived: \(when) · \(summary.copied) updated · \(totals)"
            } else {
                archiveStatusLabel.stringValue = "Last archived: \(when) · \(totals)"
            }
        } else {
            // Folder set but nothing synced yet this install: still show what's already there (0 files
            // on a fresh folder), plus the hint that a sync is pending.
            archiveStatusLabel.stringValue = "Not archived yet — runs daily, or use Archive now. (\(totals))"
        }

        resizeToFit()
    }
}
