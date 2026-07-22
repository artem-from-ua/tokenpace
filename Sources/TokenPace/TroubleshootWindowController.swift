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

    private enum Metrics {
        static let minSize = NSSize(width: 480, height: 360)
        static let startSize = NSSize(width: 640, height: 560)
        static let padding: CGFloat = 16
        static let rowSpacing: CGFloat = 4
        static let sectionSpacing: CGFloat = 12
    }

    // Header + rows of the "Usage API — last response" section.
    private var timestampLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var nextUpdateLabel: NSTextField!
    // The scrollable raw body (pretty JSON or error payload).
    private var bodyTextView: NSTextView!
    // Rows of the "Auth token" section.
    private var tokenReadLabel: NSTextField!
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

        let apiHeader = Self.sectionHeader("Usage API — last response")
        timestampLabel = Self.infoLabel()
        statusLabel = Self.infoLabel()
        nextUpdateLabel = Self.infoLabel()

        // Vertical stack for the API section's header + info rows (intrinsic height).
        let apiStack = NSStackView(views: [apiHeader, timestampLabel, statusLabel, nextUpdateLabel])
        apiStack.orientation = .vertical
        apiStack.alignment = .leading
        apiStack.spacing = Metrics.rowSpacing
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

        let tokenHeader = Self.sectionHeader("Auth token")
        tokenReadLabel = Self.infoLabel()
        tokenExpiryLabel = Self.infoLabel()
        let tokenStack = NSStackView(views: [tokenHeader, tokenReadLabel, tokenExpiryLabel])
        tokenStack.orientation = .vertical
        tokenStack.alignment = .leading
        tokenStack.spacing = Metrics.rowSpacing
        tokenStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(apiStack)
        content.addSubview(scroll)
        content.addSubview(tokenStack)

        let pad = Metrics.padding
        NSLayoutConstraint.activate([
            apiStack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            apiStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: apiStack.trailingAnchor, constant: pad),

            scroll.topAnchor.constraint(equalTo: apiStack.bottomAnchor, constant: Metrics.sectionSpacing),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: pad),

            tokenStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Metrics.sectionSpacing),
            tokenStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: tokenStack.trailingAnchor, constant: pad),
            content.bottomAnchor.constraint(equalTo: tokenStack.bottomAnchor, constant: pad),
        ])
        window?.contentView = content
    }

    /// A bold section header label.
    private static func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    /// A secondary info-row label.
    private static func infoLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
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
        nextUpdateLabel.stringValue = layout.nextUpdateLine ?? ""
        nextUpdateLabel.isHidden = layout.nextUpdateLine == nil
        tokenReadLabel.stringValue = layout.tokenReadLine
        tokenExpiryLabel.stringValue = layout.tokenExpiryLine ?? ""
        tokenExpiryLabel.isHidden = layout.tokenExpiryLine == nil

        if bodyTextView.string != layout.bodyText {
            bodyTextView.string = layout.bodyText
        }
    }
}
