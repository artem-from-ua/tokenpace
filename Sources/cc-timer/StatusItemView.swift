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
        /// Height of one pacing bar. Kept slim so the two bars read as separate rows.
        static let barHeight: CGFloat = 5
        /// Vertical gap between the stacked 5h and 7d bars. Kept just enough to read as two rows
        /// without spreading the pair out — a tight stack sits more like a single compact widget.
        static let barGap: CGFloat = 4
        /// Horizontal padding inside the item. Kept tight (2 pt) so the item hugs its neighbours
        /// the way native status items do — the menu bar adds its own inter-item spacing on top,
        /// so a wide internal pad reads as an oversized gap to the clock/battery beside us.
        static let hPadding: CGFloat = 2
        /// Gap between the bars block and the reset-time label.
        static let labelGap: CGFloat = 5
        /// Diameter of the time-indicator dot (slightly taller than the bar so it stands proud).
        static let tickDiameter: CGFloat = 7
        /// Width of the dark ring around the time-indicator dot.
        static let tickStroke: CGFloat = 1
        /// Corner radius of each bar.
        static let barCorner: CGFloat = 1.5
        /// Point size of the ⚠️ error glyph (`exclamationmark.triangle.fill`). Tuned to read at the
        /// same weight as the idle `*` and the bars block.
        static let errorGlyphSize: CGFloat = 13
        /// Gap between the ⚠️ glyph and the (stale) bars block when both are drawn (30–60 min phase).
        static let errorGlyphGap: CGFloat = 4
    }

    // MARK: Colour mapping (exact statusline 256-colour palette → NSColor)
    //
    // Colours are the **exact xterm-256 RGB** of the codes the Claude Code statusline uses
    // (ADR-0005: dark_gray 236, bright_green 71, bright_red 167, dark_blue 23), so the menu-bar
    // bars match the terminal pacing bar one-to-one. (Code 23 is actually a dark teal, not a true
    // blue, but it is the statusline's "future" colour, so we mirror it.) Fixed RGB rather than
    // system semantic colours: the statusline look is the same in any appearance, and the image is
    // non-template so macOS does not retint it.

    private enum Palette {
        /// Used zone — statusline `dark_gray` 236 = #303030.
        static let used = NSColor(srgbRed: 48/255, green: 48/255, blue: 48/255, alpha: 1)
        /// Pacing gap when on pace or behind — statusline `bright_green` 71 = #5faf5f (good).
        static let gapGreen = NSColor(srgbRed: 95/255, green: 175/255, blue: 95/255, alpha: 1)
        /// Pacing gap when ahead of pace — statusline `bright_red` 167 = #d75f5f (bad).
        static let gapRed = NSColor(srgbRed: 215/255, green: 95/255, blue: 95/255, alpha: 1)
        /// Future / unused zone — statusline `dark_blue` 23 = #005f5f (a dark teal), darkened ~20%
        /// (#004c4c) so it recedes more as background behind the used/pacing zones.
        static let future = NSColor(srgbRed: 0/255, green: 76/255, blue: 76/255, alpha: 1)
        /// Dark ring around the time-indicator dot so it stays distinct over any coloured zone.
        static let indicatorStroke = NSColor(srgbRed: 24/255, green: 24/255, blue: 24/255, alpha: 1)
        /// Idle glyph + reset label — follow the menu-bar foreground.
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
        case let .error(fiveHour, sevenDay, reset, _):
            drawError(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, in: rect)
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
    ///
    /// Because the image is non-template, macOS does **not** re-tint it for the menu-bar theme, so
    /// the semantic foreground colour (`labelColor` for the idle glyph / reset label) must be
    /// resolved against the **menu bar's** appearance — not the ambient appearance an off-screen
    /// `NSImage` draws in (which defaults to Aqua → dark text on a dark menu bar). The caller passes
    /// `item.button?.effectiveAppearance` and re-snapshots when the theme changes.
    ///
    /// - Parameter appearance: Appearance to resolve dynamic colours in; the view's own when `nil`.
    func snapshotImage(appearance: NSAppearance? = nil) -> NSImage {
        let size = intrinsicContentSize
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)        // draw eagerly now (no lazy handler)
        (appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            render(in: NSRect(origin: .zero, size: size))
        }
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
        drawBars(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, originX: rect.minX + Metrics.hPadding, in: rect)
    }

    /// Draw the stacked 5h/7d bars + reset label, with the bars block starting at `originX`.
    /// Shared by ``drawExpanded(fiveHour:sevenDay:reset:in:)`` and the bars-beside-⚠️ error phase so
    /// the geometry is identical; only the left origin differs (the error glyph shifts it right).
    private func drawBars(fiveHour: BarView, sevenDay: BarView, reset: TimeToReset, originX: CGFloat, in rect: NSRect) {
        // Two bars stacked, vertically centred as a block.
        let blockHeight = Metrics.barHeight * 2 + Metrics.barGap
        let topY = rect.minY + (rect.height - blockHeight) / 2
        let barsRect = NSRect(x: originX, y: topY, width: Metrics.barWidth, height: blockHeight)

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

    // MARK: Error (issue #12)

    /// Draw the error state: the ⚠️ glyph at the left, and — during the 30–60 min stale phase —
    /// the last known bars + reset beside it (all bars `nil` past 60 min / cold start → glyph alone).
    private func drawError(fiveHour: BarView?, sevenDay: BarView?, reset: TimeToReset?, in rect: NSRect) {
        let glyphRight = drawErrorGlyph(in: rect)
        if let fiveHour, let sevenDay, let reset {
            drawBars(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset,
                     originX: glyphRight + Metrics.errorGlyphGap, in: rect)
        }
    }

    /// Draw the ⚠️ glyph (`exclamationmark.triangle`) at the left of `rect`, in the **foreground
    /// (label) colour** so it matches the menu-bar text, and return its right edge x so the caller
    /// can place stale bars beside it. The non-`.fill` outline keeps the exclamation mark legible
    /// even as a single-colour fill. Centred on `rect.midY` (the bars block's vertical centre) and
    /// drawn with `respectFlipped: true` — this view is `isFlipped`, so a plain `draw(in:)` mirrors
    /// the image vertically (the triangle came out upside-down / crooked); the flag fixes that.
    @discardableResult
    private func drawErrorGlyph(in rect: NSRect) -> CGFloat {
        let originX = rect.minX + Metrics.hPadding
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.errorGlyphSize, weight: .semibold)
            .applying(.init(paletteColors: [Palette.foreground]))
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "error")?
            .withSymbolConfiguration(config) else {
            return originX
        }
        let size = symbol.size
        let drawRect = NSRect(
            x: originX,
            y: rect.midY - size.height / 2,
            width: size.width, height: size.height
        )
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        return originX + ceil(size.width)
    }

    /// Draw one pacing bar: used (grey) → gap (green/red) → future (teal), plus the time-indicator
    /// dot. Geometry comes straight from `BarView.layout` — fractions are just multiplied by width.
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

        // Time-indicator dot at timeFraction (drawn on top, unclipped so it stands proud).
        // Colour tracks the pacing relationship: green when behind, red when ahead, teal on a tie.
        // A dark stroke rings the dot so it separates cleanly when it sits over a coloured zone.
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

    /// Colour of the time-indicator dot from the usage-vs-time relationship:
    /// - `usage < time` → behind pace (good) → green
    /// - `usage > time` → ahead of pace (bad) → red
    /// - `usage == time` → exactly on the line → teal (the future colour)
    ///
    /// This is a finer split than `PacingState` (whose `.onPaceOrBehind` folds the tie into green),
    /// so the dot is computed from the raw fractions here rather than reusing `bar.layout.pacing`.
    private func indicatorColor(usage: Double, time: Double) -> NSColor {
        if usage > time { return Palette.gapRed }
        if usage < time { return Palette.gapGreen }
        return Palette.future
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

    /// The item width for a given layout — narrow for idle/glyph-only, wider for the bars + label,
    /// widest for the ⚠️ + stale-bars phase (the glyph adds its own width). Driven dynamically so the
    /// item hugs exactly the content currently drawn.
    private func itemWidth(for layout: MenuBarLayout?) -> CGFloat {
        switch layout?.mode {
        case .none, .idle:
            return Metrics.height                       // square-ish compact item
        case let .expanded(_, _, reset, _):
            return Metrics.hPadding + barsBlockWidth(reset: reset) + Metrics.hPadding
        case let .error(five, _, reset, _):
            // ⚠️ alone (cold start / >60 min) → compact; ⚠️ + stale bars (30–60 min) → glyph + bars.
            guard five != nil, let reset else { return Metrics.height }
            return Metrics.hPadding + errorGlyphWidth() + Metrics.errorGlyphGap
                + barsBlockWidth(reset: reset) + Metrics.hPadding
        }
    }

    /// Width of the bars block + its reset label (no outer padding) — shared by the expanded and
    /// error-with-bars widths so they stay in sync with ``drawBars(fiveHour:sevenDay:reset:originX:in:)``.
    private func barsBlockWidth(reset: TimeToReset) -> CGFloat {
        let labelWidth = (resetText(reset) as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ]).width
        return Metrics.barWidth + Metrics.labelGap + ceil(labelWidth)
    }

    /// Rendered width of the ⚠️ glyph at ``Metrics/errorGlyphSize`` — measured the same way it is
    /// drawn (the configured symbol image) so the item width matches exactly. Falls back to the
    /// glyph point size if the symbol is unavailable, so the item never collapses to zero.
    private func errorGlyphWidth() -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.errorGlyphSize, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return ceil(symbol?.size.width ?? Metrics.errorGlyphSize)
    }
}
