import AppKit
import CCTimerKit

/// The menu-bar item's custom view — the thin AppKit shell of issue #10.
///
/// It owns **no** business logic: it switches on a ``MenuBarLayout`` (computed in `CCTimerKit`)
/// and draws it. A `non-template` `NSView` is used deliberately (not a template image or plain
/// text) so macOS does not recolour the pacing bars under Dark/Light tinting — we control the
/// colours ourselves (SPEC "Технічні зауваги", ADR-0009).
///
/// ## Redraw discipline
/// Assigning ``layout`` marks the view dirty (`needsDisplay`); nothing else triggers a redraw, so
/// the item repaints **only when the data changes** — never on a timer (architecture.md: energy
/// efficiency). The polling layer (#13) will set ``layout`` after each successful poll; for now
/// `AppDelegate` sets it once from a mock snapshot.
final class StatusItemView: NSView {

    // MARK: Layout input

    /// The current widget model. Setting it (to a new value) requests a redraw and resizes the
    /// item to fit (`invalidateIntrinsicContentSize`). Drawing is a no-op while `nil`.
    var layout: MenuBarLayout? {
        didSet {
            guard layout != oldValue else { return }   // skip redundant repaints
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    // MARK: Geometry constants

    private enum Metrics {
        /// Item height — the standard menu-bar content height.
        static let height: CGFloat = 22
        /// Width of one pacing bar.
        static let barWidth: CGFloat = 34
        /// Height of one pacing bar.
        static let barHeight: CGFloat = 7
        /// Vertical gap between the stacked 5h and 7d bars.
        static let barGap: CGFloat = 2
        /// Horizontal padding inside the item.
        static let hPadding: CGFloat = 5
        /// Gap between the bars block and the reset-time label.
        static let labelGap: CGFloat = 5
        /// Width of the time-indicator tick.
        static let tickWidth: CGFloat = 1.5
        /// Corner radius of each bar.
        static let barCorner: CGFloat = 1.5
    }

    // MARK: Colour mapping (statusline 256-colour → semantic NSColor)
    //
    // ADR-0005 records the statusline reference codes (dark_gray 236, bright_green 71,
    // bright_red 167, dark_blue 23). We resolve them to **system semantic colours** where one
    // exists, because those already adapt to Dark/Light and accessibility — the raw RGB is only
    // an orientation. The two zones without a clean semantic match (used / future) use explicit,
    // theme-stable colours.

    private enum Palette {
        /// Used zone (`dark_gray` 236). A mid grey that stays legible on both the Dark and Light
        /// menu bar; `quaternaryLabelColor` is too faint at this size, so an explicit grey is used.
        static let used = NSColor(white: 0.55, alpha: 1)
        /// Pacing gap when on pace or behind (`bright_green` 71) — good.
        static let gapGreen = NSColor.systemGreen
        /// Pacing gap when ahead of pace (`bright_red` 167) — bad.
        static let gapRed = NSColor.systemRed
        /// Future / unused zone (`dark_blue` 23) — muted so it reads as background, not data.
        static let future = NSColor.systemBlue.withAlphaComponent(0.55)
        /// Time-indicator tick + idle glyph + reset label — follow the menu-bar foreground.
        static let foreground = NSColor.labelColor
    }

    // MARK: NSView overrides

    /// Top-left origin makes the bar maths read naturally (y grows downward).
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: itemWidth(for: layout), height: Metrics.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        render(in: bounds)
    }

    /// Render the current layout into `rect` (the view's own bounds, or an `NSImage` canvas).
    /// Shared by ``draw(_:)`` and ``snapshotImage()`` so the menu-bar image and a hosted view
    /// draw identically.
    private func render(in rect: NSRect) {
        guard let mode = layout?.mode else { return }
        switch mode {
        case .idle:
            drawIdleGlyph(in: rect)
        case let .expanded(fiveHour, sevenDay, reset, _):
            drawExpanded(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, in: rect)
        }
    }

    // MARK: NSImage snapshot

    /// Render the current layout to a **non-template** `NSImage` for use as the status item's
    /// `button.image`.
    ///
    /// Hosting the custom `NSView` as a button subview is unreliable (the system button owns its
    /// layout and paints over added subviews), so the robust path for fully custom menu-bar
    /// graphics is to hand the button a ready image. `isTemplate = false` stops macOS recolouring
    /// the pacing colours under Dark/Light tinting (SPEC "Технічні зауваги", ADR-0009).
    func snapshotImage() -> NSImage {
        let size = intrinsicContentSize
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)        // draw eagerly now (no lazy handler)
        render(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: Idle

    /// Compact idle form: a bold `*` centred in the item (SPEC "мала іконка"; the chosen glyph).
    private func drawIdleGlyph(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
            .foregroundColor: Palette.foreground,
        ]
        let glyph = NSAttributedString(string: "*", attributes: attrs)
        let size = glyph.size()
        let origin = NSPoint(
            x: rect.minX + (rect.width - size.width) / 2,
            y: rect.minY + (rect.height - size.height) / 2
        )
        glyph.draw(at: origin)
    }

    // MARK: Expanded

    private func drawExpanded(fiveHour: BarView, sevenDay: BarView, reset: TimeToReset, in rect: NSRect) {
        // Two bars stacked, vertically centred as a block.
        let blockHeight = Metrics.barHeight * 2 + Metrics.barGap
        let topY = rect.minY + (rect.height - blockHeight) / 2
        let barsRect = NSRect(x: rect.minX + Metrics.hPadding, y: topY, width: Metrics.barWidth, height: blockHeight)

        drawBar(fiveHour, in: NSRect(
            x: barsRect.minX, y: barsRect.minY,
            width: Metrics.barWidth, height: Metrics.barHeight
        ))
        drawBar(sevenDay, in: NSRect(
            x: barsRect.minX, y: barsRect.minY + Metrics.barHeight + Metrics.barGap,
            width: Metrics.barWidth, height: Metrics.barHeight
        ))

        drawResetLabel(reset, leftOf: barsRect.maxX + Metrics.labelGap, in: rect)
    }

    /// Draw one pacing bar: used (grey) → gap (green/red) → future (blue), plus the time tick.
    /// Geometry comes straight from `BarView.layout` — fractions are just multiplied by the width.
    private func drawBar(_ bar: BarView, in rect: NSRect) {
        let l = bar.layout
        let w = rect.width

        // Whole-bar rounded background = future zone (drawn first, others paint over it).
        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
        Palette.future.setFill()
        path.fill()

        // Clip subsequent zone fills to the rounded shape so corners stay clean.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        // Used zone: [0, usageFraction).
        fillZone(from: 0, to: l.usageFraction, in: rect, width: w, color: Palette.used)

        // Pacing gap: [gapStart, gapEnd), coloured by pacing direction.
        let gapColor = l.pacing == .ahead ? Palette.gapRed : Palette.gapGreen
        fillZone(from: l.gapStart, to: l.gapEnd, in: rect, width: w, color: gapColor)

        NSGraphicsContext.restoreGraphicsState()

        // Time-indicator tick at timeFraction (drawn on top, unclipped so it's crisp).
        let tickX = rect.minX + CGFloat(l.timeFraction) * w - Metrics.tickWidth / 2
        let tickRect = NSRect(x: tickX, y: rect.minY, width: Metrics.tickWidth, height: rect.height)
        Palette.foreground.setFill()
        tickRect.fill()
    }

    /// Fill the sub-rect spanning the fraction range `[from, to)` of a bar.
    private func fillZone(from: Double, to: Double, in rect: NSRect, width: CGFloat, color: NSColor) {
        let x0 = rect.minX + CGFloat(from) * width
        let x1 = rect.minX + CGFloat(to) * width
        guard x1 > x0 else { return }
        color.setFill()
        NSRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height).fill()
    }

    /// Draw the reset countdown text to the right of the bars.
    private func drawResetLabel(_ reset: TimeToReset, leftOf x: CGFloat, in rect: NSRect) {
        let text = resetText(reset)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Palette.foreground,
        ]
        let label = NSAttributedString(string: text, attributes: attrs)
        let size = label.size()
        label.draw(at: NSPoint(x: x, y: rect.minY + (rect.height - size.height) / 2))
    }

    // MARK: Helpers

    /// Map the reset countdown to its display string. `.resetNow` becomes the ⏰ glyph (the stale
    /// signal), matching `TimeToReset`'s documented contract.
    private func resetText(_ reset: TimeToReset) -> String {
        switch reset {
        case let .absolute(s): return s
        case let .relative(s): return s
        case .resetNow:        return "⏰"
        }
    }

    /// The item width for a given layout — narrow for idle, wider for the bars + label.
    private func itemWidth(for layout: MenuBarLayout?) -> CGFloat {
        switch layout?.mode {
        case .none, .idle:
            return Metrics.height                       // square-ish compact item
        case let .expanded(_, _, reset, _):
            let labelWidth = (resetText(reset) as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            ]).width
            return Metrics.hPadding + Metrics.barWidth + Metrics.labelGap
                + ceil(labelWidth) + Metrics.hPadding
        }
    }
}
