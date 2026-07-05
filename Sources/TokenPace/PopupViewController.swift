import AppKit
import TokenPaceKit

// MARK: - PopupBarView

/// A pacing bar drawn inside the popup, in the **same** three-zone style as the menu-bar widget:
/// used (grey) → pacing gap (green/red) → future (teal), with a time-indicator dot. The geometry
/// is a `BarLayout` from `PacingModel`; the colours are the fixed statusline palette (ADR-0005),
/// kept in sync with `StatusItemView` by mirroring the same sRGB values.
final class PopupBarView: NSView {

    var bar: BarLayout? {
        didSet {
            guard bar != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Number of equal sub-intervals the tick ruler splits this window into (`LimitRow.subdivisions`:
    /// 5 for the 5-hour bar, 7 for the 7-day/per-model bars). Draws `subdivisions - 1` interior
    /// ticks; `0` (the default) draws none (issue #38).
    var subdivisions: Int = 0 {
        didSet {
            guard subdivisions != oldValue else { return }
            needsDisplay = true
        }
    }

    private enum Metrics {
        /// Height of the pacing bar itself (the coloured zones + indicator dot).
        static let barHeight: CGFloat = 6
        static let corner: CGFloat = 2
        /// Diameter of the time-indicator dot — 2× the bar height so it reads clearly as the primary
        /// time marker over the pacing zones.
        static let indicatorDiameter: CGFloat = 12
        static let indicatorStroke: CGFloat = 1
        // Tick ruler, drawn *below* the bar like an axis (issue #38, "under-bar ruler" style).
        static let tickLength: CGFloat = 3
        static let tickGap: CGFloat = 2
        static let tickWidth: CGFloat = 1
        /// Total view height: tall enough for the bar + under-bar tick ruler **and** for the dot,
        /// which is centred on the bar and so overhangs it by `indicatorDiameter/2 − barHeight/2`
        /// on top; without that headroom a larger dot would be clipped by the view's frame.
        static let height: CGFloat = max(
            barHeight + tickGap + tickLength,
            indicatorDiameter + tickGap + tickLength)
    }

    /// The fixed view height (bar + under-bar tick ruler), exposed so `PopupViewController` can pin
    /// the hosted bar's height constraint to the same value the view draws into.
    static var viewHeight: CGFloat { Metrics.height }

    // Statusline 256-colour palette (ADR-0005), appearance-aware in the popup: on a dark theme the
    // bars keep the exact menu-bar colours; on a light theme the dark zones (used grey, future
    // teal) and the indicator ring are lightened so they read on a light panel. The pacing-gap green
    // is darkened on light to read against the pale panel; the red stays identical in both themes.
    //
    // NSColor(name:dynamicProvider:) resolves per-appearance and AppKit re-draws on theme change
    // automatically (PopupBarView draws in its real appearance — no manual observation needed).
    private enum Palette {
        /// Pacing gap "on pace": menu-bar green on dark, a deeper green on light for contrast.
        static let gapGreen = dynamic(
            dark: NSColor(srgbRed: 95/255, green: 175/255, blue: 95/255, alpha: 1),
            light: NSColor(srgbRed: 80/255, green: 155/255, blue: 80/255, alpha: 1)
        )
        static let gapRed = NSColor(srgbRed: 215/255, green: 95/255, blue: 95/255, alpha: 1)

        /// Used zone: dark grey on dark, lighter grey on light (still clearly darker than the panel).
        static let used = dynamic(dark: gray(72), light: gray(110))
        /// Future / unused zone: dark teal on dark, lighter teal on light.
        static let future = dynamic(
            dark: NSColor(srgbRed: 0/255, green: 76/255, blue: 76/255, alpha: 1),
            light: NSColor(srgbRed: 55/255, green: 110/255, blue: 110/255, alpha: 1)
        )
        /// Indicator-dot ring: the panel background at reduced opacity, so the ring reads as a soft
        /// separation between the dot and the bar beneath it rather than a hard opaque outline.
        static let indicatorStroke = NSColor.windowBackgroundColor.withAlphaComponent(0.4)

        /// Tick-ruler marks below the bar: a muted neutral, translucent so it stays clearly weaker
        /// than the indicator dot. Appearance-aware so the ruler reads on both light and dark panels.
        static let tick = dynamic(
            dark: NSColor(white: 1, alpha: 0.55),
            light: NSColor(white: 0, alpha: 0.45)
        )

        private static func gray(_ v: CGFloat) -> NSColor {
            NSColor(srgbRed: v/255, green: v/255, blue: v/255, alpha: 1)
        }

        /// Resolves to `dark` under a dark appearance, `light` otherwise; AppKit swaps on theme change.
        private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height) }

    override func draw(_ dirtyRect: NSRect) {
        guard let l = bar else { return }
        // The bar sits below a top margin equal to the dot's overhang — the dot is centred on the
        // bar, so a dot taller than the bar sticks out by `(diameter − barHeight)/2` on each side;
        // the margin keeps that top overhang inside the view (the tick ruler fills the strip below).
        let overhang = max(0, (Metrics.indicatorDiameter - Metrics.barHeight) / 2)
        let rect = NSRect(
            x: bounds.minX, y: bounds.minY + overhang, width: bounds.width, height: Metrics.barHeight)
        let w = rect.width

        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner)
        Palette.future.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        fillZone(from: 0, to: l.usageFraction, in: rect, width: w, color: Palette.used)
        let gapColor = l.pacing == .ahead ? Palette.gapRed : Palette.gapGreen
        fillZone(from: l.gapStart, to: l.gapEnd, in: rect, width: w, color: gapColor)
        NSGraphicsContext.restoreGraphicsState()

        // Tick ruler: `subdivisions - 1` interior marks at k/subdivisions, drawn below the bar and
        // *under* the indicator dot in z-order (so the dot always reads as the primary marker).
        drawTicks(in: rect, width: w)

        // Time-indicator dot at timeFraction, coloured by the raw usage-vs-time relationship.
        let cx = rect.minX + CGFloat(l.timeFraction) * w
        let cy = rect.midY
        let d = Metrics.indicatorDiameter
        let dot = NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        indicatorColor(usage: l.usageFraction, time: l.timeFraction).setFill()
        dot.fill()
        Palette.indicatorStroke.setStroke()
        dot.lineWidth = Metrics.indicatorStroke
        dot.stroke()
    }

    /// Draw the under-bar tick ruler: vertical teeth at each interior window boundary
    /// (`k / subdivisions` for `k` in `1 ..< subdivisions`), pixel-snapped on x. No-op when
    /// `subdivisions < 2` (nothing to subdivide).
    private func drawTicks(in barRect: NSRect, width: CGFloat) {
        guard subdivisions >= 2 else { return }
        let top = barRect.maxY + Metrics.tickGap           // flipped: just below the bar
        let bottom = top + Metrics.tickLength
        Palette.tick.setFill()
        for k in 1 ..< subdivisions {
            let f = CGFloat(k) / CGFloat(subdivisions)
            // Pixel-snap a 1.5px-wide tooth so it stays crisp at @1x and @2x.
            let cx = (barRect.minX + f * width).rounded()
            NSRect(x: cx - Metrics.tickWidth / 2, y: top, width: Metrics.tickWidth, height: bottom - top).fill()
        }
    }

    private func indicatorColor(usage: Double, time: Double) -> NSColor {
        // The dot uses the exact pacing-bar colours (gapGreen/gapRed) so it reads as the same
        // green/red as the gap zone it sits over, not a separate lighter shade. A tie (usage ==
        // time) is still on pace, so it reads green rather than the future teal.
        if usage > time { return Palette.gapRed }
        return Palette.gapGreen
    }

    private func fillZone(from: Double, to: Double, in rect: NSRect, width: CGFloat, color: NSColor) {
        let x0 = rect.minX + CGFloat(from) * width
        let x1 = rect.minX + CGFloat(to) * width
        guard x1 > x0 else { return }
        color.setFill()
        NSRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height).fill()
    }
}

// MARK: - StatusLineLabel

/// A status line whose status **word** is a clickable link to the Claude status page (issue #31).
///
/// `NSTextField`'s built-in `.link` handling needs first-responder/field-editor plumbing that does
/// not work reliably for a label inside an `NSMenu`-hosted view, so the click is handled here: a
/// `mouseDown` whose point falls within ``linkRange`` opens ``linkURL`` via `NSWorkspace`. A
/// tracking area shows the pointing-hand cursor over that range so it reads as a link.
final class StatusLineLabel: NSTextField {

    /// Character range of the linked status word within the attributed string.
    var linkRange: NSRange?
    /// The URL the linked word opens.
    var linkURL: URL?

    override func mouseDown(with event: NSEvent) {
        guard let url = linkURL, hitTestLink(event) else {
            super.mouseDown(with: event)
            return
        }
        NSWorkspace.shared.open(url)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Pointing-hand cursor over the whole label — but only when there is a link (operational
        // rows carry no link, so they keep the default arrow). The label is sized to its content
        // and the linked word sits at its trailing edge, so a label-wide hand is a fine
        // approximation and avoids per-glyph rect math.
        guard linkURL != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Whether `event`'s location falls on the linked word. Uses a `TextKit` layout pass over the
    /// attributed string to map the click point to a character index, then tests membership in
    /// ``linkRange``.
    private func hitTestLink(_ event: NSEvent) -> Bool {
        guard let linkRange, let attributed = attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)

        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: bounds.size)
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let index = layoutManager.characterIndex(
            for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        return NSLocationInRange(index, linkRange)
    }
}

// MARK: - PopupViewController

/// The click-to-open detail popup's content — the thin AppKit shell of issue #11, styled after
/// native macOS menu-bar widgets (battery, etc.): a bold title, two service lines, then one
/// section per limit (separator + bold heading + detail line + pacing bar).
///
/// It owns **no** business logic: it takes a `PopupLayout` (computed in `TokenPaceKit`) and renders
/// it. The model carries raw numbers / semantic enums and the shared `ResetClock` time strings;
/// **every human-readable sentence is assembled here**, in `static` formatters, so a future
/// localisation (Phase 2) touches only this file (ADR-0009).
final class PopupViewController: NSViewController {

    /// The current popup model. Setting it rebuilds the sections. `nil` renders nothing.
    var layout: PopupLayout? {
        didSet {
            guard isViewLoaded, layout != oldValue else { return }
            rebuild()
        }
    }

    private enum Metrics {
        static let width: CGFloat = 280
        static let hPadding: CGFloat = 14
        static let vPadding: CGFloat = 10
        static let rowSpacing: CGFloat = 3
        static let sectionSpacing: CGFloat = 7
        /// Gap between the bold title and the dim "Updated … · interval …" line beneath it — wider
        /// than `rowSpacing` so the title reads as its own line, not crowded by the service line.
        static let titleSpacing: CGFloat = 11
        /// Extra breathing room on **both** sides of a horizontal rule, so each separator sits in
        /// its own white space rather than hugging the lines above/below it.
        static let separatorPadding: CGFloat = 10
        /// Pacing-bar width. 240 = the original 200 widened by 20 % (user preference); still inside
        /// the 252 pt content width (`width − 2·hPadding`), with ~12 pt to spare.
        static let barWidth: CGFloat = 240
    }

    private let stack = NSStackView()

    /// The app title shown bold at the top of the popup. A constant — not localised.
    private static let appTitle = "TokenPace"

    override func loadView() {
        let container = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.vPadding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.hPadding),
            container.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Metrics.hPadding),
            container.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Metrics.vPadding),
            container.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])
        self.view = container
        rebuild()
    }

    // MARK: Rendering

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let layout else { return }

        // Title (first line), then — directly beneath it, before any rule — a single dim service
        // line: "Updated 2m ago  ·  interval 3m". A wider gap separates it from the bold title.
        let title = addLabel(Self.appTitle, font: .boldSystemFont(ofSize: 13))
        stack.setCustomSpacing(Metrics.titleSpacing, after: title)
        addLabel(
            Self.serviceLineText(lastUpdateAge: layout.lastUpdateAge, intervalSeconds: layout.intervalSeconds),
            font: .systemFont(ofSize: 11), secondary: true)
        addSeparator()

        // Claude service status (issue #31): one line per component, directly under the title block
        // and before the limit sections. Shown only once the first status poll has landed (`nil` on
        // cold start → no lines). Each line carries a colour dot and a status word that links to the
        // status page (unless operational).
        if let status = layout.serviceStatus {
            addServiceStatusRow(label: "Claude Code", status: status.claudeCode)
            addServiceStatusRow(label: "Claude API", status: status.claudeAPI)
            addSeparator()
        }

        // Error block (when failing): two lines — a bold title led by the ⚠️ symbol, then the
        // detail — followed by its own rule. Shown immediately on any failure (SPEC), so the
        // problem is read before the limit sections.
        if let reason = layout.warning {
            addWarningTitle(Self.warningTitle(reason))
            addWrappingLabel(Self.warningDetail(reason), font: .systemFont(ofSize: 11), secondary: true)
            addSeparator()
        }

        // One section per limit row: separator + "title · status" line + "% used · resets" line + bar.
        // The first section reuses the title-block rule when no status/warning block sits between.
        for row in layout.rows {
            addSeparatorIfNeeded()
            addTitleStatusLine(title: row.title, status: Self.statusText(row.indicator, row.pacing))
            addLabel(Self.detailText(row), font: .systemFont(ofSize: 11), secondary: true)
            addBar(row)
        }

        // Drop a trailing rule. When there are no limit rows (e.g. an auth failure before any
        // snapshot ever landed) the status/warning block ends in its own separator, which would
        // then sit flush against the native NSMenu `.separator()` placed before "Settings…" — two
        // stacked rules. The popup's last visible element should be content, never a rule; the menu
        // supplies the divider to the action items below.
        if let last = stack.arrangedSubviews.last as? NSBox, last.boxType == .separator {
            last.removeFromSuperview()
        }
    }

    /// The section's first line: the **bold** window title in `labelColor`, then the separator and
    /// the pacing status in **normal** weight and a **dim** `secondaryLabelColor` — the status is
    /// de-emphasised by both weight and colour, matching the dim service line under the title. Built
    /// as one attributed string so the two parts sit on a single line.
    @discardableResult
    private func addTitleStatusLine(title: String, status: String) -> NSView {
        let attributed = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
        attributed.append(NSAttributedString(string: Self.separator + status, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let label = NSTextField(labelWithAttributedString: attributed)
        stack.addArrangedSubview(label)
        return label
    }

    @discardableResult
    private func addLabel(_ text: String, font: NSFont, secondary: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        stack.addArrangedSubview(label)
        return label
    }

    /// A label that **wraps** onto multiple lines instead of clipping — for the error detail, whose
    /// text can be the server's own response body (`authHTTP`) and so be arbitrarily long. A plain
    /// `labelWithString:` is single-line and would truncate; `wrappingLabelWithString:` wraps, but
    /// only once pinned to a concrete width — `NSMenu` lays the hosted view out from its frame, not
    /// Auto Layout, so without a width anchor the field grows to its intrinsic single-line width and
    /// never breaks. We pin it to the content width (`width − 2·hPadding`) and set
    /// `preferredMaxLayoutWidth` to match, so it wraps at word boundaries within the popup.
    @discardableResult
    private func addWrappingLabel(_ text: String, font: NSFont, secondary: Bool = false) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        let contentWidth = Metrics.width - 2 * Metrics.hPadding
        label.preferredMaxLayoutWidth = contentWidth
        label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(label)
        return label
    }

    /// The error block's bold first line: a ⚠️ symbol attachment followed by `text`, both in the
    /// system red so the failure reads at a glance. The symbol is the popup counterpart of the
    /// menu-bar glyph (issue #12); using `.systemRed` (not the fixed palette sRGB) lets the popup,
    /// which is appearance-aware, keep contrast on light and dark panels alike.
    @discardableResult
    private func addWarningTitle(_ text: String) -> NSView {
        let font = NSFont.boldSystemFont(ofSize: 12)
        let color = NSColor.systemRed
        let attributed = NSMutableAttributedString()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "warning")?
            .withSymbolConfiguration(symbolConfig) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attributed.append(NSAttributedString(attachment: attachment))
            attributed.append(NSAttributedString(string: "  "))
        }
        attributed.append(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]))

        let label = NSTextField(labelWithAttributedString: attributed)
        stack.addArrangedSubview(label)
        return label
    }

    private func addBar(_ row: LimitRow) {
        let view = PopupBarView()
        view.bar = row.bar
        view.subdivisions = row.subdivisions
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Metrics.barWidth).isActive = true
        view.heightAnchor.constraint(equalToConstant: PopupBarView.viewHeight).isActive = true
        stack.addArrangedSubview(view)
        stack.setCustomSpacing(Metrics.sectionSpacing, after: view)
    }

    private func addSeparator() {
        // Pad the element above the rule (if any) so the gap is symmetric on both sides.
        if let previous = stack.arrangedSubviews.last {
            stack.setCustomSpacing(Metrics.separatorPadding, after: previous)
        }
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.hPadding).isActive = true
        stack.addArrangedSubview(box)
        stack.setCustomSpacing(Metrics.separatorPadding, after: box)
    }

    /// Add a rule **unless** the last element already is one — so consecutive optional blocks (the
    /// title rule, then status / warning / first limit) never produce two stacked separators when an
    /// in-between block is absent.
    private func addSeparatorIfNeeded() {
        if let last = stack.arrangedSubviews.last as? NSBox, last.boxType == .separator { return }
        addSeparator()
    }

    // MARK: Service status row (issue #31)

    /// One Claude-service status line: a colour dot for `status`, the component `label`, then the
    /// status **word**. When the component is **not** `operational`, the word is a link to the
    /// status page (there is something to go look at); when it *is* operational, the word is plain
    /// secondary text — no link, since the status page would add nothing. The dot mirrors
    /// `addWarningTitle`'s symbol-attachment technique (`circle.fill` tinted via `paletteColors`);
    /// the link, when present, is handled explicitly by `StatusLineLabel` because `NSTextField`'s
    /// built-in `.link` handling is unreliable inside an `NSMenu`-hosted view.
    @discardableResult
    private func addServiceStatusRow(label: String, status: ServiceStatus) -> NSView {
        let font = NSFont.systemFont(ofSize: 11)
        let attributed = NSMutableAttributedString()

        // Colour dot — same attachment approach as the warning triangle, tinted by status.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [Self.dotColor(status)]))
        if let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: status == .operational ? "operational" : "issue")?
            .withSymbolConfiguration(symbolConfig) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attributed.append(NSAttributedString(attachment: attachment))
            attributed.append(NSAttributedString(string: "  "))
        }

        // Prefix "Claude Code: " in the normal label colour.
        attributed.append(NSAttributedString(string: "\(label): ", attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]))

        // Status word. Operational → plain secondary text (no link). Otherwise → underlined link
        // colour, opened on click by StatusLineLabel over the word's range.
        let word = Self.word(status)
        let isLink = status != .operational
        let wordStart = attributed.length
        attributed.append(NSAttributedString(string: word, attributes: isLink
            ? [.font: font, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))

        let field = StatusLineLabel(labelWithAttributedString: attributed)
        if isLink {
            field.linkRange = NSRange(location: wordStart, length: (word as NSString).length)
            field.linkURL = StatusHealth.pageURL
        }
        stack.addArrangedSubview(field)
        return field
    }

    /// AppKit colour for one service status — the popup's indicator palette. Appearance-aware
    /// `system*` colours (not the fixed sRGB bar palette) so the dot keeps contrast on light and
    /// dark panels, exactly like the warning triangle's `.systemRed`. Exhaustive, no `default`.
    static func dotColor(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .operational:      return .systemGreen
        case .degraded:         return .systemYellow
        case .partialOutage:    return .systemOrange
        case .majorOutage:      return .systemRed
        case .underMaintenance: return .systemBlue
        case .unknown:          return .systemGray
        }
    }

    /// The human status word shown after the component name. Exhaustive, no `default`, so a new
    /// `ServiceStatus` case breaks the build until consciously worded (like `warningTitle`).
    static func word(_ status: ServiceStatus) -> String {
        switch status {
        case .operational:      return "operational"
        case .degraded:         return "degraded"
        case .partialOutage:    return "partial outage"
        case .majorOutage:      return "major outage"
        case .underMaintenance: return "maintenance"
        case .unknown:          return "unknown"
        }
    }

    // MARK: - Pure text formatters (the localisation seam)

    /// The separator between fields on both popup lines: two spaces, a middle dot (U+00B7), two
    /// spaces. A single constant so line 1 ("title · status") and line 2 ("% used · resets") match.
    static let separator = "  \u{00B7}  "

    /// `"20% used  ·  resets in ~20m at 05:30"` — the per-limit **second** line (the first line is
    /// "title · status", built in `addTitleStatusLine`). The relative countdown is always prefixed
    /// `~` (every value is rounded, ``ResetClock/relativeRounded``); the " at hh:mm" is appended only
    /// when the model carries an absolute time (reset < 24 h away). A reset that is now/past (no
    /// relative string) reads as "resetting…".
    static func detailText(_ row: LimitRow) -> String {
        var parts = ["\(percent(row.utilization)) used"]
        if let rel = row.resetRelative {
            var reset = "resets in ~\(rel)"
            if let abs = row.resetAbsolute { reset += " at \(abs)" }
            parts.append(reset)
        } else {
            parts.append("resetting…")
        }
        return parts.joined(separator: separator)
    }

    /// The single dim line under the title: `"Updated 2m ago  ·  interval 3m"` — combines data age
    /// and the current polling cadence on one line (replacing the former two "Last update" /
    /// "Update interval" rows). Uses the shared middle-dot ``separator``.
    static func serviceLineText(lastUpdateAge: TimeInterval, intervalSeconds: TimeInterval) -> String {
        "\(updatedText(lastUpdateAge))\(separator)interval \(duration(Int(intervalSeconds)))"
    }

    /// `"Updated 2m ago"`, or `"Updated just now"` for anything under a full minute — the age never
    /// shows seconds (user preference), so a sub-minute age reads as "just now", not "40s".
    static let justNowThreshold = 60
    static func updatedText(_ ageSeconds: TimeInterval) -> String {
        let age = Int(ageSeconds)
        return age < justNowThreshold
            ? "Updated just now"
            : "Updated \(durationMinutes(age)) ago"
    }

    /// Like ``duration`` but **never** emits a seconds component — minutes are the finest unit, so
    /// the "Last update" line stays second-free even just past the minute boundary.
    private static func durationMinutes(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "\(hours)h" : "\(hours)h \(m)m"
        }
        let days = hours / 24
        let h = hours % 24
        return h == 0 ? "\(days)d" : "\(days)d \(h)h"
    }

    // MARK: Warning banner (issue #12)

    /// The bold first line of the warning banner — a short title per failure cause. For an HTTP
    /// auth error it embeds the status code; the body text goes on the detail line below.
    static func warningTitle(_ reason: FailureReason) -> String {
        switch reason {
        case .notSignedIn:               return "Missing auth token"
        case let .authHTTP(status, _):   return "Auth error (HTTP \(status))"
        case .timeout, .cannotResolveHost, .network:
            return "Claude API connectivity issue"
        case .serverProblem:             return "Usage API unavailable"
        case .unknown:                   return "Could not fetch usage"
        }
    }

    /// The detail (second) line of the warning banner — the explanation/next step. For an HTTP auth
    /// error this is the server's own response body (sans status code) when present, else a generic
    /// line.
    static func warningDetail(_ reason: FailureReason) -> String {
        switch reason {
        case .notSignedIn:
            return "You need to authenticate in Claude Code console app first"
        case let .authHTTP(_, body):
            return body ?? "Your authorization was rejected — sign in to Claude Code again"
        case .timeout:
            return "Authentication API timeout"
        case .cannotResolveHost:
            return "Unable to resolve API endpoint hostname"
        case let .network(message):
            return message
        case .serverProblem:
            return "The usage API is unavailable right now — retrying automatically"
        case .unknown:
            return "Could not fetch usage data"
        }
    }

    // MARK: Formatter helpers

    private static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Pacing/severity in words. Severity (critical/warning) wins over the plain pacing direction.
    private static func statusText(_ indicator: LimitIndicator, _ pacing: PacingState) -> String {
        switch indicator {
        case .critical: return "limit reached"
        case .warning:  return "ahead of pace ⚠"
        case .neutral:  return pacing == .ahead ? "ahead of pace" : "on pace"
        }
    }

    /// Compact duration from whole seconds: `<60s → "Ns"`, `<60m → "Nm"`, `<24h → "Nh Mm"`
    /// (zero trailing minute dropped), else `"Nd Mh"`.
    private static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "\(hours)h" : "\(hours)h \(m)m"
        }
        let days = hours / 24
        let h = hours % 24
        return h == 0 ? "\(days)d" : "\(days)d \(h)h"
    }
}
