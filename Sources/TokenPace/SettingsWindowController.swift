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
    }

    /// The launch-at-login checkbox — its state is synced from the live `SMAppService` status every
    /// time the window is shown (the user may have changed it in System Settings meanwhile).
    private var launchToggle: NSButton!

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

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(
            equalToConstant: Metrics.width - 2 * Metrics.padding).isActive = true

        let versionLabel = NSTextField(labelWithString: "Version \(TokenPaceKit.version)")
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
        hintLabel.stringValue = hintText(inAppBundle: inAppBundle)

        // The hint wraps to a different height per message; refit so neither text is clipped.
        if let content = window?.contentView {
            window?.setContentSize(content.fittingSize)
        }
    }

    /// The explanatory line under the checkbox. Three states: a dev build (`swift run`) is not an
    /// `.app`, so launch-at-login is unavailable; an `.app` where a click just failed points the
    /// user at recovery; otherwise a neutral best-effort note.
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
        return "Launch TokenPace automatically when you log in."
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
}
