import AppKit
import CCTimerKit

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
        static let indicatorDiameter: CGFloat = 8
        static let indicatorStroke: CGFloat = 1
        // Tick ruler, drawn *below* the bar like an axis (issue #38, "under-bar ruler" style).
        static let tickLength: CGFloat = 3
        static let tickGap: CGFloat = 2
        static let tickWidth: CGFloat = 1
        /// Total view height: bar + gap + tick teeth hanging beneath it.
        static let height: CGFloat = barHeight + tickGap + tickLength
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

        /// Time-indicator dot colours — the gap colours lightened ~30 % (white-mixed) so the dot
        /// reads brighter than the pacing gap it sits over. Only the dot uses these; the gap zones
        /// keep `gapGreen`/`gapRed`. Green stays appearance-aware (lightened from each theme's base).
        static let dotGreen = dynamic(
            dark: NSColor(srgbRed: 143/255, green: 199/255, blue: 143/255, alpha: 1),
            light: NSColor(srgbRed: 133/255, green: 185/255, blue: 133/255, alpha: 1)
        )
        static let dotRed = NSColor(srgbRed: 227/255, green: 143/255, blue: 143/255, alpha: 1)

        /// Used zone: dark grey on dark, lighter grey on light (still clearly darker than the panel).
        static let used = dynamic(dark: gray(72), light: gray(110))
        /// Future / unused zone: dark teal on dark, lighter teal on light.
        static let future = dynamic(
            dark: NSColor(srgbRed: 0/255, green: 76/255, blue: 76/255, alpha: 1),
            light: NSColor(srgbRed: 55/255, green: 110/255, blue: 110/255, alpha: 1)
        )
        /// Indicator-dot ring: near-black on dark, mid grey on light.
        static let indicatorStroke = NSColor.windowBackgroundColor

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
        // The bar occupies the top `barHeight` of the view (flipped coords → minY is the top); the
        // tick ruler hangs in the remaining strip below it.
        let rect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: Metrics.barHeight)
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
        if usage > time { return Palette.dotRed }
        if usage < time { return Palette.dotGreen }
        return Palette.future
    }

    private func fillZone(from: Double, to: Double, in rect: NSRect, width: CGFloat, color: NSColor) {
        let x0 = rect.minX + CGFloat(from) * width
        let x1 = rect.minX + CGFloat(to) * width
        guard x1 > x0 else { return }
        color.setFill()
        NSRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height).fill()
    }
}

// MARK: - PopupViewController

/// The click-to-open detail popup's content — the thin AppKit shell of issue #11, styled after
/// native macOS menu-bar widgets (battery, etc.): a bold title, two service lines, then one
/// section per limit (separator + bold heading + detail line + pacing bar).
///
/// It owns **no** business logic: it takes a `PopupLayout` (computed in `CCTimerKit`) and renders
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
        /// Extra breathing room on **both** sides of a horizontal rule, so each separator sits in
        /// its own white space rather than hugging the lines above/below it.
        static let separatorPadding: CGFloat = 10
        static let barWidth: CGFloat = 200
    }

    private let stack = NSStackView()

    /// The app title shown bold at the top of the popup. A constant — not localised.
    private static let appTitle = "Claude Code Timer (cc-timer)"

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

        // Title (first line), then a horizontal rule separating it from what follows.
        addLabel(Self.appTitle, font: .boldSystemFont(ofSize: 13))
        addSeparator()

        // Error block (when failing): two lines — a bold title led by the ⚠️ symbol, then the
        // detail — followed by its own rule. Shown immediately on any failure (SPEC), so the
        // problem is read before the service lines.
        if let reason = layout.warning {
            addWarningTitle(Self.warningTitle(reason))
            addLabel(Self.warningDetail(reason), font: .systemFont(ofSize: 11), secondary: true)
            addSeparator()
        }

        // Service lines: last update + interval. The next rule comes from the first limit section
        // below (or none, on a cold-start failure with no sections).
        addLabel(Self.lastUpdateText(layout.lastUpdateAge), font: .systemFont(ofSize: 11), secondary: true)
        addLabel(Self.intervalText(layout.intervalSeconds), font: .systemFont(ofSize: 11), secondary: true)

        // One section per limit row: separator + "title · status" line + "% used · resets" line + bar.
        for row in layout.rows {
            addSeparator()
            addTitleStatusLine(title: row.title, status: Self.statusText(row.indicator, row.pacing))
            addLabel(Self.detailText(row), font: .systemFont(ofSize: 11), secondary: true)
            addBar(row)
        }
    }

    /// The section's first line: the **bold** window title, then the separator and the pacing status
    /// in **normal** weight — both in `labelColor` (variant A: the status is de-emphasised by weight
    /// only, not colour). Built as one attributed string so the two weights sit on a single line.
    @discardableResult
    private func addTitleStatusLine(title: String, status: String) -> NSView {
        let attributed = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
        attributed.append(NSAttributedString(string: Self.separator + status, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
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

    /// `"Last update: 2m ago"`, or `"just now"` for anything under a full minute — the "Last update"
    /// line never shows seconds (user preference), so a sub-minute age reads as "just now", not "40s".
    static let justNowThreshold = 60
    static func lastUpdateText(_ ageSeconds: TimeInterval) -> String {
        let age = Int(ageSeconds)
        return age < justNowThreshold
            ? "Last update: just now"
            : "Last update: \(durationMinutes(age)) ago"
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

    /// `"Update interval: 3m"` — the current dynamic polling cadence.
    static func intervalText(_ intervalSeconds: TimeInterval) -> String {
        "Update interval: \(duration(Int(intervalSeconds)))"
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
