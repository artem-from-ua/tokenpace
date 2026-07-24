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
        static let width: CGFloat = 320
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
        updatesToggle.state = PersistedConfig.automaticUpdateChecks ? .on : .off
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
}
