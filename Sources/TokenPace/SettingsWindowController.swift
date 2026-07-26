import AppKit
import TokenPaceKit

// MARK: - SettingsWindowController

/// The "Settings…" window (#14, redesigned #131): a macOS System Settings-style window reached from
/// the popup menu — a sidebar of sections on the left, a detail pane of grouped-inset cards on the
/// right. It replaces the original flat single-column panel (ADR-0012) once the settings outgrew a
/// short scroll: a sidebar scales as options grow, where one long column did not.
///
/// The controller keeps the same public contract the `AppDelegate` wires (`AppDelegate.openSettings`):
/// eight `on…Change`/provider callbacks plus `updateAvailability(_:)` and `updateArchiveStatus()`. All
/// controls are still owned here and synced from `PersistedConfig`/the system on every `show()`; the
/// per-section detail views are just the layout those controls live in. Every detail pane is built
/// **eagerly** in `init`, because `updateAvailability`/`updateArchiveStatus` fire from background poll
/// completions while the window is closed — a lazily-built pane would hit nil outlets.
///
/// Opened from an accessory (menu-bar) app, so it uses `NSApp.activate` + a floating window level to
/// come to the front (ADR-0012 §6), rather than switching activation policy to `.regular`.
@MainActor
final class SettingsWindowController: NSWindowController {

    private static let repoURL = URL(string: "https://github.com/artem-from-ua/tokenpace")!

    private enum Metrics {
        static let contentWidth: CGFloat = 620
        static let contentHeight: CGFloat = 480
        static let sidebarWidth: CGFloat = 200
        static let padding: CGFloat = 20
        static let cardSpacing: CGFloat = 20
        static let sectionTitleGap: CGFloat = 7
        /// Leading inset of the radio group nested under a parent switch (#89, #103).
        static let nestIndent: CGFloat = 18
    }

    // MARK: Public callbacks (the AppDelegate contract — unchanged from the flat design)

    /// Called when the user changes the monitored-services selection (#89), with the new config —
    /// wired by `AppDelegate.openSettings` to re-poll the status page immediately. The config is
    /// already persisted (via `PersistedConfig`) by the time this fires.
    var onMonitoredServicesChange: ((MonitoredServices) -> Void)?

    /// Called when the user clicks "Check now" (#37) — wired by `AppDelegate.openSettings` to run an
    /// immediate update check that bypasses the 24 h cadence.
    var onCheckForUpdatesNow: (() -> Void)?

    /// Called when the user toggles "Calm MenuBar Widget colors" (#105), with the new on/off state —
    /// wired by `AppDelegate.openSettings` to re-render the menu-bar image immediately.
    var onCalmColorsChange: ((Bool) -> Void)?

    /// Called when the user changes the menu-bar "Reset countdown" mode (#103), with the new mode.
    var onResetCountdownModeMenuBarChange: ((ResetCountdownMode) -> Void)?

    /// Called when the user toggles "Show service status dot on issues" (#31), with the new state.
    var onServiceDotChange: ((Bool) -> Void)?

    /// Called when the user toggles "Show extra-usage credits icon" (#146), with the new state.
    var onExtraUsageChange: ((Bool) -> Void)?

    /// Called when the user toggles "Hide 7-day bar when calm" (#94), with the new on/off state —
    /// wired by `AppDelegate.openSettings` to re-render the menu-bar image immediately (the toggle
    /// changes what is drawn — the 7-day bar and the 5h bar's vertical centring).
    var onHideCalmSevenDayChange: ((Bool) -> Void)?

    /// Called when the user toggles "Pause polling while the screen is locked" (#114) — wired to
    /// un-park the loop when turned off.
    var onPausePollingChange: ((Bool) -> Void)?

    /// Called when the user clicks "Archive now" (#110) — wired to run an immediate archive sync.
    var onArchiveNow: (() -> Void)?

    /// Called when the user turns the "Back to work" notification on (#160) — wired by
    /// `AppDelegate.openSettings` to lazily request notification authorization (never at launch, since
    /// this is an opt-in feature). The `completion` reports the resolved auth state back so the pane
    /// can refresh its hint.
    var onBackToWorkEnabled: ((@escaping (BackToWorkNotifier.AuthState) -> Void) -> Void)?

    /// Provides the last archive summary for the status line (#110), read on each `show()` /
    /// `updateArchiveStatus()`. `nil` until the first sync of the session completes.
    var archiveSummaryProvider: (() -> LogArchiver.Summary?)?

    // MARK: Controls (owned here; the detail panes just lay them out)

    // General
    private var launchToggle: NSSwitch!
    private var hintLabel: NSTextField!
    private var pausePollingToggle: NSSwitch!

    // Menu Bar
    private var calmColorsToggle: NSSwitch!
    private var hideCalmSevenDayToggle: NSSwitch!
    private var serviceDotToggle: NSSwitch!
    private var extraUsageToggle: NSSwitch!
    private var resetAlwaysRadio: NSButton!
    private var resetSmartRadio: NSButton!
    private var resetIncludeDistantCheckbox: NSButton!
    private var resetNeverRadio: NSButton!

    // Monitored Services
    private var claudeCodeToggle: NSSwitch!
    private var webDesktopToggle: NSSwitch!
    private var chatOnlyRadio: NSButton!
    private var chatAndCoworkRadio: NSButton!

    // Notifications (#160)
    private var backToWorkToggle: NSSwitch!
    private var notifyStartPicker: NSDatePicker!
    private var notifyEndPicker: NSDatePicker!
    private var notifyDurationLabel: NSTextField!
    private var notifyNeverRadio: NSButton!
    private var notifyFriSatRadio: NSButton!
    private var notifySatSunRadio: NSButton!
    /// Hint under the master switch: notification-authorization status, or the dev-build note.
    private var notifyAuthHint: NSTextField!

    // Session Logs
    private var archiveToggle: NSSwitch!
    private var archiveChooseButton: NSButton!
    private var archiveNowButton: NSButton!
    private var archivePathLabel: NSTextField!
    private var archiveStatusLabel: NSTextField!

    // About / Updates
    private var updatesToggle: NSSwitch!
    /// The nested "Install updates automatically" toggle (#122), enabled only when the parent check is
    /// on and this is a real `.app` bundle; synced from `PersistedConfig` on every `show()`.
    private var installAutomaticallyToggle: NSSwitch!
    /// Explanatory line under `installAutomaticallyToggle` (#122): what it does + its `/Applications`
    /// precondition, or why it is unavailable on a dev build. Text set in `updateInstallAvailability`.
    private var installAutomaticallyHint: NSTextField!
    private var checkNowButton: NSButton!
    private var updateLineLabel: NSTextField!
    private var updateDownloadLink: NSButton!
    private var updateRow: NSView!
    /// The card holding the update row, so it can collapse the row + its divider together (#37).
    private var updatesCard: SettingsCard!
    /// The release currently offered by the update line, or `nil` when up to date.
    private var latestRelease: GitHubRelease?

    /// Whether the last launch-at-login toggle failed in an `.app` bundle (drives the recovery hint,
    /// #69); reset on a successful toggle or a fresh `show()`.
    private var lastToggleFailed = false

    /// Whether the window has been positioned yet — so the first `show()` centres it (unless an
    /// autosaved frame already placed it), and later shows leave the user's position alone (#131).
    private var hasBeenPositioned = false

    /// The split VC (sidebar + detail); the window's content view controller and single instance.
    private var splitVC: SettingsSplitViewController!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.contentWidth, height: Metrics.contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TokenPace"
        window.level = .floating               // float above other apps from a menu-bar app (ADR-0012 §6)
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        window.setFrameAutosaveName("TokenPaceSettings")   // remember size/position across opens
        self.init(window: window)
        buildContent()
    }

    /// Show or re-focus the window. Re-syncs every control from `PersistedConfig`/the system, brings
    /// the app forward, and centres on first display (unless an autosaved frame restored a position).
    /// Calling this while the window is already on screen just focuses it — the single instance is
    /// never duplicated.
    func show() {
        lastToggleFailed = false   // a fresh open starts from the status-derived hint (#69)
        syncToggleFromSystem()
        pausePollingToggle.state = PersistedConfig.pausePollingWhenScreenLocked ? .on : .off
        syncMonitoredServicesFromConfig()
        calmColorsToggle.state = PersistedConfig.calmMenuBarColors ? .on : .off
        hideCalmSevenDayToggle.state = PersistedConfig.hideCalmSevenDayBar ? .on : .off
        syncResetCountdownFromConfig()
        serviceDotToggle.state = PersistedConfig.showServiceStatusDot ? .on : .off
        extraUsageToggle.state = PersistedConfig.showExtraUsage ? .on : .off
        syncUpdatesFromConfig()
        archiveToggle.state = PersistedConfig.archiveEnabled ? .on : .off
        updateArchiveStatus()
        syncNotificationsFromConfig()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        // Centre once, on the first show — but only if `setFrameUsingName` didn't restore an autosaved
        // frame (a menu-bar app's window otherwise defaults to the bottom-left origin). Later shows keep
        // wherever the user moved it. `frameAutosaveName` is non-empty, so try the saved frame first.
        if !hasBeenPositioned {
            hasBeenPositioned = true
            let restored = window?.setFrameUsingName("TokenPaceSettings") ?? false
            if !restored { window?.center() }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Content assembly

    private func buildContent() {
        let split = SettingsSplitViewController(
            sidebarWidth: Metrics.sidebarWidth,
            sections: [
                .init(title: "General", symbol: "gearshape", tint: .systemGray, make: buildGeneralPane),
                .init(title: "Menu Bar", symbol: "menubar.rectangle", tint: .systemIndigo, make: buildMenuBarPane),
                .init(title: "Monitored Services", symbol: "dot.radiowaves.left.and.right", tint: .systemGreen, make: buildServicesPane),
                .init(title: "Session Logs", symbol: "folder", tint: .systemOrange, make: buildSessionLogsPane),
                .init(title: "Notifications", symbol: "bell", tint: .systemRed, make: buildNotificationsPane),
                .init(title: "About", symbol: "info.circle", tint: .systemBlue, make: buildAboutPane),
            ])
        // The window title stays "TokenPace" across sections — the selected section is already obvious
        // from the highlighted sidebar row, exactly like macOS System Settings (which never repeats the
        // pane name in the title bar). `onSelect` is left unused for the title (#131).
        split.onSelect = nil
        splitVC = split
        window?.contentViewController = split   // triggers viewDidLoad → sidebar + first selection
        // Build every pane up front so no outlet is nil when a background callback (updateAvailability
        // / updateArchiveStatus) fires while the window is closed (#131). `contentViewController` above
        // has already run `viewDidLoad`, which built + cached the first pane; this fills in the rest.
        split.buildAllPanes()
        window?.title = "TokenPace"
    }

    // MARK: Pane builders (all eager, called once from `buildContent`)

    private func buildGeneralPane() -> NSView {
        let card = SettingsCard()

        launchToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleLaunchAtLogin(_:)))
        hintLabel = SettingsRow.wrappingHint("")
        let launchCol = NSStackView(views: [
            leadingLabel("Launch TokenPace at login"), hintLabel,
        ])
        launchCol.orientation = .vertical
        launchCol.alignment = .leading
        launchCol.spacing = 2
        card.addRow(SettingsRow.container(leading: launchCol, trailing: launchToggle))

        pausePollingToggle = SettingsRow.makeSwitch(target: self, action: #selector(togglePausePolling(_:)))
        let pauseCol = SettingsRow.labelColumn(
            "Pause polling while the screen is locked",
            hint: "Skips usage polls while the screen is locked, off, or the screensaver is running, "
                + "and refreshes right away on unlock. System sleep always pauses regardless.")
        card.addRow(SettingsRow.container(leading: pauseCol.view, trailing: pausePollingToggle))

        return pane(sections: [("General", card)])
    }

    private func buildMenuBarPane() -> NSView {
        // Appearance card: calm colours + service dot.
        let appearance = SettingsCard()

        calmColorsToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleCalmColors(_:)))
        let calmCol = SettingsRow.labelColumn(
            "Calm colors",
            hint: "Shows blue/green/yellow pacing bars as white in the menu bar. Warning colours and "
                + "the service dot stay coloured.")
        appearance.addRow(SettingsRow.container(leading: calmCol.view, trailing: calmColorsToggle))

        // "Hide 7-day bar when calm" (#94): drop the 7-day bar while it is green/mild-yellow, leaving
        // the 5h bar centred alone — one fewer element on the tiny widget when the week is on track.
        hideCalmSevenDayToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleHideCalmSevenDay(_:)))
        let hideCalmCol = SettingsRow.labelColumn(
            "Hide 7-day bar when calm",
            hint: "When the 7-day bar is green or mild-yellow, hides it and centres the 5-hour bar "
                + "alone. An orange or red 7-day bar always stays visible.")
        appearance.addRow(SettingsRow.container(leading: hideCalmCol.view, trailing: hideCalmSevenDayToggle))

        // "Show extra-usage credits icon" (#146): the trailing currency glyph that appears while paid
        // usage credits are covering an exhausted plan limit. Opt-out, like the service dot.
        extraUsageToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleExtraUsage(_:)))
        let creditsCol = SettingsRow.labelColumn(
            "Show extra-usage credits icon",
            hint: "Draws a currency icon in the menu bar when paid usage credits are covering an "
                + "exhausted plan limit. Its colour paces with your spend against the monthly limit.")
        appearance.addRow(SettingsRow.container(leading: creditsCol.view, trailing: extraUsageToggle))

        serviceDotToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleServiceDot(_:)))
        let dotCol = SettingsRow.labelColumn(
            "Show service status dot on issues",
            hint: "Draws a small coloured dot in the menu bar when a monitored Claude service has issues.")
        appearance.addRow(SettingsRow.container(leading: dotCol.view, trailing: serviceDotToggle))

        // Reset-countdown card: the three-radio exclusive group + one nested checkbox (#103). The
        // radios and the checkbox all share `resetCountdownModeChanged` and live as siblings in one
        // stack inside a *single* card row, so AppKit's shared-action auto-grouping keeps them an
        // exclusive set — splitting them across separate card rows would break exclusivity (#131).
        let countdown = SettingsCard()
        resetAlwaysRadio = NSButton(radioButtonWithTitle: "Always",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        resetSmartRadio = NSButton(radioButtonWithTitle: "When well ahead or limit reached",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        resetNeverRadio = NSButton(radioButtonWithTitle: "Never",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        resetIncludeDistantCheckbox = NSButton(
            checkboxWithTitle: "Include distant 7d limit reset (≥ 24 h away)",
            target: self, action: #selector(resetCountdownModeChanged(_:)))
        let resetGroup = NSStackView(views: [
            resetAlwaysRadio, resetSmartRadio, indented(resetIncludeDistantCheckbox), resetNeverRadio,
        ])
        resetGroup.orientation = .vertical
        resetGroup.alignment = .leading
        resetGroup.spacing = 6
        countdown.addRow(SettingsRow.container(leading: resetGroup))

        return pane(sections: [("Appearance", appearance), ("Reset Countdown", countdown)])
    }

    private func buildServicesPane() -> NSView {
        let card = SettingsCard()

        // Claude API — always monitored, not configurable. A disabled `NSSwitch` has no title, so the
        // "always monitored" note is a muted trailing label beside the on+disabled switch (#89).
        let apiNote = NSTextField(labelWithString: "always monitored")
        apiNote.font = .systemFont(ofSize: 11)
        apiNote.textColor = .secondaryLabelColor
        let apiSwitch = NSSwitch()
        apiSwitch.state = .on
        apiSwitch.isEnabled = false
        let apiTrailing = NSStackView(views: [apiNote, apiSwitch])
        apiTrailing.orientation = .horizontal
        apiTrailing.alignment = .centerY
        apiTrailing.spacing = 8
        card.addRow(SettingsRow.container(leading: leadingLabel("Claude API"), trailing: apiTrailing))

        claudeCodeToggle = SettingsRow.makeSwitch(target: self, action: #selector(monitoredServicesToggled))
        card.addRow(SettingsRow.container(leading: leadingLabel("Claude Code"), trailing: claudeCodeToggle))

        // WEB/Desktop + its two mode radios nested underneath, in one card row so the label, switch,
        // and the indented radio group read as one grouped control.
        webDesktopToggle = SettingsRow.makeSwitch(target: self, action: #selector(monitoredServicesToggled))
        chatOnlyRadio = NSButton(radioButtonWithTitle: "Chat only",
            target: self, action: #selector(monitoredServicesToggled))
        chatAndCoworkRadio = NSButton(radioButtonWithTitle: "Chat and Cowork",
            target: self, action: #selector(monitoredServicesToggled))
        let radioGroup = NSStackView(views: [chatOnlyRadio, chatAndCoworkRadio])
        radioGroup.orientation = .vertical
        radioGroup.alignment = .leading
        radioGroup.spacing = 6

        // Label + switch on top, indented radios directly beneath — as one grouped control in a single
        // card row, hand-laid so there is exactly one set of vertical insets (two stacked container
        // rows doubled the inset, leaving too big a gap above the radios, #131 feedback). The switch
        // aligns to the label line (top), not the centre of the whole block; the radios hang 4 pt under
        // the label with the standard 12 pt horizontal nest.
        webDesktopToggle.translatesAutoresizingMaskIntoConstraints = false
        let webLabel = leadingLabel("Claude WEB/Desktop")
        webLabel.translatesAutoresizingMaskIntoConstraints = false
        let webRadios = indented(radioGroup, by: 12)
        webRadios.translatesAutoresizingMaskIntoConstraints = false
        let webRow = NSView()
        webRow.translatesAutoresizingMaskIntoConstraints = false
        [webLabel, webDesktopToggle, webRadios].forEach { webRow.addSubview($0) }
        let hInset = SettingsRow.Metrics.horizontalInset
        let vInset = SettingsRow.Metrics.verticalInset
        NSLayoutConstraint.activate([
            webLabel.leadingAnchor.constraint(equalTo: webRow.leadingAnchor, constant: hInset),
            webLabel.topAnchor.constraint(equalTo: webRow.topAnchor, constant: vInset),
            webDesktopToggle.trailingAnchor.constraint(equalTo: webRow.trailingAnchor, constant: -hInset),
            webDesktopToggle.centerYAnchor.constraint(equalTo: webLabel.centerYAnchor),
            webLabel.trailingAnchor.constraint(lessThanOrEqualTo: webDesktopToggle.leadingAnchor, constant: -12),
            webRadios.topAnchor.constraint(equalTo: webLabel.bottomAnchor, constant: 8),
            webRadios.leadingAnchor.constraint(equalTo: webRow.leadingAnchor, constant: hInset),
            webRadios.bottomAnchor.constraint(equalTo: webRow.bottomAnchor, constant: -vInset),
        ])
        card.addRow(webRow)

        return pane(sections: [("Monitored Services", card)])
    }

    private func buildSessionLogsPane() -> NSView {
        let card = SettingsCard()

        archiveToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleArchive(_:)))
        let archiveCol = SettingsRow.labelColumn(
            "Archive session logs to a folder",
            hint: "Copies Claude Code's raw session logs to a folder you choose, daily. Files Claude "
                + "Code deletes after 30 days are kept in the archive.")
        card.addRow(SettingsRow.container(leading: archiveCol.view, trailing: archiveToggle))

        // Destination row: a "Destination" label above the chosen path (standard body size, not the
        // small caption used for hints), with the Choose… button trailing (#131 feedback).
        archivePathLabel = NSTextField(labelWithString: "")
        archivePathLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        archivePathLabel.textColor = .secondaryLabelColor
        archivePathLabel.lineBreakMode = .byTruncatingMiddle
        let destinationCol = NSStackView(views: [leadingLabel("Destination"), archivePathLabel])
        destinationCol.orientation = .vertical
        destinationCol.alignment = .leading
        destinationCol.spacing = 2
        archiveChooseButton = SettingsRow.makeButton("Choose…", target: self, action: #selector(chooseArchiveFolder))
        card.addRow(SettingsRow.container(leading: destinationCol, trailing: archiveChooseButton))

        archiveStatusLabel = NSTextField(labelWithString: "")
        archiveStatusLabel.font = .systemFont(ofSize: 11)
        archiveStatusLabel.textColor = .secondaryLabelColor
        archiveStatusLabel.lineBreakMode = .byWordWrapping
        archiveStatusLabel.maximumNumberOfLines = 0
        archiveNowButton = SettingsRow.makeButton("Archive Now", target: self, action: #selector(archiveNow))
        card.addRow(SettingsRow.container(leading: archiveStatusLabel, trailing: archiveNowButton))

        return pane(sections: [("Archive", card)])
    }

    // MARK: Notifications (#160)

    private func buildNotificationsPane() -> NSView {
        let card = SettingsCard()

        // Master switch: the whole feature. Off by default (opt-in). A wrapping hint under the label
        // carries the authorization status / dev-build note, set by `refreshNotifyAuthHint`.
        backToWorkToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleBackToWork(_:)))
        let masterCol = SettingsRow.labelColumn(
            "Back to work",
            hint: "Shows a system notification when your Claude usage limit resets and you can work "
                + "again.")
        card.addRow(SettingsRow.container(leading: masterCol.view, trailing: backToWorkToggle))

        // Second wrapping hint row for the auth/dev status — its own row so the toggle row's hint stays
        // the static description. Placed in a leading column so it reads as continuation text.
        notifyAuthHint = SettingsRow.wrappingHint(" ")
        card.addRow(SettingsRow.container(leading: indented(notifyAuthHint)))

        // Allowed-hours row: two hour/minute pickers with an en-dash between, plus a live "Nh window"
        // duration label. `NSDatePicker` in `.hourMinute` honours the user's locale (12h/24h) and zone.
        notifyStartPicker = makeTimePicker()
        notifyEndPicker = makeTimePicker()
        let dash = NSTextField(labelWithString: "–")
        dash.font = .systemFont(ofSize: NSFont.systemFontSize)
        dash.textColor = .secondaryLabelColor
        notifyDurationLabel = NSTextField(labelWithString: "")
        notifyDurationLabel.font = .systemFont(ofSize: 11)
        notifyDurationLabel.textColor = .secondaryLabelColor
        let hoursRow = NSStackView(views: [
            notifyStartPicker, dash, notifyEndPicker, notifyDurationLabel,
        ])
        hoursRow.orientation = .horizontal
        hoursRow.alignment = .centerY
        hoursRow.spacing = 8
        let hoursCol = NSStackView(views: [leadingLabel("Allowed hours"), indented(hoursRow, by: 0)])
        hoursCol.orientation = .vertical
        hoursCol.alignment = .leading
        hoursCol.spacing = 6
        card.addRow(SettingsRow.container(leading: indented(hoursCol)))

        // Suppress-days radio group: three radios sharing one action so AppKit auto-groups them into an
        // exclusive set (same pattern as the reset-countdown group).
        notifyNeverRadio = NSButton(radioButtonWithTitle: "Never",
            target: self, action: #selector(notifySuppressChanged(_:)))
        notifyFriSatRadio = NSButton(radioButtonWithTitle: "Friday-Saturday",
            target: self, action: #selector(notifySuppressChanged(_:)))
        notifySatSunRadio = NSButton(radioButtonWithTitle: "Saturday-Sunday",
            target: self, action: #selector(notifySuppressChanged(_:)))
        let suppressRadios = NSStackView(views: [notifyNeverRadio, notifyFriSatRadio, notifySatSunRadio])
        suppressRadios.orientation = .vertical
        suppressRadios.alignment = .leading
        suppressRadios.spacing = 6
        let suppressCol = NSStackView(views: [
            leadingLabel("Suppress notifications on"), indented(suppressRadios, by: 0),
        ])
        suppressCol.orientation = .vertical
        suppressCol.alignment = .leading
        suppressCol.spacing = 6
        card.addRow(SettingsRow.container(leading: indented(suppressCol)))

        return pane(sections: [("Back to Work", card)])
    }

    /// An hour/minute `NSDatePicker` (stepper style) that renders in the user's locale (12h/24h) and
    /// zone. The stored form is a minute-of-day Int; the picker's date is display only, so the calendar
    /// day it carries is irrelevant.
    private func makeTimePicker() -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.locale = .current
        picker.timeZone = .current
        picker.target = self
        picker.action = #selector(notifyTimeChanged(_:))
        return picker
    }

    private func buildAboutPane() -> NSView {
        // About card: version + source link.
        let about = SettingsCard()

        let versionValue = NSTextField(labelWithString: Self.versionText())
        versionValue.font = .systemFont(ofSize: NSFont.systemFontSize)
        versionValue.textColor = .secondaryLabelColor
        about.addRow(SettingsRow.container(leading: leadingLabel("Version"), trailing: versionValue))

        let link = SettingsRow.makeLink("github.com/artem-from-ua/tokenpace", target: self, action: #selector(openRepo))
        about.addRow(SettingsRow.container(leading: leadingLabel("Source code"), trailing: link))

        // Updates card (folded into About, #131): daily-check toggle, Check Now, and the hidden
        // update-available row.
        let updates = SettingsCard()
        updatesCard = updates

        updatesToggle = SettingsRow.makeSwitch(target: self, action: #selector(toggleAutomaticUpdates(_:)))
        checkNowButton = SettingsRow.makeButton("Check Now", target: self, action: #selector(checkNow))
        let updatesTrailing = NSStackView(views: [checkNowButton, updatesToggle])
        updatesTrailing.orientation = .horizontal
        updatesTrailing.alignment = .centerY
        updatesTrailing.spacing = 10
        updates.addRow(SettingsRow.container(leading: leadingLabel("Check for updates daily"), trailing: updatesTrailing))

        // Nested "Install updates automatically" (#122, restored in the sidebar design): label + its
        // dynamic hint stacked in one leading column (so no divider splits them), switch on the right,
        // the whole row indented under the parent check. `updateInstallAvailability` sets the hint text
        // (enabled description / parent-off / dev-build precondition).
        installAutomaticallyToggle = SettingsRow.makeSwitch(
            target: self, action: #selector(toggleInstallAutomatically(_:)))
        let installCol = SettingsRow.labelColumn("Install updates automatically", hint: " ")
        installAutomaticallyHint = installCol.hintLabel
        updates.addRow(SettingsRow.container(
            leading: indented(installCol.view), trailing: installAutomaticallyToggle))

        updateLineLabel = NSTextField(labelWithString: "")
        updateLineLabel.font = .systemFont(ofSize: 12)
        updateLineLabel.textColor = .secondaryLabelColor
        updateDownloadLink = SettingsRow.makeLink("Download", target: self, action: #selector(openDownload))
        updateRow = SettingsRow.container(leading: updateLineLabel, trailing: updateDownloadLink)
        updates.addRow(updateRow)
        updates.setRow(updateRow, hidden: true)   // hidden (with its divider) until an update is known

        return pane(sections: [("About", about), ("Updates", updates)])
    }

    // MARK: Layout helpers

    /// A plain leading label at the standard body size/colour.
    private func leadingLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        return label
    }

    /// A small semibold section title above a card (System Settings groups its cards under a muted
    /// caption).
    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Wrap a view in a leading-indented row, for controls nested under a parent (the WEB/Desktop
    /// mode radios, the "include distant 7d" checkbox). A fixed-width leading spacer gives the indent;
    /// `by` overrides the default `nestIndent` where the row is already inset by a card container.
    private func indented(_ view: NSView, by amount: CGFloat = Metrics.nestIndent) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: amount).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    /// Assemble a detail pane: a vertical run of `(title, card)` groups inside a scroll view, so a tall
    /// pane scrolls rather than clipping. Each card stretches to the content width; the title sits above
    /// it. Replaces the old window-wide `resizeToFit()` (each pane now scrolls independently, #131).
    private func pane(sections: [(String, SettingsCard)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.cardSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (title, card) in sections {
            let group = NSStackView(views: [sectionTitle(title), card])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = Metrics.sectionTitleGap
            group.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }

        // A flipped document so short content pins to the *top* of the pane (an NSScrollView document is
        // bottom-origin otherwise, which pushed the cards down with a big gap above them, #131).
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Metrics.padding),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Metrics.padding),
            document.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Metrics.padding),
            // ≥ so a short pane doesn't stretch the stack to fill height; the document grows only when
            // content is taller than the scroll view (then it scrolls).
            document.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: Metrics.padding),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        // Pin the document to the scroll view's width so cards fill the pane and only height scrolls.
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        // At least as tall as the viewport so a short pane fills it (flipped → content sits at the top);
        // taller content wins via the ≥ bottom constraint above and scrolls.
        document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
        return scroll
    }

    // MARK: Sync from config / system

    private func syncToggleFromSystem() {
        let status = LaunchAtLoginController.currentStatus()
        launchToggle.state = LaunchAtLogin.toggleState(for: status) ? .on : .off

        // Availability is gated on being a real `.app` bundle, not on status (ADR-0012 §4, ADR-0018).
        let inAppBundle = LaunchAtLoginController.isAppBundle
        launchToggle.isEnabled = inAppBundle
        let hint = hintText(inAppBundle: inAppBundle)
        hintLabel.stringValue = hint
        // Collapse the hint when empty (the neutral state) so the row doesn't keep a dead gap.
        hintLabel.isHidden = hint.isEmpty
    }

    private func syncMonitoredServicesFromConfig() {
        let config = PersistedConfig.monitoredServices
        claudeCodeToggle.state = config.claudeCodeEnabled ? .on : .off
        webDesktopToggle.state = config.webDesktopEnabled ? .on : .off
        chatOnlyRadio.state = config.webDesktopMode == .chatOnly ? .on : .off
        chatAndCoworkRadio.state = config.webDesktopMode == .chatAndCowork ? .on : .off
        updateRadioAvailability()
    }

    private func updateRadioAvailability() {
        let enabled = webDesktopToggle.state == .on
        chatOnlyRadio.isEnabled = enabled
        chatAndCoworkRadio.isEnabled = enabled
    }

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

    private func updateResetCheckboxAvailability() {
        resetIncludeDistantCheckbox.isEnabled = (resetSmartRadio.state == .on)
    }

    // MARK: Notifications sync (#160)

    private func syncNotificationsFromConfig() {
        backToWorkToggle.state = PersistedConfig.backToWorkEnabled ? .on : .off
        notifyStartPicker.dateValue = date(fromMinuteOfDay: PersistedConfig.notifyWindowStartMinute)
        notifyEndPicker.dateValue = date(fromMinuteOfDay: PersistedConfig.notifyWindowEndMinute)
        switch PersistedConfig.notifySuppressDays {
        case .never:  notifyNeverRadio.state = .on
        case .friSat: notifyFriSatRadio.state = .on
        case .satSun: notifySatSunRadio.state = .on
        }
        updateNotifyControlsAvailability()
        updateNotifyDurationLabel()
        refreshNotifyAuthHint()
    }

    /// Grey out (never hide, so the layout doesn't jump) the pickers and radios when the master switch
    /// is off — mirrors the reset-countdown checkbox / WEB-Desktop radio disabling.
    private func updateNotifyControlsAvailability() {
        let on = backToWorkToggle.state == .on
        notifyStartPicker.isEnabled = on
        notifyEndPicker.isEnabled = on
        notifyNeverRadio.isEnabled = on
        notifyFriSatRadio.isEnabled = on
        notifySatSunRadio.isEnabled = on
    }

    /// Update the live "Nh window" duration label from the two pickers (handles wrap + whole-day).
    private func updateNotifyDurationLabel() {
        let start = minuteOfDay(from: notifyStartPicker.dateValue)
        let end = minuteOfDay(from: notifyEndPicker.dateValue)
        let minutes = NotificationSchedule.windowLengthMinutes(startMinute: start, endMinute: end)
        let h = minutes / 60
        let m = minutes % 60
        notifyDurationLabel.stringValue = m == 0 ? "\(h)h window" : "\(h)h \(m)m window"
    }

    /// Refresh the auth/dev hint under the master switch by querying the current notification state.
    private func refreshNotifyAuthHint() {
        BackToWorkNotifier.currentAuthState { [weak self] state in
            self?.applyNotifyAuthHint(state)
        }
    }

    private func applyNotifyAuthHint(_ state: BackToWorkNotifier.AuthState) {
        let text: String
        switch state {
        case .dev:
            text = "Available only for TokenPace.app in /Applications — a dev build can't post "
                + "system notifications."
        case .denied:
            text = "Notifications are turned off for TokenPace. Enable them in System Settings → "
                + "Notifications → TokenPace."
        case .authorized, .notDetermined:
            text = ""
        }
        notifyAuthHint.stringValue = text
        notifyAuthHint.isHidden = text.isEmpty
    }

    // MARK: Minute-of-day ↔ Date (display only)

    /// Map a stored minute-of-day (0…1439) to a `Date` for a picker — on an arbitrary reference day,
    /// since only the hour/minute are ever read back.
    private func date(fromMinuteOfDay minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .minute, value: min(1439, max(0, minute)), to: base) ?? base
    }

    /// Read a picker's `Date` back as a minute-of-day (0…1439) in the current zone.
    private func minuteOfDay(from date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: Actions

    @objc private func monitoredServicesToggled() {
        updateRadioAvailability()
        let config = MonitoredServices(
            claudeCodeEnabled: claudeCodeToggle.state == .on,
            webDesktopEnabled: webDesktopToggle.state == .on,
            webDesktopMode: chatAndCoworkRadio.state == .on ? .chatAndCowork : .chatOnly)
        PersistedConfig.monitoredServices = config
        onMonitoredServicesChange?(config)
    }

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
        return ""
    }

    private static func versionText() -> String {
        let base = TokenPaceKit.version
        guard !LaunchAtLoginController.isAppBundle else { return base }
        if let stub = ProcessInfo.processInfo.environment["TOKENPACE_STUB"] {
            return "\(base) — Dev Build (stub: \(stub))"
        }
        return "\(base) — Dev Build"
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        let wantOn = sender.state == .on
        do {
            if wantOn { try LaunchAtLoginController.enable() }
            else      { try LaunchAtLoginController.disable() }
            lastToggleFailed = false
            AppLogger.lifecycle.notice("launch-at-login: user set \(wantOn, privacy: .public)")
        } catch {
            // Best-effort: roll the switch back and remember the failure so the hint explains it (#69).
            lastToggleFailed = true
            AppLogger.lifecycle.error(
                "launch-at-login: toggle failed: \(error.localizedDescription, privacy: .public)")
            sender.state = wantOn ? .off : .on
        }
        if LaunchAtLogin.needsSystemSettings(LaunchAtLoginController.currentStatus()) {
            LaunchAtLoginController.openLoginItemsSettings()
        }
        syncToggleFromSystem()
    }

    @objc private func toggleCalmColors(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.calmMenuBarColors = on
        AppLogger.lifecycle.notice("calm-colors: menu-bar set \(on, privacy: .public)")
        onCalmColorsChange?(on)
    }

    @objc private func toggleServiceDot(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.showServiceStatusDot = on
        AppLogger.lifecycle.notice("service-status-dot: menu-bar set \(on, privacy: .public)")
        onServiceDotChange?(on)
    }

    @objc private func toggleExtraUsage(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.showExtraUsage = on
        AppLogger.lifecycle.notice("extra-usage-icon: menu-bar set \(on, privacy: .public)")
        onExtraUsageChange?(on)
    }

    /// Persist the "Hide 7-day bar when calm" choice (#94) and notify the app so the menu-bar image
    /// repaints immediately (the toggle changes both the drawing and the vertical layout).
    @objc private func toggleHideCalmSevenDay(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.hideCalmSevenDayBar = on
        AppLogger.lifecycle.notice("hide-calm-7d: menu-bar set \(on, privacy: .public)")
        onHideCalmSevenDayChange?(on)
    }

    @objc private func togglePausePolling(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.pausePollingWhenScreenLocked = on
        AppLogger.lifecycle.notice("screen-lock-pause: setting set \(on, privacy: .public)")
        onPausePollingChange?(on)
    }

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

    // MARK: Notification actions (#160)

    @objc private func toggleBackToWork(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.backToWorkEnabled = on
        AppLogger.lifecycle.notice("back-to-work: enabled set \(on, privacy: .public)")
        updateNotifyControlsAvailability()
        if on {
            // Lazily request authorization on first enable, then refresh the hint with the result.
            onBackToWorkEnabled?({ [weak self] state in self?.applyNotifyAuthHint(state) })
        } else {
            refreshNotifyAuthHint()
        }
    }

    @objc private func notifyTimeChanged(_ sender: NSDatePicker) {
        PersistedConfig.notifyWindowStartMinute = minuteOfDay(from: notifyStartPicker.dateValue)
        PersistedConfig.notifyWindowEndMinute = minuteOfDay(from: notifyEndPicker.dateValue)
        updateNotifyDurationLabel()
        AppLogger.lifecycle.notice(
            "back-to-work: time window set \(PersistedConfig.notifyWindowStartMinute, privacy: .public)–\(PersistedConfig.notifyWindowEndMinute, privacy: .public)")
    }

    @objc private func notifySuppressChanged(_ sender: NSButton) {
        let choice: SuppressDays
        if notifyFriSatRadio.state == .on {
            choice = .friSat
        } else if notifySatSunRadio.state == .on {
            choice = .satSun
        } else {
            choice = .never
        }
        PersistedConfig.notifySuppressDays = choice
        AppLogger.lifecycle.notice("back-to-work: suppress set \(choice.rawValue, privacy: .public)")
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(Self.repoURL)
    }

    // MARK: Updates (#37)

    /// Load both update toggles from `PersistedConfig` and refresh the nested toggle's enablement +
    /// hint. Called from `show()` (via the switch sync), so the window always reflects the stored
    /// choice.
    private func syncUpdatesFromConfig() {
        updatesToggle.state = PersistedConfig.automaticUpdateChecks ? .on : .off
        installAutomaticallyToggle.state = PersistedConfig.installUpdatesAutomatically ? .on : .off
        updateInstallAvailability()
    }

    /// The "Install updates automatically" toggle is only meaningful when update checks are on and
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
            // U+2060 word-joiner keeps "/Applications" from wrapping mid-path; the surrounding spaces
            // stay ordinary so the line can still break cleanly before or after the path.
            hint = "Available only for the TokenPace app in /\u{2060}Applications — a developer build "
                 + "can't replace itself."
        } else if !checksOn {
            hint = "Turn on \u{201C}Check for updates automatically\u{201D} to enable this."
        } else {
            hint = "On by default: downloads and installs a newer release in the background, then "
                 + "restarts. If anything fails, the menu shows a \u{201C}New version available\u{201D} "
                 + "item linking to the release instead."
        }
        installAutomaticallyHint.stringValue = hint
    }

    /// Persist the "Check for updates automatically" choice. Refreshes the nested "Install updates
    /// automatically" enablement, which depends on this. (There is no notification-authorization
    /// request here — #130 removed the banner; the only signal is the dropdown item.)
    @objc private func toggleAutomaticUpdates(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.automaticUpdateChecks = on
        AppLogger.lifecycle.notice("update: automatic checks set \(on, privacy: .public)")
        updateInstallAvailability()
    }

    /// Persist the "Install updates automatically" choice (#122). No immediate action — the decision
    /// to install rides the next found-update path (`AppDelegate.handleUpdateFound`).
    @objc private func toggleInstallAutomatically(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.installUpdatesAutomatically = on
        AppLogger.lifecycle.notice("update-install: auto set \(on, privacy: .public)")
    }

    @objc private func checkNow() {
        onCheckForUpdatesNow?()
    }

    @objc private func openDownload() {
        guard let release = latestRelease, let url = URL(string: release.htmlURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reflect the current update state (#37): show "Update available: vX.Y.Z" + the Download link when
    /// `release` is non-nil, hide the row (and its divider) when up to date. Safe to call while the
    /// window is closed — the About pane is built eagerly, so the outlets always exist.
    func updateAvailability(_ release: GitHubRelease?) {
        latestRelease = release
        if let release {
            updateLineLabel.stringValue = "Update available: \(release.tagName)"
            updatesCard.setRow(updateRow, hidden: false)
        } else {
            updateLineLabel.stringValue = ""
            updatesCard.setRow(updateRow, hidden: true)
        }
    }

    // MARK: Session logs (#110)

    @objc private func toggleArchive(_ sender: NSSwitch) {
        let on = sender.state == .on
        PersistedConfig.archiveEnabled = on
        AppLogger.lifecycle.notice("archive: enabled set \(on, privacy: .public)")
        if on, PersistedConfig.archiveDestination == nil {
            chooseArchiveFolder()   // no folder yet → prompt now, or the toggle does nothing
        }
        updateArchiveStatus()
    }

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

    @objc private func archiveNow() {
        onArchiveNow?()
    }

    /// Reflect the current archive state (#110): the chosen path (or "No folder selected"), the "Last
    /// archived …" line, and the enablement of the Choose…/Archive-now buttons. Safe to call while the
    /// window is closed (the pane is built eagerly).
    func updateArchiveStatus() {
        let enabled = PersistedConfig.archiveEnabled
        let destination = PersistedConfig.archiveDestination

        archiveChooseButton.isEnabled = enabled
        archiveNowButton.isEnabled = enabled && destination != nil

        guard let destination else {
            archivePathLabel.stringValue = "No folder selected"
            archiveStatusLabel.stringValue = ""
            return
        }
        archivePathLabel.stringValue = (destination as NSString).abbreviatingWithTildeInPath

        let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
        let stats = LogArchiver().archiveStats(at: destURL)
        let totals = "\(stats.files) files · \(ByteSize.humanReadable(stats.bytes))"

        if let last = PersistedConfig.lastArchiveSync {
            let when = PopupViewController.ageText(max(0, Date().timeIntervalSince(last)))
            if let summary = archiveSummaryProvider?() {
                archiveStatusLabel.stringValue = "Last archived: \(when) · \(summary.copied) updated · \(totals)"
            } else {
                archiveStatusLabel.stringValue = "Last archived: \(when) · \(totals)"
            }
        } else {
            archiveStatusLabel.stringValue = "Not archived yet — runs daily, or use Archive now. (\(totals))"
        }
    }
}
