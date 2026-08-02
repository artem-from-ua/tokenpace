import AppKit
import TokenPaceKit

/// The menu-bar item's custom view — the thin AppKit shell of issue #10.
///
/// It owns **no** business logic: it switches on a ``MenuBarLayout`` (computed in `TokenPaceKit`)
/// and draws it into a single non-template `NSImage` (``snapshotImage()`` → `button.image`). All colours
/// are **system semantic** — the bar **track** is `labelColor` at 22 % alpha (a translucent silhouette
/// that both dims *and* breathes the wallpaper like the moon); the **bright** mono tones (reset text, ⚠️,
/// tick ring) are `labelColor` at the system menu-bar text opacity (``bright(_:)``);
/// accents (pacing gap, service dot, idle) are `.systemGreen`/`.systemRed`/… scaled by ``accentSaturation``.
/// No fixed sRGB, no statusline parity (the old xterm mapping was dropped). True template vibrancy is
/// unavailable for arbitrary coloured geometry, so this custom-draw approximation is the same one every
/// menu-bar app uses (Stats/iStat/AlDente); see ADR-0059.
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

    /// "Calm colours" (#105): when `true`, the widget's **soft** signals mute to a calm neutral (a
    /// system-matched light grey, `calmWhite`) — the idle
    /// blue track, the on-pace green gap, the mild ahead-of-pace yellow, and the **degraded (yellow)
    /// service dot**; the strong warnings (orange/red), the stronger service states
    /// (orange/red/blue/grey), and the ⚠️ glyph keep their colour. The time-indicator marker now
    /// shares its pacing gap's colour, so it follows the gap into white in the calm states too. Set by `AppDelegate`
    /// from `PersistedConfig.calmMenuBarColors`; the view stays a thin shell and does not read the
    /// config itself. Changing it requests a redraw (no size change).
    var calmColors: Bool = false {
        didSet {
            guard calmColors != oldValue else { return }
            needsDisplay = true
        }
    }

    /// "Work harder" (#…): when on, the far-behind **blue** (`.farBehind`) zone is treated as
    /// **non-calm** — it is NOT muted to white under ``calmColors``, so a big surplus stays coloured
    /// (a nudge that there's headroom to push). Only has a visible effect when `calmColors` is on;
    /// with calm off, blue is already coloured. Off by default. Redraw on change.
    var workHarder: Bool = false {
        didSet {
            guard workHarder != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Saturation/vividness of the **colour accents** (pacing gap, service dot, idle blue) — a multiplier
    /// applied to the resolved `.system*` colour at the draw site. `1.0` = the raw system colour; lower
    /// values mute the accent toward grey so it sits calmer against a busy wallpaper. Kept as a hook for
    /// the accent-tuning pass (the mono formula shipped first); at `1.0` the accents are the plain system
    /// colours. Redraw on change.
    var accentSaturation: CGFloat = 1.0 {
        didSet {
            guard accentSaturation != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The alpha the bright mono tones (reset text, ⚠️, tick ring) are drawn at. Measured live with
    /// Digital Color Meter (sRGB) against the system menu-bar text: a light bar wanted ~0.85 (`0x1E2423`,
    /// the system clock's tone) and a dark bar ~0.88 (`≈0xE6` vs system `0xE7`). The two are visually
    /// indistinguishable by eye, so a single mid value serves both — no per-theme switch. `labelColor`
    /// flips the *colour* by itself; this only pins the opacity (its own alpha varies with the vibrant
    /// appearance the widget image is drawn in — see ``bright(_:)``).
    private static let brightAlpha: CGFloat = 0.865

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
        /// Width of the time-indicator marker — a vertical bar (#…) drawn centred on the current
        /// time position. Widened from the old slim 3.5 pt tick so the "you are here" marker reads
        /// more boldly at a glance while still staying narrower than a blob-like dot.
        static let tickWidth: CGFloat = 5
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
        /// Point size of the orange "pause" glyph (`pause.fill`, #199) drawn to the **left** of the
        /// bars when fully blocked with bars kept visible. A touch smaller than the ⚠️ so it reads at
        /// about the same weight as the two-bar block it precedes.
        static let pauseGlyphSize: CGFloat = 11
        /// Gap between the pause glyph and the bars block to its right.
        static let pauseGlyphGap: CGFloat = 3
    }

    // MARK: Colour mapping (system semantic colours → NSColor)
    //
    // Every menu-bar colour is a **system semantic colour** resolved through `ColorStore` — the
    // coloured accents (pacing gap/marker, service dot, idle bar) map 1:1 onto the discrete
    // pacing/service buckets via `.systemGreen/.systemYellow/.systemOrange/.systemRed/.systemBlue`,
    // and the neutrals use the `*labelColor` family. The image draws through a per-appearance
    // handler (`snapshotImage`), so these flip light/dark and honour Increase Contrast automatically,
    // like the battery/Wi-Fi icons — no fixed sRGB, no manual appearance detection, no statusline
    // parity (the old xterm-256 mapping was dropped, ADR-0005 colour clause superseded).

    @MainActor
    private enum Palette {
        /// Pacing gap / dot when on pace or behind — `.systemGreen`. The ahead-of-pace colours are NOT
        /// here: they come from `PopupBarView.aheadColor` (discrete yellow/orange/red buckets), shared
        /// with the popup so both bars agree.
        static var gapGreen: NSColor { ColorStore.shared.color(.green) }

        /// Pacing gap / dot when **far behind** pace (deep behind / big surplus) on the base 5h/7d
        /// bars — `.systemBlue` via the dedicated `paceBlue` role (distinct from the idle-bar blue).
        /// Chosen by `PopupBarView.behindColor`; on the menu bar the surface only ever carries base
        /// 5h/7d bars, so no per-row gate is needed here.
        static var gapBlue: NSColor { ColorStore.shared.color(.paceBlue) }

        /// Time-indicator dot when on pace. Shares the unified green with the gap (`.systemGreen`), so the
        /// marker reads as the gap's colour with no manual lightening.
        static var dotGreen: NSColor { ColorStore.shared.color(.green) }
        /// Ring around the time-indicator marker so it stays distinct over any coloured zone —
        /// `.separatorColor`, so the ring flips with the bar (dark ring on a light bar and vice versa).
        static var indicatorStroke: NSColor { ColorStore.shared.color(.indicatorRing) }
        /// The neutral grey track of a menu-bar bar — the whole-bar background, i.e. BOTH the `used`
        /// head and the future/unused tail on either side of the coloured pacing gap. `labelColor` at
        /// 22 % alpha, so both flanks read identical and the track "breathes" with the wallpaper like a
        /// native icon. The unified `barTrack` role — the popup bar uses the same one.
        static var unusedGrey: NSColor { ColorStore.shared.color(.barTrack) }
        /// The **idle** 5-hour bar's solid fill (#100, ADR-0027) — the 5h window has no active session,
        /// so the bar is a knobless solid track meaning "ready to start, full quota available", not a
        /// pacing state. `.systemBlue`, so it flips light/dark and honours Increase Contrast like the
        /// native icons; the unified `blue` role, shared with the popup idle bar and maintenance dot.
        static var idleBlue: NSColor { ColorStore.shared.color(.blue) }
        /// The **calm-colours** replacement for the "ready to start" idle blue (#105/#158): under Calm
        /// colours the idle blue mutes to this quieter neutral rather than the plain `calmWhite`. Only the
        /// *ready* idle bar uses it; a *blocked* idle bar is the base track grey in both colour modes (see
        /// `drawBar`). `secondaryLabelColor` — a semantic neutral that flips with the bar.
        static var idleCalmGrey: NSColor { ColorStore.shared.color(.idleCalmGrey) }
        /// Idle glyph + reset label — follow the menu-bar foreground.
        static var foreground: NSColor { ColorStore.shared.color(.foreground) }

        /// The "calm colours" replacement (#105): the soft pacing colours (idle blue, on-pace green,
        /// mild-ahead yellow) — and, since the time-indicator marker now shares its gap's colour, the
        /// marker too — collapse to this when the user opts into a quieter menu bar. `labelColor`, the
        /// same semantic foreground the reset label uses, so the calm signals read as the neutral
        /// foreground and flip with the bar (a fixed light tone would vanish on a light bar).
        static var calmWhite: NSColor { ColorStore.shared.color(.calmWhite) }

        // Service-status dot (issue #31). The unified semantic hues (`.yellow/.orange/…`), shared with
        // the popup service dots, so the dot flips light/dark and honours Increase Contrast.
        // `operational` is never drawn (the dot appears only for a problem), so it is omitted.
        static var statusYellow: NSColor { ColorStore.shared.color(.yellow) }
        static var statusOrange: NSColor { ColorStore.shared.color(.orange) }
        static var statusRed:    NSColor { ColorStore.shared.color(.red) }
        static var statusBlue:   NSColor { ColorStore.shared.color(.blue) }
        static var statusGray:   NSColor { ColorStore.shared.color(.gray) }

        /// The orange "pause" glyph drawn to the left of the bars when the user is fully blocked
        /// (`CreditsPacing.isBlocked`) and kept the bars visible in that state (#199). The unified
        /// `orange` role.
        static var pauseOrange: NSColor { ColorStore.shared.color(.orange) }
    }

    // MARK: Colour resolution (ADR-0059)

    /// Resolve a **bright mono** colour (reset text, ⚠️, tick ring) at the system menu-bar text's opacity.
    ///
    /// `labelColor` already flips its *colour* correctly in the draw context (near-black on a light bar,
    /// near-white on a dark one), but its *alpha* comes out low under the vibrant menu-bar appearance the
    /// widget image is drawn in (measured 0.698), which made our text too light. So we keep `labelColor`'s
    /// resolved RGB and substitute a fixed alpha (``brightAlpha``) that matches the system clock on both a
    /// light and a dark bar. The bar *track* (`unusedGrey` = `labelColor@0.22`) is deliberately left
    /// untouched — measured there it already matches the moon, because the moon is itself a vibrant icon.
    /// Falls back to the colour unchanged if its RGB can't be resolved.
    private func bright(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return rgb.withAlphaComponent(Self.brightAlpha)
    }

    /// Outline the time-indicator marker's **left and right edges only where it overlaps the bar** —
    /// `quaternaryLabelColor` vertical strokes from the bar's top to its bottom, so the marker is set off
    /// from the coloured zone it sits over without ringing the ends that stand proud above/below the bar.
    private func strokeMarkerEdges(_ markerRect: NSRect, in barRect: NSRect, width: CGFloat) {
        let y0 = max(markerRect.minY, barRect.minY)
        let y1 = min(markerRect.maxY, barRect.maxY)
        guard y1 > y0 else { return }
        Palette.indicatorStroke.setFill()   // quaternaryLabelColor (tunable via .indicatorRing)
        // Flank the marker's edges from **outside** the fill, so the outline sits beside the marker rather
        // than eating into it.
        for x in [markerRect.minX - width, markerRect.maxX] {
            NSRect(x: x, y: y0, width: width, height: y1 - y0).fill()
        }
    }

    /// Scale a **colour accent** (pacing gap, service dot, idle blue) by ``accentSaturation`` — blend the
    /// resolved `.system*` colour toward its own grey (luma) so a lower value reads calmer against a busy
    /// wallpaper. At `1.0` the colour is returned unchanged.
    private func accent(_ color: NSColor) -> NSColor {
        guard accentSaturation < 1.0, let c = color.usingColorSpace(.sRGB) else { return color }
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        func mix(_ ch: CGFloat) -> CGFloat { luma + (ch - luma) * accentSaturation }
        return NSColor(srgbRed: mix(c.redComponent), green: mix(c.greenComponent),
                       blue: mix(c.blueComponent), alpha: c.alphaComponent)
    }

    /// The dot colour for a non-operational service state. `operational` should never reach here
    /// (the dot is drawn only for a problem) but maps to gray defensively.
    ///
    /// Calm colours (#105): `.degraded` is the **soft** service signal — the yellow counterpart of
    /// the mild ahead-of-pace yellow — so it mutes to the calm neutral (`calmWhite` = `labelColor`)
    /// alongside the pacing colours. The strong states (partial/major outage → orange/red) and the
    /// neutral ones (maintenance blue, unknown grey) keep their colour, matching how the pacing gap
    /// keeps orange/red under calm.
    private func statusDotColor(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .degraded:         return calmColors ? bright(Palette.calmWhite) : accent(Palette.statusYellow)
        case .partialOutage:    return accent(Palette.statusOrange)
        case .majorOutage:      return accent(Palette.statusRed)
        case .underMaintenance: return accent(Palette.statusBlue)
        case .unknown:          return accent(Palette.statusGray)
        case .operational:      return accent(Palette.statusGray)
        }
    }

    // MARK: NSView overrides

    /// Top-left origin makes the bar maths read naturally (y grows downward).
    override var isFlipped: Bool { true }

    /// Debug: big colour swatches instead of the widget (env `TOKENPACE_SWATCHES=1`) — draws the track
    /// and bright-tone candidate alphas as wide fills for precise eyedropping vs the system icons on the
    /// real bar (the only reliable way to compare RGB — a screenshot on a wide-gamut display lies). Dev-
    /// only; kept as a colour-tuning aid (the shipped widget never enters this branch).
    static let swatchMode = ProcessInfo.processInfo.environment["TOKENPACE_SWATCHES"] == "1"

    override var intrinsicContentSize: NSSize {
        Self.swatchMode
            ? NSSize(width: 120, height: Metrics.height)
            : NSSize(width: itemWidth(for: layout), height: Metrics.height)
    }

    // MARK: Rendering

    override func draw(_ dirtyRect: NSRect) {
        render(in: bounds)
    }

    /// Render the current layout into `rect` (the view's own bounds, or an `NSImage` canvas). Shared by
    /// ``draw(_:)`` and ``snapshotImage()`` so the menu-bar image and a hosted view draw identically.
    private func render(in rect: NSRect) {
        if Self.swatchMode {
            let w = rect.width / 4
            // labelColor resolves its COLOUR correctly in the draw context (black on a light bar, white on
            // a dark bar) — only its ALPHA is low under vibrancy (0.698). Forcing higher alpha keeps the
            // right colour and hits the system text opacity. Do NOT branch on effectiveAppearance — it
            // reports the system theme (Dark), not the actual bar (which can be light from the wallpaper).
            NSColor.labelColor.withAlphaComponent(0.22).setFill()   // [1] TRACK — vs the moon
            NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height).fill()
            NSColor.labelColor.withAlphaComponent(0.85).setFill()   // [2] bright @0.85 — vs clock text
            NSRect(x: rect.minX + w, y: rect.minY, width: w, height: rect.height).fill()
            NSColor.labelColor.withAlphaComponent(0.88).setFill()   // [3] bright @0.88 (balanced) — vs clock text
            NSRect(x: rect.minX + 2 * w, y: rect.minY, width: w, height: rect.height).fill()
            NSColor.labelColor.withAlphaComponent(0.90).setFill()   // [4] bright @0.90 — vs clock text
            NSRect(x: rect.minX + 3 * w, y: rect.minY, width: w, height: rect.height).fill()
            return
        }
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
        case let .blockedReset(reset, _):
            drawBlockedReset(reset, in: contentRect)
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
    /// Rendered as a **palette image** in the marker's pacing colour (``creditsIconColor(_:)``) — a system
    /// semantic colour resolved in the draw handler's appearance, matching the rest of the widget. Drawn
    /// with `respectFlipped: true` because this view is `isFlipped` (same as the ⚠️ glyph).
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
        if calmColors && credits.isCalm { return bright(Palette.calmWhite) }
        guard let l = credits.bar else { return bright(Palette.foreground) }   // unlimited → neutral
        return accent(l.timeFraction < l.usageFraction
            ? PopupBarView.aheadColor(usage: l.usageFraction, time: l.timeFraction, remainingSeconds: l.remainingSeconds)
            : Palette.dotGreen)
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

    /// Render the current layout to a non-template `NSImage` for the status item's `button.image`.
    ///
    /// Hosting the custom `NSView` as a button subview is unreliable (the system button owns its layout
    /// and paints over added subviews), so the robust path for fully custom menu-bar graphics is to hand
    /// the button a ready image. This is the industry-standard technique for a menu-bar widget that
    /// carries colour (Stats/iStat/AlDente all custom-draw with `NSColor.textColor`/`labelColor` for the
    /// mono part and explicit colours for accents): true template vibrancy is unavailable for arbitrary
    /// coloured geometry (`isTemplate` is all-or-nothing, and `wantsLayer`+overlay defeats vibrancy —
    /// Apple forums thread/776799), so we approximate it with system semantic colours and compensate the
    /// missing wallpaper-breathe with the mono-brightness slider / wallpaper calibration (ADR-0059).
    ///
    /// `isTemplate = false`: the widget carries real colour (pacing/service/idle) a template mask would
    /// strip.
    ///
    /// **Drawn EAGERLY inside the caller's `performAsCurrentDrawingAppearance` block** (`lockFocusFlipped`
    /// + `render` + `unlockFocus`) — NOT the lazy `NSImage(size:flipped:drawingHandler:)` form. The lazy
    /// handler runs *later*, when the status button paints, resolving dynamic colours against whatever
    /// appearance is current then (the vibrant menu-bar appearance, where e.g. `labelColor`'s alpha drops
    /// 0.847 → 0.698) — so the mono tones came out wrong (text too light, `tertiaryLabelColor` track
    /// mis-resolved). Drawing eagerly bakes every semantic colour against the button's *real*
    /// `effectiveAppearance` the caller set, giving the same values as the system clock/moon. The caller
    /// re-snapshots on a theme flip (its `effectiveAppearance` KVO) to rebake for the new appearance.
    /// `flipped: true` matches this view's `isFlipped` so `render(in:)`'s top-left maths is unchanged.
    func snapshotImage() -> NSImage {
        let size = intrinsicContentSize
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        render(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }


    // MARK: Expanded

    private func drawExpanded(fiveHour: BarView, sevenDay: BarView?, reset: TimeToReset?, in rect: NSRect) {
        // Fully blocked with bars kept visible (#199): draw the orange pause glyph first and shift the
        // bars right past it — same leading-glyph pattern as the ⚠️ error state (`drawError`).
        var originX = rect.minX + Metrics.hPadding
        if layout?.blockedPause == true {
            originX = drawPauseGlyph(in: rect) + Metrics.pauseGlyphGap
        }
        drawBars(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, originX: originX, in: rect)
    }

    /// Draw the orange "pause" glyph at the left of `rect`, vertically centred on the bars block, and
    /// return its right-edge x so ``drawExpanded`` can place the bars beside it (#199). A non-template
    /// palette image in ``Palette/pauseOrange``, drawn with `respectFlipped: true` (this view is
    /// `isFlipped`). Only reached when `layout.blockedPause` is set (fully blocked, bars kept visible).
    /// If `pause.fill` is unavailable the bars fall back to the normal leading origin (glyph omitted).
    @discardableResult
    private func drawPauseGlyph(in rect: NSRect) -> CGFloat {
        let originX = rect.minX + Metrics.hPadding
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.pauseGlyphSize, weight: .semibold)
            .applying(.init(paletteColors: [accent(Palette.pauseOrange)]))
        guard let symbol = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "all limits reached")?
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
            .applying(.init(paletteColors: [bright(Palette.foreground)]))   // ⚠️ — labelColor at text opacity
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
            // Idle bar fill (#100/#158): blocked → base track grey; ready+calm → quiet neutral;
            // ready+normal → the "ready to start" blue.
            let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
            let fill: NSColor = bar.blocked
                ? Palette.unusedGrey
                : (calmColors ? Palette.idleCalmGrey : accent(Palette.idleBlue))
            fill.setFill()
            path.fill()
            return
        }

        let l = bar.layout
        let w = rect.width

        // Whole-bar rounded grey track (drawn first; the gap paints over it). Both flanks of the gap —
        // the used head and the future/unused tail — are this one tone, so they read identical.
        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
        Palette.unusedGrey.setFill()   // the dimmed "moon" base
        path.fill()

        // Clip the gap fill to the rounded shape so corners stay clean.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        // Pacing gap: [gapStart, gapEnd). Ahead-of-pace uses the SAME graded colour as the popup
        // (`PopupBarView.aheadColor`: amber → orange → red by how far ahead), so the menu-bar bar and
        // the popup row agree — e.g. a yellow 7-day here reads yellow in the dropdown too. On pace →
        // `.systemGreen`.
        let gapColor = calmedGapColor(l)
        fillZone(from: l.gapStart, to: l.gapEnd, in: rect, width: w, color: gapColor)

        NSGraphicsContext.restoreGraphicsState()

        // Time-indicator marker at timeFraction (drawn on top, unclipped so it stands proud).
        // A slim, lightly-rounded vertical bar rather than a dot — reads as a crisp position tick.
        // Filled with this state's pacing-gap colour, ringed with `separatorColor` so it separates
        // cleanly over the coloured zone on both light and dark bars.
        let cx = rect.minX + CGFloat(l.timeFraction) * w
        let cy = rect.midY
        let mw = Metrics.tickWidth
        let mh = Metrics.tickHeight
        let markerRect = NSRect(x: cx - mw / 2, y: cy - mh / 2, width: mw, height: mh)
        let marker = NSBezierPath(
            roundedRect: markerRect, xRadius: Metrics.tickCorner, yRadius: Metrics.tickCorner)
        // Reset the bar under the marker back to the bare track (clipped to the bar), REPLACING the gap
        // there instead of layering over it. The marker fill is translucent (`bright(...)` = labelColor at
        // 0.865, kept translucent so it breathes the wallpaper); without this, a marker sitting inside the
        // gap would composite its own tone over the gap's identical tone — two half-transparent layers —
        // and read too dark (measured 0x1b vs the target 0x26 in calm on-pace). `.copy` overwrites rather
        // than blends, so the marker lands on ONE track layer, matching the reset text / tick opacity.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner).addClip()
        NSGraphicsContext.current?.compositingOperation = .copy
        Palette.unusedGrey.setFill()
        NSRect(x: markerRect.minX, y: rect.minY, width: markerRect.width, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        // The marker takes the EXACT colour of this state's pacing gap (`calmedGapColor`) — one tone
        // per pacing status, so the "you are here" tick reads as the same colour as the zone it marks.
        calmedGapColor(l).setFill()
        marker.fill()
        // Edge outline only where the marker overlaps the bar (`quaternaryLabelColor`): two short vertical
        // strokes down the marker's left and right edges, clipped to the bar's height — the parts of the
        // marker that stand proud above/below the bar carry no outline.
        strokeMarkerEdges(markerRect, in: rect, width: Metrics.tickStroke)
    }

    /// The pacing-gap fill colour, with calm mode (#105) applied. Normally this is the on-pace green
    /// or the graded ahead colour (`PopupBarView.aheadColor`). When `calmColors` is on, the **calm**
    /// states (`BarLayout.isCalm`: on-pace green + mild-ahead yellow) mute to white; the strong warnings
    /// (orange/red) stay coloured.
    private func calmedGapColor(_ l: BarLayout) -> NSColor {
        // Calm neutral is a bright tone (labelColor at the text opacity, via `bright`); the coloured
        // pacing gap is an accent (scaled by accentSaturation). Neither is the dimmed bar track.
        // "Work harder" exempts the far-behind blue from muting so a big surplus stays coloured.
        if calmColors && l.isCalm && !(workHarder && l.severity == .farBehind) {
            return bright(Palette.calmWhite)
        }
        if l.pacing == .ahead {
            return accent(PopupBarView.aheadColor(
                usage: l.usageFraction, time: l.timeFraction, remainingSeconds: l.remainingSeconds))
        }
        // Calm side: the menu bar only carries base 5h/7d bars, so split green↔blue unconditionally.
        return accent(PopupBarView.behindColor(l))
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
            .foregroundColor: bright(Palette.foreground),   // labelColor at the system text opacity
        ]
        let label = NSAttributedString(string: text, attributes: attrs)
        let size = label.size()
        label.draw(at: NSPoint(x: x, y: rect.minY + (rect.height - size.height) / 2))
    }

    /// Draw the blocked-state countdown **alone** (#194) — no bars, just the reset label at the left
    /// inset, vertically centred. Reuses the same monospaced-digit font and foreground colour as
    /// ``drawResetLabel(_:leftOf:in:)`` so the countdown looks identical whether or not the bars are
    /// hidden; `itemWidth` reserves exactly this label's width (via ``resetLabelWidth(_:)``) so the item
    /// hugs the text. The blocked mode carries no pacing colour to mute, so `calmColors` is irrelevant
    /// here — the label is always the neutral foreground.
    ///
    /// When `layout.blockedPause` is set (fully blocked, glyph opted in), the orange pause glyph is
    /// drawn first and the countdown shifts right past it — the same leading-glyph pattern the bars use
    /// in ``drawExpanded``, so the glyph appears whether or not the bars are hidden (#199).
    private func drawBlockedReset(_ reset: TimeToReset, in rect: NSRect) {
        var originX = rect.minX + Metrics.hPadding
        if layout?.blockedPause == true {
            originX = drawPauseGlyph(in: rect) + Metrics.pauseGlyphGap
        }
        drawResetLabel(reset, leftOf: originX, in: rect)
    }

    // MARK: Helpers

    /// Map the reset countdown to its display string. Both cases already carry a ready-to-draw string
    /// (`ResetClock` formats them). There is no longer a "reset now / unknown" case: a window past its
    /// boundary is rolled forward before formatting, and a missing/unparseable `resets_at` becomes the
    /// ⚠️ error state upstream (#167, ADR-0043) — so this never has to invent an about-to-reset glyph.
    private func resetText(_ reset: TimeToReset) -> String {
        switch reset {
        case let .absolute(s): return s
        case let .relative(s): return s
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
        // Leading orange pause glyph (#199) reserves its width + gap in both the bars (`.expanded`) and
        // the bars-less countdown (`.blockedReset`) modes, mirroring the origin shift in `drawExpanded`
        // / `drawBlockedReset`; zero when not fully blocked so the layout is unchanged otherwise.
        let pauseInset = (layout?.blockedPause == true) ? pauseGlyphWidth() + Metrics.pauseGlyphGap : 0
        switch layout?.mode {
        case .none:
            return Metrics.height + trailingInset       // square-ish compact item (no layout yet)
        case let .expanded(_, _, resetToShow):
            return trailingInset + Metrics.hPadding + pauseInset
                + barsBlockWidth(reset: resetToShow?.display) + Metrics.hPadding
        case let .blockedReset(reset, _):
            // No bars (#194): the item hugs the countdown label (plus the leading pause glyph, #199).
            return trailingInset + Metrics.hPadding + pauseInset + resetLabelWidth(reset) + Metrics.hPadding
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
        return Metrics.barWidth + Metrics.labelGap + resetLabelWidth(reset)
    }

    /// Rendered width of a reset label, measured with the exact font ``drawResetLabel`` /
    /// ``drawBlockedReset`` draw it in — so both the bars-plus-label width and the bars-less blocked
    /// width (#194) reserve precisely the drawn text. Rounded up so sub-pixel widths never clip the last
    /// glyph.
    private func resetLabelWidth(_ reset: TimeToReset) -> CGFloat {
        let labelWidth = (resetText(reset) as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ]).width
        return ceil(labelWidth)
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

    /// Rendered width of the orange pause glyph at ``Metrics/pauseGlyphSize`` — measured the same way
    /// it is drawn so the reserved width in ``itemWidth(for:)`` matches ``drawPauseGlyph(in:)`` exactly.
    /// Falls back to the glyph point size if the symbol is unavailable (a tiny over-reservation, never
    /// a clip — consistent with `drawPauseGlyph` omitting the glyph in that case).
    private func pauseGlyphWidth() -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.pauseGlyphSize, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return ceil(symbol?.size.width ?? Metrics.pauseGlyphSize)
    }
}
