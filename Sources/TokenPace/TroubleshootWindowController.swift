import AppKit
import TokenPaceKit

// MARK: - TroubleshootWindowController

/// The hidden Troubleshoot window (ADR-0020), reached from the popup menu via ⌥ Option on
/// "Settings…". A large, resizable, full-screen-capable window that surfaces the **raw** diagnostics
/// the popup aggregates away: the last usage-API response verbatim, its timestamp, the next-update
/// estimate, and the auth token's read/expiry dates — so a bug can be diagnosed from the widget
/// alone, without a `log stream` session.
///
/// Unlike `SettingsWindowController` (a small, fixed, `.floating` panel), this window uses the
/// **normal** level and a resizable, full-screen style: `.floating` fights a full-screen Space, and
/// a large always-on-top window is hostile to the user. `NSApp.activate(ignoringOtherApps:)` in
/// `show()` is enough to raise it from an accessory app — a deliberate departure from ADR-0012 §6.
///
/// Single-instance like `SettingsWindowController` (`isReleasedWhenClosed = false`), and its content
/// **updates live**: `render(_:)` is called from `AppDelegate.apply(_:)` on every poll, so an open
/// window refreshes both sections in place (ADR-0020).
@MainActor
final class TroubleshootWindowController: NSWindowController {

    /// Called when the user clicks "Refresh now" — wired by `AppDelegate` to force an immediate poll
    /// of both data streams and reset any 429 backoff (ADR-0020).
    var onForceRefresh: (() -> Void)?

    private enum Metrics {
        static let minSize = NSSize(width: 480, height: 360)
        static let startSize = NSSize(width: 640, height: 560)
        static let padding: CGFloat = 20
        static let rowSpacing: CGFloat = 4
        /// Gap between a section header and its first info row — wider than `rowSpacing` so the
        /// bold header reads as a title above its rows rather than as just another line, without
        /// opening up as much air as `sectionSpacing` (which separates whole groups).
        static let headerSpacing: CGFloat = 8
        static let sectionSpacing: CGFloat = 12
        /// Gap between the "Auth token" and "Usage API" sections — wider than `sectionSpacing` so
        /// the two read as distinct groups by whitespace alone (no rule; matches the popup's
        /// no-interior-lines style — HIG treats negative space and separator lines as equally valid
        /// grouping cues, so this is a stylistic choice, not a compliance one).
        static let interSectionSpacing: CGFloat = 24
    }

    // Header + rows of the "Usage API — last response" section.
    private var timestampLabel: NSTextField!
    private var statusLabel: NSTextField!
    // The scrollable raw body (pretty JSON or error payload).
    private var bodyTextView: NSTextView!
    // Rows of the "Update interval" section (the refresh cadence + next-update estimate).
    private var intervalLabel: NSTextField!
    private var nextUpdateLabel: NSTextField!
    // Rows of the "Auth token" section.
    private var tokenStatusLabel: NSTextField!
    private var tokenExpiryLabel: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.startSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TokenPace — Troubleshoot"
        // Normal level (not .floating) + native full-screen in its own Space (green button):
        // a large diagnostic window must not float above everything or fight a full-screen Space
        // (ADR-0020, departing from ADR-0012 §6).
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = Metrics.minSize
        window.isReleasedWhenClosed = false     // keep the controller alive so re-opening reuses it
        window.setFrameAutosaveName("TokenPaceTroubleshoot")   // remember size/position across opens
        self.init(window: window)
        buildContent()
    }

    /// Show or re-focus the window, rendering the latest poll output. Bringing an accessory app's
    /// window forward needs `NSApp.activate`; `makeKeyAndOrderFront` focuses the single instance.
    func show(_ output: PollOutput?) {
        render(output)
        NSApp.activate(ignoringOtherApps: true)
        if !(window?.isVisible ?? false) { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Content

    private func buildContent() {
        let content = NSView()

        // Auth token — the second section (checked when diagnosing a fetch failure).
        let tokenHeader = Self.sectionHeader("Auth token")
        tokenStatusLabel = Self.infoLabel()
        tokenExpiryLabel = Self.infoLabel()
        let tokenStack = NSStackView(views: [tokenHeader, tokenStatusLabel, tokenExpiryLabel])
        tokenStack.orientation = .vertical
        tokenStack.alignment = .leading
        tokenStack.spacing = Metrics.rowSpacing
        tokenStack.setCustomSpacing(Metrics.headerSpacing, after: tokenHeader)
        tokenStack.translatesAutoresizingMaskIntoConstraints = false

        // "Update interval" — the first section: the refresh cadence (a duration) + the next-update
        // estimate (a timestamp), plus a button that forces an immediate poll of both streams and
        // clears any 429 backoff (ADR-0020). The interval (the rate) sits above the next-update (the
        // when).
        let intervalHeader = Self.sectionHeader("Update interval")
        intervalLabel = Self.infoLabel()
        nextUpdateLabel = Self.infoLabel()
        let refreshButton = NSButton(
            title: "Refresh now", target: self, action: #selector(refreshNowClicked))
        refreshButton.bezelStyle = .rounded
        let intervalStack = NSStackView(views: [
            intervalHeader, intervalLabel, nextUpdateLabel, refreshButton])
        intervalStack.orientation = .vertical
        intervalStack.alignment = .leading
        intervalStack.spacing = Metrics.rowSpacing
        intervalStack.setCustomSpacing(Metrics.headerSpacing, after: intervalHeader)
        intervalStack.setCustomSpacing(Metrics.sectionSpacing, after: nextUpdateLabel)
        intervalStack.translatesAutoresizingMaskIntoConstraints = false

        let apiHeader = Self.sectionHeader("Usage API — last response")
        timestampLabel = Self.infoLabel()
        statusLabel = Self.infoLabel()

        // Vertical stack for the API section's header + info rows (intrinsic height).
        let apiStack = NSStackView(views: [apiHeader, timestampLabel, statusLabel])
        apiStack.orientation = .vertical
        apiStack.alignment = .leading
        apiStack.spacing = Metrics.rowSpacing
        apiStack.setCustomSpacing(Metrics.headerSpacing, after: apiHeader)
        apiStack.translatesAutoresizingMaskIntoConstraints = false

        // The scrollable raw body — takes the remaining vertical space, so it must stretch.
        let scroll = NSTextView.scrollableTextView()
        bodyTextView = (scroll.documentView as! NSTextView)
        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // Smart quotes / dashes would corrupt copied JSON — disable them.
        bodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        bodyTextView.isAutomaticDashSubstitutionEnabled = false
        bodyTextView.isAutomaticTextReplacementEnabled = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(tokenStack)
        content.addSubview(intervalStack)
        content.addSubview(apiStack)
        content.addSubview(scroll)

        let pad = Metrics.padding
        NSLayoutConstraint.activate([
            // Order top-to-bottom: Update interval, Auth token, Usage API, then the scrollable body.
            intervalStack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            intervalStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: intervalStack.trailingAnchor, constant: pad),

            tokenStack.topAnchor.constraint(equalTo: intervalStack.bottomAnchor, constant: Metrics.interSectionSpacing),
            tokenStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: tokenStack.trailingAnchor, constant: pad),

            apiStack.topAnchor.constraint(equalTo: tokenStack.bottomAnchor, constant: Metrics.interSectionSpacing),
            apiStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: apiStack.trailingAnchor, constant: pad),

            scroll.topAnchor.constraint(equalTo: apiStack.bottomAnchor, constant: Metrics.sectionSpacing),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: pad),
            content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: pad),
        ])
        window?.contentView = content
    }

    /// A section header label — the `.headline` dynamic text style (bold, `labelColor`) so it
    /// scales with the user's system text-size setting like a native control, instead of a fixed
    /// point size (HIG: prefer the system's dynamic text styles over hard-coded sizes).
    private static func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .headline, options: [:])
        label.textColor = .labelColor
        return label
    }

    /// A secondary info-row label — the `.body` dynamic text style in `secondaryLabelColor`, so
    /// diagnostic rows read at the same size as the rest of the system and scale together.
    private static func infoLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .preferredFont(forTextStyle: .body, options: [:])
        label.textColor = .secondaryLabelColor
        return label
    }

    /// The "Refresh now" button — hand off to `AppDelegate.forceRefresh()` via `onForceRefresh`.
    /// The live `render(_:)` on the resulting poll updates the interval / next-update rows in place.
    @objc private func refreshNowClicked() {
        onForceRefresh?()
    }

    // MARK: Live render

    /// Map the pure ``TroubleshootLayout`` onto the views. Called from `show(_:)` and — for live
    /// updates — from `AppDelegate.apply(_:)` on every poll (ADR-0020). To keep the user's text
    /// selection and scroll position across a live update, the body is only reassigned when it
    /// actually changed.
    func render(_ output: PollOutput?) {
        let layout = TroubleshootLayout.make(from: output)
        timestampLabel.stringValue = layout.timestampLine
        statusLabel.stringValue = layout.statusLine ?? ""
        statusLabel.isHidden = layout.statusLine == nil
        intervalLabel.stringValue = layout.intervalLine ?? ""
        intervalLabel.isHidden = layout.intervalLine == nil
        nextUpdateLabel.stringValue = layout.nextUpdateLine ?? ""
        nextUpdateLabel.isHidden = layout.nextUpdateLine == nil
        tokenStatusLabel.stringValue = layout.tokenStatusLine ?? ""
        tokenStatusLabel.isHidden = layout.tokenStatusLine == nil
        tokenExpiryLabel.stringValue = layout.tokenExpiryLine ?? ""
        tokenExpiryLabel.isHidden = layout.tokenExpiryLine == nil

        if bodyTextView.string != layout.bodyText {
            bodyTextView.string = layout.bodyText
        }
    }
}
