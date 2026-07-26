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

    /// "Calm colours" (#105): when `true`, the widget's **soft** signals are drawn white — the idle
    /// blue track, the on-pace green gap, the mild ahead-of-pace yellow, and the **degraded (yellow)
    /// service dot**; the strong warnings (orange/red), the time-indicator marker, the stronger
    /// service states (orange/red/blue/grey), and the ⚠️ glyph keep their colour. Set by `AppDelegate`
    /// from `PersistedConfig.calmMenuBarColors`; the view stays a thin shell and does not read the
    /// config itself. Changing it requests a redraw (no size change).
    var calmColors: Bool = false {
        didSet {
            guard calmColors != oldValue else { return }
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
        /// Width of the time-indicator marker — a slim vertical bar (#…), narrower than the diameter
        /// of the old dot so it reads as a crisp position tick rather than a blob.
        static let tickWidth: CGFloat = 3.5
        /// Height of the time-indicator marker — taller than the bar so it stands proud above and
        /// below the pacing zone.
        static let tickHeight: CGFloat = 9
        /// Corner radius of the time-indicator marker (lightly rounded, matching the bar corners).
        static let tickCorner: CGFloat = 1.5
        /// Width of the dark ring around the time-indicator marker.
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
        /// Point size of the trailing money-credits currency glyph (`coloncurrencysign` ¤, #144).
        /// Tuned to read at the same visual weight as the bars block and the ⚠️ glyph — a touch
        /// larger than the bars are tall so the generic-currency mark stays legible at menu-bar size.
        static let creditsIconSize: CGFloat = 12
        /// Gap between the money-credits icon and the content to its **left** (bars / glyph). The icon
        /// sits between the bars block and the service dot, so this is its leading separation.
        static let creditsIconGap: CGFloat = 4
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
        /// pacing state. A **muted, slightly darker** blue (85/130/180): the R/G channels are pulled up
        /// toward B to drop the saturation (~53 %, softer than the vivid ~70 % `statusBlue` service dot),
        /// and the overall brightness is lowered a notch so the track reads a touch deeper — still
        /// clearly blue, in tone with the palette (`gapGreen` #5faf5f), distinct from the pacing
        /// greens/ambers, on both light and dark menu bars. Fixed sRGB (not `systemBlue`) because the
        /// menu-bar image is non-template, drawn in a resolved appearance.
        static let idleBlue = NSColor(srgbRed: 85/255, green: 130/255, blue: 180/255, alpha: 1)
        /// Idle glyph + reset label — follow the menu-bar foreground.
        static let foreground = NSColor.labelColor

        /// The "calm colours" replacement (#105): the soft pacing colours (idle blue, on-pace green,
        /// mild-ahead yellow) collapse to this when the user opts into a quieter menu bar. Fixed sRGB
        /// white (not `labelColor`): the bars are deliberately monochrome-neutral here, and — like the
        /// other pacing colours — the image is non-template, so a resolved value is drawn as-is on both
        /// light and dark menu bars.
        static let calmWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

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
    ///
    /// Calm colours (#105): `.degraded` is the **soft** service signal — the yellow counterpart of
    /// the mild ahead-of-pace yellow — so it mutes to white alongside the pacing colours. The strong
    /// states (partial/major outage → orange/red) and the neutral ones (maintenance blue, unknown
    /// grey) keep their colour, matching how the pacing gap keeps orange/red under calm.
    private func statusDotColor(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .degraded:         return calmColors ? Palette.calmWhite : Palette.statusYellow
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

        // Trailing decorations, drawn right-to-left so each reclaims width from the right edge and the
        // bars/glyph keep their leading position:
        //  1. the service-status dot (#31) is the **rightmost** element (its long-established slot);
        //  2. the money-credits icon (#144) sits just **left of the dot**, between it and the bars —
        //     the two can appear together (they are independent signals). When either is absent its
        //     inset is zero and the layout is exactly as before that feature.
        var contentRect = rect
        if let problem = layout.serviceProblem {
            drawStatusDot(problem, in: contentRect)
            let inset = Metrics.statusDotDiameter + Metrics.statusDotGap
            contentRect = NSRect(x: contentRect.minX, y: contentRect.minY,
                                 width: contentRect.width - inset, height: contentRect.height)
        }
        if let credits = layout.credits {
            drawCreditsIcon(credits, in: contentRect)
            let inset = creditsIconWidth(for: credits.currency) + Metrics.creditsIconGap
            contentRect = NSRect(x: contentRect.minX, y: contentRect.minY,
                                 width: contentRect.width - inset, height: contentRect.height)
        }

        switch layout.mode {
        case let .expanded(fiveHour, sevenDay, resetToShow):
            drawExpanded(fiveHour: fiveHour, sevenDay: sevenDay, reset: resetToShow?.display, in: contentRect)
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

    // MARK: Money-credits icon (issue #144)

    /// Draw the money-credits currency glyph at the **right edge** of `rect`, vertically centred — the
    /// trailing element just left of the service dot (whose width the caller has already reserved by
    /// passing an inset `rect`). `hPadding` keeps it off the very edge, like the bars.
    ///
    /// The glyph is **currency-specific** (``creditsSymbolName(for:)``): a known currency draws its own
    /// SF Symbol (`eurosign`/`dollarsign`/…), an unknown/empty code falls back to the generic
    /// `coloncurrencysign` (¤) — never a hard-coded `$` (the currency is dynamic; EUR observed, #142).
    /// Rendered as a **non-template palette image** in the marker's pacing colour (``creditsIconColor(_:)``),
    /// matching the rest of the widget (non-template so macOS does not retint it). Drawn with
    /// `respectFlipped: true` because this view is `isFlipped` (same as the ⚠️ glyph).
    private func drawCreditsIcon(_ credits: CreditsMarker, in rect: NSRect) {
        let color = creditsIconColor(credits)
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.creditsIconSize, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(
            systemSymbolName: Self.creditsSymbolName(for: credits.currency),
            accessibilityDescription: "usage credits")?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let x = rect.maxX - Metrics.hPadding - size.width
        let drawRect = NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }

    /// The SF Symbol name for a currency's menu-bar glyph: a known ISO code maps to its own currency
    /// symbol, anything else (unknown code, empty) to the generic `coloncurrencysign` (¤). The set
    /// mirrors ``PopupViewController``'s known-symbol table so the menu bar and dropdown agree on which
    /// currencies are "known". SF Symbols ships a `…sign` glyph for each of these.
    static func creditsSymbolName(for currency: String) -> String {
        switch currency.uppercased() {
        case "EUR": return "eurosign"
        case "USD": return "dollarsign"
        case "GBP": return "sterlingsign"
        case "JPY", "CNY": return "yensign"   // ¥ symbol is shared by JPY and CNY
        case "INR": return "indianrupeesign"
        default:    return "coloncurrencysign"
        }
    }

    /// The colour of the money-credits icon, from its ``CreditsMarker/bar`` via the **same** mapping
    /// the pacing bars use — so a yellow credits icon and a yellow 7-day bar read as the same amber:
    /// - `bar == nil` (unlimited monthly limit) → the neutral menu-bar foreground: the icon shows the
    ///   credits are active but carries no pacing tint.
    /// - on pace / behind (`usage <= time`) → the on-pace green (`dotGreen`, the brighter knob green,
    ///   so a single glyph reads as clearly green rather than the darker gap fill).
    /// - ahead of pace → the graded ahead colour (`PopupBarView.aheadColor`: amber → orange → red at
    ///   the cap), identical to the bars' gap/knob.
    ///
    /// Calm mode (#105): the icon follows the bars — it mutes to white in exactly the **calm** states
    /// (on pace / behind, mild-ahead yellow, and the neutral unlimited icon), and keeps its colour for
    /// the strong warnings (orange/red). `CreditsMarker.isCalm` is the one predicate that decides this,
    /// so the icon and the bars always agree.
    private func creditsIconColor(_ credits: CreditsMarker) -> NSColor {
        if calmColors && credits.isCalm { return Palette.calmWhite }
        guard let l = credits.bar else { return Palette.foreground }   // unlimited → neutral
        return l.timeFraction < l.usageFraction
            ? PopupBarView.aheadColor(usage: l.usageFraction, time: l.timeFraction)
            : Palette.dotGreen
    }

    /// Rendered width of the money-credits glyph at ``Metrics/creditsIconSize`` — measured the same way
    /// it is drawn (the configured symbol image) so the reserved width matches exactly. Falls back to
    /// the icon point size if the symbol is unavailable, so the item never collapses. The palette
    /// colour does not affect the metrics, so a plain configuration is enough here.
    private func creditsIconWidth(for currency: String) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.creditsIconSize, weight: .semibold)
        let symbol = NSImage(systemSymbolName: Self.creditsSymbolName(for: currency), accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return ceil(symbol?.size.width ?? Metrics.creditsIconSize)
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

    private func drawExpanded(fiveHour: BarView, sevenDay: BarView?, reset: TimeToReset?, in rect: NSRect) {
        drawBars(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset,
                 originX: rect.minX + Metrics.hPadding, in: rect)
    }

    /// Draw the pacing bars starting at `originX`; the reset label is drawn to their right only when
    /// `reset != nil`. Two layouts by whether the 7-day bar is present:
    /// - **`sevenDay != nil`**: 5h on top, 7d below, the pair vertically centred as one block.
    /// - **`sevenDay == nil`** (the calm 7-day was hidden, #94): the 5h bar **alone**, vertically
    ///   centred on the item — so a single bar sits mid-height, not clinging to the top row.
    ///
    /// Shared by ``drawExpanded(fiveHour:sevenDay:reset:in:)`` and the bars-beside-⚠️ error phase so
    /// the geometry is identical; only the left origin differs (the error glyph shifts it right). The
    /// error phase always passes a non-nil `sevenDay` (the 7-day bar is diagnostic there, never
    /// hidden) and a non-nil `reset`; in the normal expanded mode `nil` `reset` means the countdown
    /// was dropped per the selection table (ADR-0029).
    private func drawBars(fiveHour: BarView, sevenDay: BarView?, reset: TimeToReset?,
                          originX: CGFloat, in rect: NSRect) {
        // Right edge of the bar column (same `barWidth` for one or two bars) — where the reset label
        // starts. The item width does not change when the 7-day bar is hidden (only the vertical
        // layout does), so this stays aligned with `barsBlockWidth`/`itemWidth`.
        let barsMaxX = originX + Metrics.barWidth

        if let sevenDay {
            // Two bars stacked, vertically centred as a block.
            let blockHeight = Metrics.barHeight * 2 + Metrics.barGap
            let topY = rect.minY + (rect.height - blockHeight) / 2
            drawBar(fiveHour, in: NSRect(
                x: originX, y: topY,
                width: Metrics.barWidth, height: Metrics.barHeight
            ))
            drawBar(sevenDay, in: NSRect(
                x: originX, y: topY + Metrics.barHeight + Metrics.barGap,
                width: Metrics.barWidth, height: Metrics.barHeight
            ))
        } else {
            // Single 5h bar (calm 7-day hidden, #94): vertically centred on the item.
            drawBar(fiveHour, in: NSRect(
                x: originX, y: rect.midY - Metrics.barHeight / 2,
                width: Metrics.barWidth, height: Metrics.barHeight
            ))
        }

        if let reset {
            drawResetLabel(reset, leftOf: barsMaxX + Metrics.labelGap, in: rect)
        }
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
        // In calm mode (#105) the soft idle blue mutes to white.
        if bar.idle {
            let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
            (calmColors ? Palette.calmWhite : Palette.idleBlue).setFill()
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
        let gapColor = calmedGapColor(l)
        fillZone(from: l.gapStart, to: l.gapEnd, in: rect, width: w, color: gapColor)

        NSGraphicsContext.restoreGraphicsState()

        // Time-indicator marker at timeFraction (drawn on top, unclipped so it stands proud).
        // A slim, lightly-rounded vertical bar rather than a dot — reads as a crisp position tick.
        // Colour tracks the pacing relationship: green when behind, red when ahead, teal on a tie.
        // A dark stroke rings the marker so it separates cleanly when it sits over a coloured zone.
        let cx = rect.minX + CGFloat(l.timeFraction) * w
        let cy = rect.midY
        let mw = Metrics.tickWidth
        let mh = Metrics.tickHeight
        let markerRect = NSRect(x: cx - mw / 2, y: cy - mh / 2, width: mw, height: mh)
        let marker = NSBezierPath(
            roundedRect: markerRect, xRadius: Metrics.tickCorner, yRadius: Metrics.tickCorner)
        indicatorColor(l).setFill()
        marker.fill()
        Palette.indicatorStroke.setStroke()
        marker.lineWidth = Metrics.tickStroke
        marker.stroke()
    }

    /// Colour of the time-indicator dot from the usage-vs-time relationship:
    /// - `usage < time` → behind pace (good) → green
    /// - `usage > time` → ahead of pace (bad) → the graded ahead colour (amber → orange → red)
    /// - `usage == time` → exactly on the line → green (a tie is still on pace, not behind)
    ///
    /// This is a finer split than `PacingState` (whose `.onPaceOrBehind` folds the tie into green), so
    /// the dot is computed from the raw fractions here. The ahead colour matches the popup exactly
    /// (`PopupBarView.aheadColor`), so the dot and its gap read as the same colour across both bars.
    ///
    /// Calm mode (#105): the dot follows its gap — it is white in exactly the states where the pacing
    /// gap under it mutes to white (the **calm** states — on pace / behind, and the mild ahead-of-pace
    /// yellow), and keeps its colour where the gap stays coloured (orange/red). So the dot never floats
    /// as a colour over a white strip. "Calm" is the SAME predicate the menu bar uses to drop the reset
    /// label (`BarLayout.isCalm`, ADR-0028) — one source of truth, so colour and countdown always agree.
    private func indicatorColor(_ l: BarLayout) -> NSColor {
        if calmColors && l.isCalm { return Palette.calmWhite }
        return l.timeFraction < l.usageFraction
            ? PopupBarView.aheadColor(usage: l.usageFraction, time: l.timeFraction)
            : Palette.dotGreen
    }

    /// The pacing-gap fill colour, with calm mode (#105) applied. Normally this is the on-pace green
    /// or the graded ahead colour (`PopupBarView.aheadColor`). When `calmColors` is on, the **calm**
    /// states (`BarLayout.isCalm`: on-pace green + mild-ahead yellow) mute to white; the strong warnings
    /// (orange/red) stay coloured.
    private func calmedGapColor(_ l: BarLayout) -> NSColor {
        if calmColors && l.isCalm { return Palette.calmWhite }
        return l.pacing == .ahead
            ? PopupBarView.aheadColor(usage: l.usageFraction, time: l.timeFraction)
            : Palette.gapGreen
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

    /// Map the reset countdown to its display string. `.resetNow` renders as a neutral `"<1m"`
    /// ("about to reset"), not the old colored ⏰ (#36) — it stays consistent with the monochrome text
    /// and the sub-minute `"<1m"` of the live countdown. In the normal reset-boundary flow the
    /// coordinator's optimistic-reset timer rolls the window forward before the countdown reaches zero,
    /// so `.resetNow` now only surfaces genuinely degenerate data (a missing/unparseable `resets_at`).
    private func resetText(_ reset: TimeToReset) -> String {
        switch reset {
        case let .absolute(s): return s
        case let .relative(s): return s
        case .resetNow:        return "<1m"
        }
    }

    /// The item width for a given layout — narrow for the glyph-only error/cold-start case, wider for
    /// the bars + label, widest for the ⚠️ + stale-bars phase (the glyph adds its own width). Driven
    /// dynamically so the item hugs exactly the content currently drawn.
    private func itemWidth(for layout: MenuBarLayout?) -> CGFloat {
        // The trailing decorations, when present, widen every mode by the same insets: the service dot
        // (#31) by dot + gap, the money-credits icon (#144) by glyph + gap. Both are additive.
        let dotInset = layout?.serviceProblem != nil ? Metrics.statusDotDiameter + Metrics.statusDotGap : 0
        let creditsInset = layout?.credits.map { creditsIconWidth(for: $0.currency) + Metrics.creditsIconGap } ?? 0
        let trailingInset = dotInset + creditsInset
        switch layout?.mode {
        case .none:
            return Metrics.height + trailingInset       // square-ish compact item (no layout yet)
        case let .expanded(_, _, resetToShow):
            return trailingInset + Metrics.hPadding + barsBlockWidth(reset: resetToShow?.display) + Metrics.hPadding
        case let .error(five, _, reset, _):
            // ⚠️ alone (cold start / >60 min) → compact; ⚠️ + stale bars (30–60 min) → glyph + bars.
            guard five != nil, let reset else { return Metrics.height + trailingInset }
            return trailingInset + Metrics.hPadding + errorGlyphWidth() + Metrics.errorGlyphGap
                + barsBlockWidth(reset: reset) + Metrics.hPadding
        }
    }

    /// Width of the bars block + (optionally) its reset label (no outer padding) — shared by the
    /// expanded and error-with-bars widths so they stay in sync with
    /// ``drawBars(fiveHour:sevenDay:reset:originX:in:)``. A `nil` `reset` omits the label (and its
    /// leading gap), so the item hugs just the bars (ADR-0029); the error path always passes non-nil.
    private func barsBlockWidth(reset: TimeToReset?) -> CGFloat {
        guard let reset else { return Metrics.barWidth }
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
