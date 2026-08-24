import AppKit
import TokenPaceKit

// MARK: - TroubleshootWindowController

/// The hidden Troubleshoot window (ADR-0020), reached from the popup menu via ⌥ Option on
/// "Settings…". Surfaces the **raw** diagnostics the popup aggregates away: the last usage-API
/// response verbatim, its timestamp, the next-update estimate, and the auth token's read/expiry
/// dates.
///
/// Unlike `SettingsWindowController` (a small, fixed, `.floating` panel), this uses the **normal**
/// level and a resizable, full-screen style: `.floating` fights a full-screen Space, and a large
/// always-on-top window is hostile — a deliberate departure from ADR-0012 §6.
///
/// Single-instance (`isReleasedWhenClosed = false`); its content **updates live**: `render(_:)` is
/// called from `AppDelegate.apply(_:)` on every poll (ADR-0020).
@MainActor
final class TroubleshootWindowController: NSWindowController {

    /// Wired by `AppDelegate` to force an immediate poll and reset any 429 backoff (ADR-0020).
    var onForceRefresh: (() -> Void)?

    private enum Metrics {
        static let minSize = NSSize(width: 480, height: 360)
        static let startSize = NSSize(width: 840, height: 720)
        static let padding: CGFloat = 20
        static let rowSpacing: CGFloat = 4
        /// Wider than `rowSpacing` so the bold header reads as a title, narrower than
        /// `sectionSpacing` (which separates whole groups).
        static let headerSpacing: CGFloat = 8
        static let sectionSpacing: CGFloat = 12
        /// Wider than `sectionSpacing` so "Auth token" and "Usage API" read as distinct groups by
        /// whitespace alone (matches the popup's no-interior-lines style).
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
    /// The weekly reconstruction disclosure (#386) — raw vs reconstructed. Hidden when the two agree.
    private var weeklyLabel: NSTextField!
    /// The weekly reset instant and the mode it was computed in (ADR-0107).
    private var weeklyResetLabel: NSTextField!
    // Rows of the "Auth token" section.
    private var tokenStatusLabel: NSTextField!
    private var tokenExpiryLabel: NSTextField!
    /// The Codex collector's four rows, and the header above them. Both are hidden together while
    /// the quota half is off — an empty section reads as a broken one.
    private var codexHeader: NSTextField!
    private var codexLabels: [NSTextField] = []
    private var codexStack: NSStackView!
    // The "copy JSON" button, held so its glyph can flip to a checkmark after a copy (#257), plus the
    // pending revert back to the copy glyph — cancelled and re-armed on each click.
    private weak var copyButton: NSButton?
    private var copyFeedbackWorkItem: DispatchWorkItem?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.startSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TokenPace — Troubleshoot"
        // Normal level (not .floating) + native full-screen in its own Space (ADR-0020, departing
        // from ADR-0012 §6).
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = Metrics.minSize
        window.isReleasedWhenClosed = false     // keep the controller alive so re-opening reuses it
        // No `setFrameAutosaveName`: a restored frame can outlive its display layout (disconnected
        // monitor, changed resolution) and reopen off-screen; centring is always on-screen.
        self.init(window: window)
        buildContent()
    }

    /// Bringing an accessory app's window forward needs `NSApp.activate`; `makeKeyAndOrderFront`
    /// focuses the single instance.
    func show(_ output: PollOutput?) {
        render(output)
        NSApp.activate(ignoringOtherApps: true)
        // Each fresh open resets to the default size and re-centres — the frame isn't persisted.
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

        // "Update interval" — refresh cadence + next-update estimate, plus a button that forces an
        // immediate poll and clears any 429 backoff (ADR-0020).
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

        // Codex — the quota collector's own source, which has no entry in Claude's `PollOutput`.
        codexHeader = Self.sectionHeader("Codex quota")
        // One per line `CodexQuotaTroubleshoot.lines` can emit. A line with no label to land in is
        // dropped without a word, and the missing one would be the diagnostic somebody opened the
        // window to read — `CodexQuotaTests` asserts the constant against a maximal call.
        codexLabels = (0..<CodexQuotaTroubleshoot.maxLineCount).map { _ in Self.infoLabel() }
        codexStack = NSStackView(views: [codexHeader] + codexLabels)
        codexStack.orientation = .vertical
        codexStack.alignment = .leading
        codexStack.spacing = Metrics.rowSpacing
        codexStack.setCustomSpacing(Metrics.headerSpacing, after: codexHeader)
        codexStack.translatesAutoresizingMaskIntoConstraints = false
        codexStack.isHidden = true

        let apiHeader = Self.sectionHeader("Usage API — last response")
        timestampLabel = Self.infoLabel()
        statusLabel = Self.infoLabel()

        // Section title on the left, a borderless "copy JSON" icon button on the right (pinned there
        // by a low-hugging spacer). Copies the body verbatim so it can be lifted into a bug report.
        let copyButton = NSButton(
            image: NSImage(
                systemSymbolName: CopyFeedback.restingSymbol,
                accessibilityDescription: CopyFeedback.restingLabel(Self.copyTarget))!,
            target: self, action: #selector(copyBodyClicked))
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        // `.momentaryChange` would swap the image back on mouse-up, fighting the checkmark
        // `showCopiedFeedback()` sets — `.momentaryPushIn` leaves the image under our control.
        copyButton.setButtonType(.momentaryPushIn)
        copyButton.toolTip = "Copy \(Self.copyTarget) to the clipboard"
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        self.copyButton = copyButton   // held so the glyph can flash a checkmark after a copy (#257)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [apiHeader, headerSpacer, copyButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Metrics.rowSpacing
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        weeklyLabel = Self.infoLabel()
        weeklyResetLabel = Self.infoLabel()
        let apiStack = NSStackView(views: [timestampLabel, statusLabel, weeklyLabel, weeklyResetLabel])
        apiStack.orientation = .vertical
        apiStack.alignment = .leading
        apiStack.spacing = Metrics.rowSpacing
        apiStack.translatesAutoresizingMaskIntoConstraints = false

        // **Editable, but every mutation is vetoed** by the delegate (`textView(_:shouldChangeTextIn:)`)
        // rather than `isEditable = false`: editable is what supplies the blinking caret and full
        // arrow-key navigation, which a read-only view lacks. Clipboard shortcuts do NOT ride the
        // native path — an accessory app has no Edit menu, so ⌘C/⌘A finds no handler and falls
        // through to `NSBeep`. `ReadOnlyTextView.performKeyEquivalent(_:)` claims them itself.
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
        content.addSubview(codexStack)
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

            codexStack.topAnchor.constraint(equalTo: tokenStack.bottomAnchor, constant: Metrics.interSectionSpacing),
            codexStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: codexStack.trailingAnchor, constant: pad),

            // Full-width header row (title + right-aligned copy button), then the info rows below it.
            headerRow.topAnchor.constraint(equalTo: codexStack.bottomAnchor, constant: Metrics.interSectionSpacing),
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

    /// `.headline` dynamic text style so it scales with the user's system text-size setting.
    private static func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .headline, options: [:])
        label.textColor = .labelColor
        return label
    }

    private static func infoLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .preferredFont(forTextStyle: .body, options: [:])
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func refreshNowClicked() {
        onForceRefresh?()
    }

    /// Flips the glyph to a checkmark per ``CopyFeedback`` (#257) — the clipboard is invisible, so
    /// the swap is the only sign the click landed.
    @objc private func copyBodyClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bodyTextView.string, forType: .string)
        showCopiedFeedback()
    }

    /// The pending revert is cancelled and re-armed on each click, so clicking again mid-flash
    /// restarts the full duration rather than letting the earlier timer clear it early.
    private func showCopiedFeedback() {
        copyFeedbackWorkItem?.cancel()
        copyButton?.image = NSImage(
            systemSymbolName: CopyFeedback.confirmedSymbol,
            accessibilityDescription: CopyFeedback.confirmedLabel)

        let revert = DispatchWorkItem { [weak self] in
            self?.copyButton?.image = NSImage(
                systemSymbolName: CopyFeedback.restingSymbol,
                accessibilityDescription: CopyFeedback.restingLabel(Self.copyTarget))
        }
        copyFeedbackWorkItem = revert
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CopyFeedback.duration, execute: revert)
    }

    private static let copyTarget = "the response body"

    // MARK: Live render

    /// Called from `show(_:)` and — for live updates — from `AppDelegate.apply(_:)` on every poll
    /// (ADR-0020).
    /// Fill the Codex section, or hide it whole when the quota half is off. Called beside
    /// ``render(_:)`` because its source is the collector, not Claude's poll.
    func renderCodex(_ diagnostics: CodexQuotaDiagnostics?, candidates: [String], now: Date) {
        guard let diagnostics else {
            codexStack.isHidden = true
            return
        }
        codexStack.isHidden = false
        let lines = CodexQuotaTroubleshoot.lines(
            binaryPath: diagnostics.binaryPath, candidates: candidates,
            version: diagnostics.version, lastSuccess: diagnostics.lastSuccess,
            lastLatency: diagnostics.lastLatency, lastError: diagnostics.lastError,
            lastResets: diagnostics.lastResets, now: now)
        for (index, label) in codexLabels.enumerated() {
            label.stringValue = index < lines.count ? lines[index] : ""
            // A line the collector had nothing to say for leaves no blank row behind it.
            label.isHidden = index >= lines.count
        }
    }

    func render(_ output: PollOutput?) {
        let layout = TroubleshootLayout.make(from: output)
        timestampLabel.stringValue = layout.timestampLine
        statusLabel.stringValue = layout.statusLine ?? ""
        statusLabel.isHidden = layout.statusLine == nil
        intervalLabel.stringValue = layout.intervalLine ?? ""
        intervalLabel.isHidden = layout.intervalLine == nil
        nextUpdateLabel.stringValue = layout.nextUpdateLine ?? ""
        nextUpdateLabel.isHidden = layout.nextUpdateLine == nil
        weeklyLabel.stringValue = layout.weeklyLine ?? ""
        weeklyLabel.isHidden = layout.weeklyLine == nil
        weeklyResetLabel.stringValue = layout.weeklyResetLine ?? ""
        weeklyResetLabel.isHidden = layout.weeklyResetLine == nil
        tokenStatusLabel.stringValue = layout.tokenStatusLine ?? ""
        tokenStatusLabel.isHidden = layout.tokenStatusLine == nil
        tokenExpiryLabel.stringValue = layout.tokenExpiryLine ?? ""
        tokenExpiryLabel.isHidden = layout.tokenExpiryLine == nil

        // Only rebuild the body when the text actually changed — reassigning it would drop the
        // user's selection and scroll position on every live poll (ADR-0020).
        if bodyTextView.string != layout.bodyText {
            bodyTextView.textStorage?.setAttributedString(
                Self.bodyAttributedString(layout.bodyText, isJSON: layout.bodyIsJSON))
        }
    }

    // MARK: JSON syntax highlighting

    /// Base monospace font in `labelColor`, then — for a JSON body — a foreground colour per token
    /// from ``JSONHighlighter``. Non-JSON bodies get the base attributes only.
    private static func bodyAttributedString(_ text: String, isJSON: Bool) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: base)
        guard isJSON else { return attributed }

        let full = attributed.length
        for token in JSONHighlighter.tokens(in: text) {
            // Belt-and-suspenders guard against range drift before touching the storage.
            guard token.range.location >= 0,
                  token.range.location + token.range.length <= full else { continue }
            attributed.addAttribute(
                .foregroundColor, value: Self.color(for: token.kind), range: token.range)
        }
        return attributed
    }

    /// In the **light** appearance the base system colour is darkened a touch (the bright system
    /// tints are tuned for dark mode); dark keeps them as-is.
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

    /// Blend a fraction of black into it, in sRGB (system colours resolve cleanly there). ~28% reads
    /// noticeably deeper without going muddy.
    private static func darkened(_ color: NSColor) -> NSColor {
        (color.usingColorSpace(.sRGB) ?? color).blended(withFraction: 0.28, of: .black) ?? color
    }

    /// `NSColor(name:dynamicProvider:)` so the `NSTextView` re-resolves it if the theme flips while
    /// the window is open.
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
    /// editable. The single choke point for typing, paste, delete, and drag-drop insertion.
    /// Programmatic `bodyTextView.string = …` in `render(_:)` bypasses this path.
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        false
    }
}

// MARK: - ReadOnlyTextView

/// An `NSTextView` for a read-only body in an accessory app that has **no Edit menu**, so no menu
/// carries the standard clipboard key equivalents.
///
/// - `performKeyEquivalent(_:)` handles ⌘C / ⌘A / ⌘X itself. With no Edit menu, nothing claims
///   ⌘C/⌘A down the responder chain and the event falls through to `NSBeep` without copying.
///   Claiming them here calls the action and returns `true`. Matched by `keyCode`
///   (layout-independent — on a non-Latin layout the C key reports a non-"c" character).
/// - `cut(_:)` is a plain copy: the view is editable-but-edit-vetoed, so a real cut would copy then
///   have its delete rejected.
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
