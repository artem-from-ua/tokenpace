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
    /// immediate update check that bypasses the 24 h cadence.
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
    /// Shows "Last archived: … · N files", or a hint when nothing has synced yet (#110).
    private var archiveStatusLabel: NSTextField!

    /// The "Check for updates daily" checkbox (#37), synced from `PersistedConfig` on every `show()`.
    private var updatesToggle: NSButton!
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

    /// The "Calm MenuBar Widget colors" checkbox (#105), synced from `PersistedConfig` on every
    /// `show()`.
    private var calmColorsToggle: NSButton!

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
        syncMonitoredServicesFromConfig()
        calmColorsToggle.state = PersistedConfig.calmMenuBarColors ? .on : .off
        syncResetCountdownFromConfig()
        serviceDotToggle.state = PersistedConfig.showServiceStatusDot ? .on : .off
        updatesToggle.state = PersistedConfig.automaticUpdateChecks ? .on : .off
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

        // "Display reset countdown" (#103): three radios pick the coarse intent, and a checkbox nested
        // under the middle ("smart") radio flips the one bit between the two smart modes. AppKit groups
        // radios sharing an `action` in one superview into an exclusive set; the vertical stack keeps
        // them a single group. The checkbox shares that action too, so any change routes through
        // `resetCountdownModeChanged`, which reads the whole group back into a `ResetCountdownMode`.
        let resetLabel = NSTextField(labelWithString: "Display reset countdown:")
        resetLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(resetLabel)
        stack.setCustomSpacing(12, after: calmHint)   // separate the countdown sub-section from the calm hint

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
            checkboxWithTitle: "Check for updates daily",
            target: self,
            action: #selector(toggleAutomaticUpdates(_:)))
        stack.addArrangedSubview(updatesToggle)

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

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.padding),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.padding),
            content.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Metrics.padding),
            content.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Metrics.padding),
            content.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
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
        if let content = window?.contentView {
            window?.setContentSize(content.fittingSize)
        }
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

    /// Persist the "Check for updates daily" choice. Turning it on also (re)requests notification
    /// authorization so a later banner can appear — a no-op outside a real `.app`.
    @objc private func toggleAutomaticUpdates(_ sender: NSButton) {
        let on = sender.state == .on
        PersistedConfig.automaticUpdateChecks = on
        AppLogger.lifecycle.notice("update: automatic checks set \(on, privacy: .public)")
        if on { UpdateNotifier.requestAuthorizationIfNeeded() }
    }

    /// Run an immediate update check (bypasses the 24 h cadence) via the app's shared path.
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
        if let content = window?.contentView {
            window?.setContentSize(content.fittingSize)
        }
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

        if let destination {
            archivePathLabel.stringValue = (destination as NSString).abbreviatingWithTildeInPath
        } else {
            archivePathLabel.stringValue = "No folder selected"
        }

        if let last = PersistedConfig.lastArchiveSync {
            let when = Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
            if let summary = archiveSummaryProvider?() {
                archiveStatusLabel.stringValue = "Last archived: \(when) · \(summary.copied) file\(summary.copied == 1 ? "" : "s")"
            } else {
                archiveStatusLabel.stringValue = "Last archived: \(when)"
            }
        } else if enabled, destination != nil {
            archiveStatusLabel.stringValue = "Not archived yet — runs daily, or use Archive now."
        } else {
            archiveStatusLabel.stringValue = ""
        }

        if let content = window?.contentView {
            window?.setContentSize(content.fittingSize)
        }
    }

    /// Shared relative-time formatter for the "Last archived …" line ("2 hours ago").
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
