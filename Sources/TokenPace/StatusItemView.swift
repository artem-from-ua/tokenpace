import AppKit
import TokenPaceKit

/// The menu-bar item's custom view — the thin AppKit shell of issue #10.
///
/// It owns **no** business logic: it switches on a ``MenuBarLayout`` (computed in `TokenPaceKit`)
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
        /// Diameter of the leftmost service-status dot (issue #31), drawn only when a service is
        /// non-operational. Small — a glance signal, not a primary element.
        static let statusDotDiameter: CGFloat = 6
        /// Gap between the service-status dot and the content to its right (bars / glyph).
        static let statusDotGap: CGFloat = 4
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
        /// Pacing gap / dot when on pace or behind — statusline `bright_green` 71 = #5faf5f (good). The
        /// ahead-of-pace colours are NOT here: they come from `PopupBarView.aheadColor` (graded amber →
        /// orange → red), shared with the popup so both bars agree.
        static let gapGreen = NSColor(srgbRed: 95/255, green: 175/255, blue: 95/255, alpha: 1)
        /// Time-indicator dot when on pace — the gap green lightened ~30 % (white-mixed) so the dot
        /// reads brighter than the pacing gap it sits over.
        static let dotGreen = NSColor(srgbRed: 143/255, green: 199/255, blue: 143/255, alpha: 1)
        /// Dark ring around the time-indicator dot so it stays distinct over any coloured zone.
        static let indicatorStroke = NSColor(srgbRed: 24/255, green: 24/255, blue: 24/255, alpha: 1)
        /// The **idle** 5-hour bar's solid fill (#100, ADR-0027) — the 5h window has no active session,
        /// so the bar is a knobless solid track meaning "ready to start, full quota available", not a
        /// pacing state. Same 70/140/230 sRGB as the ``statusBlue`` service dot: mid-brightness, in tone
        /// with the palette (`gapGreen` #5faf5f), distinct from the pacing greens/ambers, and already
        /// tuned to read at small size on both light and dark menu bars. Fixed sRGB (not `systemBlue`)
        /// because the menu-bar image is non-template and drawn in a resolved appearance.
        static let idleBlue = NSColor(srgbRed: 70/255, green: 140/255, blue: 230/255, alpha: 1)
        /// Idle glyph + reset label — follow the menu-bar foreground.
        static let foreground = NSColor.labelColor

        // Service-status dot (issue #31). Fixed sRGB (not the dynamic `system*` colours) because the
        // status image is non-template and drawn in a resolved appearance, so a fixed, vivid value
        // reads consistently on both light and dark menu bars. Tuned to be saturated enough to pop at
        // 6 pt. `operational` is never drawn (the dot appears only for a problem), so it is omitted.
        static let statusYellow = NSColor(srgbRed: 240/255, green: 190/255, blue: 50/255, alpha: 1)
        static let statusOrange = NSColor(srgbRed: 240/255, green: 140/255, blue: 40/255, alpha: 1)
        static let statusRed    = NSColor(srgbRed: 225/255, green: 70/255, blue: 70/255, alpha: 1)
        static let statusBlue   = NSColor(srgbRed: 70/255, green: 140/255, blue: 230/255, alpha: 1)
        static let statusGray   = NSColor(srgbRed: 150/255, green: 150/255, blue: 150/255, alpha: 1)
    }

    /// The dot colour for a non-operational service state. `operational` should never reach here
    /// (the dot is drawn only for a problem) but maps to gray defensively.
    private func statusDotColor(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .degraded:         return Palette.statusYellow
        case .partialOutage:    return Palette.statusOrange
        case .majorOutage:      return Palette.statusRed
        case .underMaintenance: return Palette.statusBlue
        case .unknown:          return Palette.statusGray
        case .operational:      return Palette.statusGray
        }
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
        guard let layout else { return }

        // Rightmost service-status dot (issue #31): drawn at the trailing edge, then everything else
        // is rendered in a content rect inset from the right by the dot + gap, so the bars/glyph keep
        // their leading position. When there is no problem, the inset is zero and the layout is
        // exactly as before.
        var contentRect = rect
        if let problem = layout.serviceProblem {
            drawStatusDot(problem, in: rect)
            let inset = Metrics.statusDotDiameter + Metrics.statusDotGap
            contentRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width - inset, height: rect.height)
        }

        switch layout.mode {
        case let .expanded(fiveHour, sevenDay, reset, _):
            drawExpanded(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, in: contentRect)
        case let .error(fiveHour, sevenDay, reset, _):
            drawError(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, in: contentRect)
        }
    }

    /// Draw the small service-status dot at the **right edge** of `rect`, vertically centred — the
    /// trailing element of the widget. `hPadding` keeps it off the very edge, matching the bars'
    /// inset. Drawn only when a service is non-operational (issue #31).
    private func drawStatusDot(_ status: ServiceStatus, in rect: NSRect) {
        let d = Metrics.statusDotDiameter
        let x = rect.maxX - Metrics.hPadding - d
        let y = rect.midY - d / 2
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d))
        statusDotColor(status).setFill()
        dot.fill()
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

    /// Draw one pacing bar: monochrome grey base → gap (green/red), plus the time-indicator dot.
    /// Geometry comes straight from `BarView.layout` — fractions are just multiplied by width. The two
    /// base zones (used + future/unused) share the solid ``PopupBarView/monochromeGrey`` with the popup,
    /// so the menu-bar bars read identically; only the pacing gap and dot carry colour.
    private func drawBar(_ bar: BarView, in rect: NSRect) {
        // Idle 5h bar (#100, ADR-0027): a solid blue track, no pacing zones, no time-indicator dot —
        // "no active session, full quota available". The bar's `layout`/`indicator` are inert here.
        if bar.idle {
            let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
            Palette.idleBlue.setFill()
            path.fill()
            return
        }

        let l = bar.layout
        let w = rect.width

        // Whole-bar rounded background = the monochrome base (drawn first, others paint over it).
        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
        PopupBarView.monochromeGrey.setFill()
        path.fill()

        // Clip subsequent zone fills to the rounded shape so corners stay clean.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        // Used zone: [0, usageFraction).
        fillZone(from: 0, to: l.usageFraction, in: rect, width: w, color: PopupBarView.monochromeGrey)

        // Pacing gap: [gapStart, gapEnd). Ahead-of-pace uses the SAME graded colour as the popup
        // (`PopupBarView.aheadColor`: amber → orange → red by how far ahead), so the menu-bar bar and
        // the popup row agree — e.g. a yellow 7-day here reads yellow in the dropdown too. On pace →
        // the statusline green (ADR-0005), kept fixed to match the terminal pacing bar.
        let gapColor = l.pacing == .ahead
            ? PopupBarView.aheadColor(usage: l.usageFraction, time: l.timeFraction)
            : Palette.gapGreen
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
    /// - `usage > time` → ahead of pace (bad) → the graded ahead colour (amber → orange → red)
    /// - `usage == time` → exactly on the line → green (a tie is still on pace, not behind)
    ///
    /// This is a finer split than `PacingState` (whose `.onPaceOrBehind` folds the tie into green), so
    /// the dot is computed from the raw fractions here. The ahead colour matches the popup exactly
    /// (`PopupBarView.aheadColor`), so the dot and its gap read as the same colour across both bars.
    private func indicatorColor(usage: Double, time: Double) -> NSColor {
        usage > time ? PopupBarView.aheadColor(usage: usage, time: time) : Palette.dotGreen
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

    /// The item width for a given layout — narrow for the glyph-only error/cold-start case, wider for
    /// the bars + label, widest for the ⚠️ + stale-bars phase (the glyph adds its own width). Driven
    /// dynamically so the item hugs exactly the content currently drawn.
    private func itemWidth(for layout: MenuBarLayout?) -> CGFloat {
        // The trailing service dot, when present, widens every mode by the same dot + gap inset.
        let dotInset = layout?.serviceProblem != nil ? Metrics.statusDotDiameter + Metrics.statusDotGap : 0
        switch layout?.mode {
        case .none:
            return Metrics.height + dotInset            // square-ish compact item (no layout yet)
        case let .expanded(_, _, reset, _):
            return dotInset + Metrics.hPadding + barsBlockWidth(reset: reset) + Metrics.hPadding
        case let .error(five, _, reset, _):
            // ⚠️ alone (cold start / >60 min) → compact; ⚠️ + stale bars (30–60 min) → glyph + bars.
            guard five != nil, let reset else { return Metrics.height + dotInset }
            return dotInset + Metrics.hPadding + errorGlyphWidth() + Metrics.errorGlyphGap
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
