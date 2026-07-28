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
        static let startSize = NSSize(width: 840, height: 720)
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
        // No `setFrameAutosaveName`: the window opens at `startSize`, centred, every time (see `show()`)
        // rather than restoring a saved frame. A restored frame can outlive its display layout
        // (disconnected monitor, changed resolution/scale) and reopen off-screen; centring is always
        // on-screen. The window stays user-resizable within the session.
        self.init(window: window)
        buildContent()
    }

    /// Show or re-focus the window, rendering the latest poll output. Bringing an accessory app's
    /// window forward needs `NSApp.activate`; `makeKeyAndOrderFront` focuses the single instance.
    func show(_ output: PollOutput?) {
        render(output)
        NSApp.activate(ignoringOtherApps: true)
        // Each fresh open resets to the default size and re-centres — the frame isn't persisted, so a
        // previous in-session resize doesn't carry over, and the window is always fully on-screen.
        if !(window?.isVisible ?? false) {
            window?.setContentSize(Metrics.startSize)
            window?.center()
        }
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

        // Header row: the section title on the left, a borderless "copy JSON" icon button on the
        // right (pinned there by a low-hugging spacer). The button copies the body verbatim — the
        // same text ⌘C copies from a selection — so a payload can be lifted into a bug report with
        // one click. The row spans the section's full width so the button sits at the right edge.
        let copyButton = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy JSON")!,
            target: self, action: #selector(copyBodyClicked))
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.setButtonType(.momentaryChange)
        copyButton.toolTip = "Copy the response body to the clipboard"
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [apiHeader, headerSpacer, copyButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Metrics.rowSpacing
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Vertical stack for the API section's info rows (intrinsic height). The header row sits
        // above it as a separate, full-width subview so the copy button can reach the right edge.
        let apiStack = NSStackView(views: [timestampLabel, statusLabel])
        apiStack.orientation = .vertical
        apiStack.alignment = .leading
        apiStack.spacing = Metrics.rowSpacing
        apiStack.translatesAutoresizingMaskIntoConstraints = false

        // The scrollable raw body — takes the remaining vertical space, so it must stretch.
        //
        // It is **editable, but every mutation is vetoed** by the delegate (see
        // `textView(_:shouldChangeTextIn:)`), rather than `isEditable = false`. Editable is what gives
        // a blinking insertion-point caret and full arrow-key caret navigation (word/line jumps,
        // shift-selection); a read-only view has neither. The veto keeps the content immutable.
        // Clipboard shortcuts do NOT ride the native path here: an accessory app has no Edit menu, so
        // the ⌘C/⌘A key-equivalent pass finds no handler, falls through to `noResponderFor:` → `NSBeep`
        // (and never copies). `ReadOnlyTextView.performKeyEquivalent(_:)` claims ⌘C/⌘A/⌘X itself,
        // which both copies and suppresses the beep — see that type.
        let scroll = ReadOnlyTextView.scrollableTextView()
        bodyTextView = (scroll.documentView as! ReadOnlyTextView)
        bodyTextView.isEditable = true
        bodyTextView.isSelectable = true
        bodyTextView.allowsUndo = false
        bodyTextView.delegate = self
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
        content.addSubview(headerRow)
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

            // Full-width header row (title + right-aligned copy button), then the info rows below it.
            headerRow.topAnchor.constraint(equalTo: tokenStack.bottomAnchor, constant: Metrics.interSectionSpacing),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: pad),

            apiStack.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Metrics.headerSpacing),
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

    /// Copy the response body verbatim to the clipboard for a bug report. Reads `bodyTextView.string`
    /// — exactly what is displayed (`TroubleshootLayout.bodyText`), the pretty-printed JSON or error
    /// payload. First `NSPasteboard` use in the codebase.
    @objc private func copyBodyClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bodyTextView.string, forType: .string)
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

        // Only rebuild the body when the text actually changed — reassigning it would drop the
        // user's selection and scroll position on every live poll (ADR-0020). When the body is JSON
        // (`bodyIsJSON`) it is syntax-highlighted; otherwise it is monolithic monospace.
        if bodyTextView.string != layout.bodyText {
            bodyTextView.textStorage?.setAttributedString(
                Self.bodyAttributedString(layout.bodyText, isJSON: layout.bodyIsJSON))
        }
    }

    // MARK: JSON syntax highlighting

    /// Build the attributed body: the base monospace font in `labelColor`, then — for a JSON body —
    /// a foreground colour per token from the pure ``JSONHighlighter``. Non-JSON bodies (error
    /// payloads, placeholders) get the base attributes only, reading as plain monospace as before.
    private static func bodyAttributedString(_ text: String, isJSON: Bool) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: base)
        guard isJSON else { return attributed }

        let full = attributed.length
        for token in JSONHighlighter.tokens(in: text) {
            // Guard against any range drift (the tokenizer works on the same string, so this is
            // belt-and-suspenders) before touching the storage.
            guard token.range.location >= 0,
                  token.range.location + token.range.length <= full else { continue }
            attributed.addAttribute(
                .foregroundColor, value: Self.color(for: token.kind), range: token.range)
        }
        return attributed
    }

    /// Map a JSON token kind to its highlight colour. The base is a system semantic colour; in the
    /// **light** appearance it is darkened a touch so the tokens read with more contrast against the
    /// white background (the bright system tints are tuned for dark mode). The **dark** appearance
    /// keeps the system colours as-is. `punctuation` stays `tertiaryLabelColor` (already adaptive and
    /// intentionally muted) in both.
    private static func color(for kind: JSONHighlighter.JSONTokenKind) -> NSColor {
        switch kind {
        case .key: return Self.dynamic(light: Self.darkened(.systemBlue), dark: .systemBlue)
        case .string: return Self.dynamic(light: Self.darkened(.systemGreen), dark: .systemGreen)
        case .number: return Self.dynamic(light: Self.darkened(.systemOrange), dark: .systemOrange)
        case .bool: return Self.dynamic(light: Self.darkened(.systemPurple), dark: .systemPurple)
        case .null: return Self.dynamic(light: Self.darkened(.systemPurple), dark: .systemPurple)
        case .punctuation: return .tertiaryLabelColor
        }
    }

    /// Darken a system colour for the light appearance — blend a fraction of black into it, in the
    /// sRGB space (system colours resolve cleanly there). ~28 % reads noticeably deeper without going
    /// muddy.
    private static func darkened(_ color: NSColor) -> NSColor {
        (color.usingColorSpace(.sRGB) ?? color).blended(withFraction: 0.28, of: .black) ?? color
    }

    /// An appearance-aware colour: resolves to `light` under Aqua and `dark` under Dark Aqua. Uses
    /// `NSColor(name:dynamicProvider:)` so the `NSTextView` re-resolves it if the system theme flips
    /// while the window is open.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
}

// MARK: - NSTextViewDelegate

extension TroubleshootWindowController: NSTextViewDelegate {
    /// Veto every user-driven text change so the body stays read-only while the view is technically
    /// editable (which is what supplies the caret, arrow navigation, and beep-free ⌘C/⌘A — see the
    /// body-setup comment). This is the single choke point for typing, paste (⌘V), delete, and
    /// drag-drop insertion — all funnel through here before mutating storage. Programmatic
    /// `bodyTextView.string = …` in `render(_:)` bypasses this path, so live updates still apply.
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        false
    }
}

// MARK: - ReadOnlyTextView

/// An `NSTextView` for a read-only body in an accessory app that has **no Edit menu**.
///
/// Two custom behaviours, both needed because there is no menu to carry the standard clipboard key
/// equivalents:
/// - `performKeyEquivalent(_:)` handles ⌘C / ⌘A / ⌘X itself. In Cocoa a Command chord is first
///   offered as a key equivalent down the responder chain; with no Edit menu nothing claims ⌘C/⌘A,
///   the pass returns `false`, and the event falls through to `noResponderFor:` → `NSBeep` (and copy
///   never happens). Claiming them here calls the action and returns `true`, so copy/select-all work
///   **and** the beep is suppressed. Matched by `keyCode` (layout-independent — on a non-Latin layout
///   the C key reports a non-"c" character, so a character match would miss).
/// - `cut(_:)` is a plain copy: the view is editable-but-edit-vetoed (that supplies the caret + arrow
///   navigation), so a real cut would copy then have its delete rejected — this makes ⌘X explicit.
final class ReadOnlyTextView: NSTextView {
    /// ANSI virtual key codes (Carbon `kVK_ANSI_*`) — layout-independent physical keys.
    private enum KeyCode {
        static let a: UInt16 = 0
        static let c: UInt16 = 8
        static let x: UInt16 = 7
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.keyCode {
            case KeyCode.c: copy(nil);      return true
            case KeyCode.a: selectAll(nil); return true
            case KeyCode.x: cut(nil);       return true   // cut == copy (see type doc)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cut(_ sender: Any?) { copy(sender) }
}
