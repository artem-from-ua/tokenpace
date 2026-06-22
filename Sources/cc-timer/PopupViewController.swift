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

    private enum Metrics {
        static let height: CGFloat = 6
        static let corner: CGFloat = 2
        static let tickDiameter: CGFloat = 8
        static let tickStroke: CGFloat = 1
    }

    // Statusline 256-colour palette (ADR-0005), appearance-aware in the popup: on a dark theme the
    // bars keep the exact menu-bar colours; on a light theme the dark zones (used grey, future
    // teal) and the indicator ring are lightened so they read on a light panel. The pacing gap
    // (green/red) is the limit signal and stays identical in both themes.
    //
    // NSColor(name:dynamicProvider:) resolves per-appearance and AppKit re-draws on theme change
    // automatically (PopupBarView draws in its real appearance — no manual observation needed).
    private enum Palette {
        static let gapGreen = NSColor(srgbRed: 95/255, green: 175/255, blue: 95/255, alpha: 1)
        static let gapRed = NSColor(srgbRed: 215/255, green: 95/255, blue: 95/255, alpha: 1)

        /// Used zone: dark grey on dark, much lighter grey on light.
        static let used = dynamic(dark: gray(48), light: gray(130))
        /// Future / unused zone: dark teal on dark, lighter teal on light.
        static let future = dynamic(
            dark: NSColor(srgbRed: 0/255, green: 76/255, blue: 76/255, alpha: 1),
            light: NSColor(srgbRed: 55/255, green: 110/255, blue: 110/255, alpha: 1)
        )
        /// Indicator-dot ring: near-black on dark, mid grey on light.
        static let indicatorStroke = NSColor.windowBackgroundColor

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
        let rect = bounds
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

        // Time-indicator dot at timeFraction, coloured by the raw usage-vs-time relationship.
        let cx = rect.minX + CGFloat(l.timeFraction) * w
        let cy = rect.midY
        let d = Metrics.tickDiameter
        let dot = NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        indicatorColor(usage: l.usageFraction, time: l.timeFraction).setFill()
        dot.fill()
        Palette.indicatorStroke.setStroke()
        dot.lineWidth = Metrics.tickStroke
        dot.stroke()
    }

    private func indicatorColor(usage: Double, time: Double) -> NSColor {
        if usage > time { return Palette.gapRed }
        if usage < time { return Palette.gapGreen }
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

        // Header block.
        addLabel(Self.appTitle, font: .boldSystemFont(ofSize: 13))
        addLabel(Self.lastUpdateText(layout.lastUpdateAge), font: .systemFont(ofSize: 11), secondary: true)
        addLabel(Self.intervalText(layout.intervalSeconds), font: .systemFont(ofSize: 11), secondary: true)

        // One section per limit row: separator + bold heading + detail + bar.
        for row in layout.rows {
            addSeparator()
            addLabel(row.title, font: .boldSystemFont(ofSize: 12))
            addLabel(Self.detailText(row), font: .systemFont(ofSize: 11), secondary: true)
            addBar(row.bar)
        }
    }

    private func addLabel(_ text: String, font: NSFont, secondary: Bool = false) {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        stack.addArrangedSubview(label)
    }

    private func addBar(_ bar: BarLayout) {
        let view = PopupBarView()
        view.bar = bar
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Metrics.barWidth).isActive = true
        view.heightAnchor.constraint(equalToConstant: 6).isActive = true
        stack.addArrangedSubview(view)
        stack.setCustomSpacing(Metrics.sectionSpacing, after: view)
    }

    private func addSeparator() {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.hPadding).isActive = true
        stack.addArrangedSubview(box)
        stack.setCustomSpacing(Metrics.sectionSpacing, after: box)
    }

    // MARK: - Pure text formatters (the localisation seam)

    /// `"50% used · on pace · resets in 20m @ 10:30"` — the per-limit detail line. The "@ hh:mm"
    /// is appended only when the model carries an absolute time (reset < 24 h away). A reset that
    /// is now/past (no relative string) reads as "resetting…".
    static func detailText(_ row: LimitRow) -> String {
        var parts = ["\(percent(row.utilization)) used", statusText(row.indicator, row.pacing)]
        if let rel = row.resetRelative {
            var reset = "resets in \(rel)"
            if let abs = row.resetAbsolute { reset += " @ \(abs)" }
            parts.append(reset)
        } else {
            parts.append("resetting…")
        }
        return parts.joined(separator: " · ")
    }

    /// `"Last update: 2m ago"` (or `"just now"` for a fresh poll).
    static func lastUpdateText(_ ageSeconds: TimeInterval) -> String {
        let age = Int(ageSeconds)
        return age < 1 ? "Last update: just now" : "Last update: \(duration(age)) ago"
    }

    /// `"Update interval: 3m"` — the current dynamic polling cadence.
    static func intervalText(_ intervalSeconds: TimeInterval) -> String {
        "Update interval: \(duration(Int(intervalSeconds)))"
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
