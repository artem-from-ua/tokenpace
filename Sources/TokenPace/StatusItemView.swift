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
///
/// **One scoped exception (ADR-0070):** while a pacing colour is *changing*, ``ColorAnimator`` drives
/// ~450 ms of frames so the new colour eases in instead of snapping (a threshold crossing used to
/// read as a blink). The timer exists only for the duration of a transition and stops itself the
/// moment nothing is animating — an idle widget still runs no loop at all.
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

    /// How much of the **non-critical** pacing palette the widget mutes to a calm neutral (#105, #224,
    /// ADR-0061) — the single three-way ``CalmColorMode`` that replaces the old `calmMenuBarColors` +
    /// `workHarderColors` pair. The view reads its two derived flags:
    /// - ``CalmColorMode/mutesCalm`` — when true, the widget's **soft** signals mute to a calm neutral
    ///   (a system-matched light grey, `calmWhite`): the idle blue track, the on-pace green gap, the
    ///   mild ahead-of-pace yellow, and the **degraded (yellow) service dot**; the strong warnings
    ///   (orange/red), the stronger service states (orange/red/blue/grey), and the ⚠️ glyph keep their
    ///   colour. The time-indicator marker shares its pacing gap's colour, so it follows the gap into
    ///   white in the calm states too.
    /// - ``CalmColorMode/mutesBlue`` — when true, the far-behind **blue** (`.farBehind`) zone mutes
    ///   with the rest; when false (the old "Work harder" behaviour) it is treated as **non-calm** and
    ///   stays coloured, so a big surplus reads as a nudge that there's headroom to push. Only visible
    ///   when `mutesCalm` is on.
    ///
    /// Set by `AppDelegate` from `PersistedConfig.calmColorMode`; the view stays a thin shell and does
    /// not read the config itself. Changing it requests a redraw (no size change).
    var calmColorMode: CalmColorMode = .yellowGreenBlue {
        didSet {
            guard calmColorMode != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Bar presentation style for **this surface** (#224, per-surface since #329) — fed from
    /// `PersistedConfig.menuBarStyle`. ``BarStyle/progress`` draws the current gap + time-indicator
    /// marker; ``BarStyle/pressure`` a left-anchored ribbon with no marker; ``BarStyle/gauge`` a
    /// ribbon growing either way from a centre tick. Render-only (the bar occupies the same rect
    /// whichever it is), so a redraw is all that's needed.
    ///
    /// Deliberately **not** kept in sync with `PopupBarView.barStyle` any more: the two surfaces are
    /// chosen independently, and the drawing code they share is reached through `BarStyle.scale`.
    var barStyle: BarStyle = .progress {
        didSet {
            guard barStyle != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Drives the smooth colour transitions (ADR-0070). Every colour that can *change* — the pacing
    /// gap/ribbon, the time marker, the idle track, the service dot — is passed through
    /// ``ColorAnimator/resolve(_:target:)`` at the draw site, which returns the eased in-between tone
    /// while a transition is running and the plain target colour otherwise.
    ///
    /// Owned by `AppDelegate` (shared with the popup), never by this view: the animation must outlive
    /// individual draws, and the popup's bar views are rebuilt from scratch on every update. `nil`
    /// disables animation entirely — every colour renders at its target, which is exactly the old
    /// behaviour (used by the dev-tools preview, which has no app delegate behind it).
    weak var colorAnimator: ColorAnimator?

    /// The pacing-bar geometry override used by the `color-cycle` verification stub: when set, the
    /// **5-hour** bar's coloured strip is pinned to this fraction of the track (anchored at the left
    /// edge) and its time marker parks at that same point, so the *only* thing that moves on screen
    /// is the colour. Without it a colour walk would drag the strip's length and the marker along
    /// with it, and the eye could not tell a colour transition from a geometry jump.
    ///
    /// The 7-day bar deliberately keeps its real geometry, so there is a motionless reference right
    /// beside the animated one. `nil` on every real data path — see `StubScenario.colorCycle`.
    var frozenStripFraction: Double?

    /// The strip override for `bar`, applied only to the row the colour walk drives.
    private func frozenStrip(for bar: BarView) -> Double? {
        bar.window == .fiveHour ? frozenStripFraction : nil
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
        /// Vertical gap between the stacked 5h and 7d bars. Wide enough to read as two distinct rows
        /// without spreading the pair out — a tight stack sits more like a single compact widget.
        ///
        /// Must stay a **whole** number of points: ``halfPointAligned(_:)`` puts the 5h bar on the
        /// half-point grid the status button needs, and a whole gap carries that alignment down to the
        /// 7d bar. A fractional gap would leave the lower bar off-grid and blurred again. At 5 pt the
        /// block is 15 pt tall, leaving symmetric 3.5 pt margins inside the 22 pt item.
        static let barGap: CGFloat = 5
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
        /// Width of the **Gauge** centre tick (#326) — the permanent mark for the zero the ribbon
        /// grows out of. Deliberately a fifth of ``tickWidth``, and drawn *under* the track in the
        /// neutral tick tone rather than over it in the pacing colour, so a lone vertical mark on a
        /// 34 pt bar cannot be mistaken for the Progress time marker: only its ends show, it never
        /// moves, and it carries no colour.
        static let centreTickWidth: CGFloat = 1
        /// How far the transparent gutter under a yellow strip extends past it on each side (#326).
        /// 1.25 pt against this 5 pt bar — the popup's 1.5 pt scaled to the shorter track.
        static let yellowGutter: CGFloat = 1.25
        /// Corner radius of each bar — **and** of the coloured strip drawn over it (`fillZone` clamps
        /// to this rather than rounding a capsule, #326). The value itself is the shipped 1.5;
        /// only the strip's sharing of it is new.
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
        /// Point size of the money-credits currency glyph (`coloncurrencysign` ¤, #144). Tuned to read
        /// at the same visual weight as the bars block and the ⚠️ glyph — a touch larger than the bars
        /// are tall so the generic-currency mark stays legible at menu-bar size.
        static let creditsIconSize: CGFloat = 12
        /// Gap after the money-credits icon. In the bars modes it is a leading element between the pause
        /// glyph and the bars (#227), so this is the separation to the bars on its right; in the `.error`
        /// state it is trailing and this is the separation to the content on its left.
        static let creditsIconGap: CGFloat = 4
        /// Point size of the red "pause" glyph (`pause.fill`, #199, #227) drawn as the **leftmost**
        /// element when fully blocked. A touch smaller than the ⚠️ so it reads at about the same weight
        /// as the two-bar block it precedes.
        static let pauseGlyphSize: CGFloat = 11
        /// Gap between the pause glyph and the element to its right (credits icon or bars).
        static let pauseGlyphGap: CGFloat = 3
        /// Point size of the awaiting-input `hand.raised` indicator (#233), drawn as the **first
        /// leading** element (before pause/credits/bars). Sized like the credits glyph so it reads at
        /// the same weight as the other menu-bar decorations.
        static let awaitingIconSize: CGFloat = 12
        /// Gap between the awaiting-input icon and the element to its right (pause / credits / bars).
        /// A touch wider than the other decoration gaps so the hand doesn't crowd the next element.
        static let awaitingIconGap: CGFloat = 6
        /// How far below its resting position the awaiting hand sits when fully hidden (ADR-0073).
        ///
        /// The full item height rather than the measured symbol height: the ~13 pt glyph is centred
        /// in a 22 pt row, so the distance from its resting top edge to the row's bottom is ≈17.5 pt
        /// at most. 22 clears that with margin — anything short leaves a sliver of the fingertips
        /// parked at the bottom edge, reading as a stray mark rather than an absent icon — and it is
        /// one constant instead of a number derived from whatever SF Symbols reports today.
        static let awaitingSlideTravel: CGFloat = height
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
        /// bars — `.systemBlue` via the shared `blue` role, the same one the idle fill and the
        /// maintenance dot use. Chosen by `PopupBarView.behindColor`; on the menu bar the surface only
        /// ever carries base 5h/7d bars, so no per-row gate is needed here.
        static var gapBlue: NSColor { ColorStore.shared.color(.blue) }

        /// Time-indicator dot when on pace. Shares the unified green with the gap (`.systemGreen`), so the
        /// marker reads as the gap's colour with no manual lightening.
        static var dotGreen: NSColor { ColorStore.shared.color(.green) }
        /// Ring around the time-indicator marker so it stays distinct over any coloured zone —
        /// `.separatorColor`, so the ring flips with the bar (dark ring on a light bar and vice versa).
        static var indicatorStroke: NSColor { ColorStore.shared.color(.indicatorRing) }
        /// The **Gauge** centre tick (#326) — `secondaryLabelColor` by default, brighter than both the
        /// marker's `indicatorRing` and the popup ruler's `tick`. It gets its own role because it
        /// carries more weight than either: it is the only fixed landmark on the centred scale, and
        /// the direction the ribbon leaves it in *is* the reading. A dimmer tone made the zero hard to
        /// locate on the 34 pt bar, and everything the style says is relative to it.
        static var centreTick: NSColor { ColorStore.shared.color(.centreTick) }
        /// The neutral grey track of a menu-bar bar — the whole-bar background, i.e. BOTH the `used`
        /// head and the future/unused tail on either side of the coloured pacing gap. `labelColor` at
        /// 22 % alpha, so both flanks read identical and the track "breathes" with the wallpaper like a
        /// native icon. The unified `barTrack` role — the popup bar uses the same one.
        static var unusedGrey: NSColor { ColorStore.shared.color(.barTrack) }
        /// The **idle** 5-hour bar's solid fill (#100, ADR-0027) — the 5h window has no active session,
        /// so the bar is a knobless solid track meaning "ready to start", not a
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

        /// The red "pause" glyph drawn to the left of the bars/countdown when the user is fully blocked
        /// (`CreditsPacing.isBlocked`) — the "no path to work" signal (#199, #227). The unified `red`
        /// role, shared with the exhausted-limit bars and the blocking reset pill.
        static var pauseRed: NSColor { ColorStore.shared.color(.red) }
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
        let target = statusDotTarget(status)
        guard let colorAnimator else { return target }
        // One key for the widget's single dot — it always shows the *worst* problem, so a change of
        // severity is a colour change on the same element, exactly what should fade (ADR-0070).
        return colorAnimator.resolve(
            .serviceDot(surface: .menuBar, component: "worst"), target: target)
    }

    /// The dot's colour for a status, before the transition layer.
    private func statusDotTarget(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .degraded:         return calmColorMode.mutesCalm ? bright(Palette.calmWhite) : accent(Palette.statusYellow)
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

        // The service-status dot (#31) is always the **rightmost** (trailing) element; its width is
        // reserved from the right so the mode content keeps its leading position.
        var contentRect = rect
        if let problem = layout.serviceProblem {
            drawStatusDot(problem, in: contentRect)
            let inset = Metrics.statusDotDiameter + Metrics.statusDotGap
            contentRect = NSRect(x: contentRect.minX, y: contentRect.minY,
                                 width: contentRect.width - inset, height: contentRect.height)
        }
        // The money-credits icon (#144): in the bars modes it is a **leading** element between the pause
        // glyph and the bars (drawn inside `drawExpanded`/`drawBlockedReset`, #227). In the diagnostic
        // `.error` state there is no leading pause sequence, so it stays trailing (just left of the dot).
        if case .error = layout.mode, let credits = layout.credits {
            drawCreditsIconTrailing(credits, in: contentRect)
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

    /// The leading-decoration origin for the bars modes (`.expanded`/`.blockedReset`): draw the pause
    /// glyph (when blocked) then the credits icon (when present), each advancing the origin, and return
    /// the x where the bars/countdown should start. Keeps the left-to-right order **pause → credits →
    /// content** consistent across both modes (#199, #227).
    private func drawLeadingDecorations(in rect: NSRect) -> CGFloat {
        var originX = rect.minX + Metrics.hPadding
        // #233: the awaiting-input hand is the **first** leading element (left of pause/credits/bars).
        //
        // The origin advances whenever the **slot** is reserved, not whenever the glyph is drawn
        // (#283) — the two conditions differ while nothing is waiting. Advancing only when the glyph
        // is present would put the reserved width to the *right* of everything instead of to the left
        // of it, so the bars would still shift on every change and the reservation would buy nothing.
        //
        // The step is the measured reserve (`awaitingIconWidth()`), the same number `itemWidth(for:)`
        // adds — never the drawn symbol's own width, so slot and glyph cannot drift apart by a
        // sub-pixel.
        if reservesAwaitingSlot {
            drawAwaitingIcon(atX: originX, in: rect)
            originX += awaitingIconWidth() + Metrics.awaitingIconGap
        }
        if layout?.blockedPause == true {
            originX = drawPauseGlyph(atX: originX, in: rect) + Metrics.pauseGlyphGap
        }
        if let credits = layout?.credits {
            originX = drawCreditsIcon(credits, atX: originX, in: rect) + Metrics.creditsIconGap
        }
        return originX
    }

    /// Whether the hand's **slot** is reserved — driven by the Appearance option alone, deliberately
    /// ignoring whether anything is waiting right now (#283).
    ///
    /// The menu bar is right-aligned, so every width change shifts everything to its left, including
    /// other apps' status items. Of the five data-dependent addends in ``itemWidth(for:)`` the hand
    /// is the only high-frequency one — it toggles dozens of times a day, during ordinary work, and
    /// carries no news about the widget's own layout. The other four fire once or twice per 5-hour
    /// window and at the exact moment the user is already looking at the widget for that reason, so
    /// their jump explains itself and stays as it is.
    ///
    /// This changes what the existing toggle means: "Show in menu bar" reserves the slot rather than
    /// describing what is on screen this second. Users who keep the indicator off pay nothing.
    ///
    /// **Both** flags, not just the placement one. Turning the Extra-features master off only
    /// *disables* the Appearance toggle — its stored value stays `true` — so reading the placement
    /// flag alone would keep ≈18 pt reserved for a feature the user has switched off entirely. The
    /// condition this replaced happened to cover that case through the data (`awaitingInput` is
    /// always nil while the master is off), which is exactly why it needs restating now that the
    /// reservation no longer looks at the data.
    private var reservesAwaitingSlot: Bool {
        PersistedConfig.awaitingInputEnabled && PersistedConfig.awaitingInputInMenuBar
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

    // MARK: Awaiting-input icon (#233)

    /// Draw the `hand.raised` awaiting-input indicator in the reserved slot at **leading** `x` — the
    /// **first** leading decoration (before pause/credits/bars). Bare icon, no count (the count lives
    /// in the popup).
    ///
    /// Draws nothing when the glyph is fully hidden; the caller advances the origin by the reserved
    /// width regardless (#283), so this returns nothing to place the next element by.
    ///
    /// The glyph slides in from below the widget's bottom edge and back down out of it (ADR-0073),
    /// clipped to its own slot. Its position comes from a presence factor the animator interpolates:
    /// 0 fully hidden, 1 at rest.
    private func drawAwaitingIcon(atX x: CGFloat, in rect: NSRect) {
        // Tint by urgency (soonest deletion across all awaiting sessions): red < 7d left, orange
        // < 15d, neutral otherwise (#233/#234). accent(...) for the coloured states so they read at
        // the same weight as the pause/credits glyphs; bright(label) for neutral.
        //
        // A hand on its way *out* has no urgency left in the layout — the count is already gone — so
        // it would grey out halfway down. The animator remembers the last one it was drawn with.
        let urgency: AwaitingUrgency
        if let live = layout?.awaitingInput?.urgency {
            urgency = live
            colorAnimator?.noteAwaitingUrgency(live)
        } else {
            urgency = colorAnimator?.lastAwaitingUrgency ?? .neutral
        }
        let tint: NSColor
        switch urgency {
        case .red:     tint = accent(.systemRed)
        case .orange:  tint = accent(.systemOrange)
        case .neutral: tint = bright(NSColor.labelColor)
        }

        // Presence target: the glyph belongs on screen exactly when the layout carries a count
        // (feature on + ≥ 1 session). The Appearance option is already accounted for — this method
        // only runs inside the reserved slot — which is what keeps the `TOKENPACE_AWAITING` stub
        // honest: it forces the *count* upstream, so toggling "Show in menu bar" still hides the hand
        // under the stub exactly as it does with real data.
        //
        // Resolved on **every** frame the slot exists, including those where nothing is waiting
        // (target 0) — that is what keeps the key alive so a departing hand can animate out at all.
        // See `ColorAnimator.resolve(_:target:)`; skipping this call when the count is nil silently
        // kills the exit animation and lets the key be pruned.
        let target: Double = layout?.awaitingInput != nil ? 1 : 0
        let presence = colorAnimator?.resolve(.awaitingIcon(surface: .menuBar), target: target) ?? target
        guard presence > 0 else { return }

        let config = NSImage.SymbolConfiguration(pointSize: Metrics.awaitingIconSize, weight: .semibold)
            .applying(.init(paletteColors: [tint]))
        guard let symbol = NSImage(
            systemSymbolName: "hand.raised", accessibilityDescription: "sessions awaiting input")?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size

        // This view is `isFlipped` (and `snapshotImage()` locks focus flipped to match), so y grows
        // **downward**: adding the offset pushes the glyph down, out through the bottom edge. The one
        // place in this file where flippedness changes a sign. (`respectFlipped: true` below only
        // un-mirrors the symbol's own content; it does not move `drawRect`.)
        let restY = rect.midY - size.height / 2
        let offset = (1 - presence) * Metrics.awaitingSlideTravel
        let drawRect = NSRect(x: x, y: restY + offset, width: size.width, height: size.height)

        // Clip to the slot, not to `rect`: the bottom edge is where the glyph disappears, and the
        // side edges keep a symbol wider than its measured reserve from ever bleeding onto the pause
        // glyph. `addClip` intersects, so any clip the status button installed still holds.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: x, y: rect.minY,
                                  width: awaitingIconWidth(), height: rect.height)).addClip()
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Money-credits icon (issue #144)

    /// Draw the money-credits currency glyph at **leading** `x`, vertically centred on `rect`, and return
    /// its right-edge x so the caller can place the bars/countdown beside it (#144, #227). In the bars
    /// modes the icon sits between the pause glyph and the bars; the width is measured the same way
    /// ``creditsIconWidth(for:)`` reserves it. Returns `x` unchanged if the symbol can't be built.
    ///
    /// The glyph is **currency-specific** (``creditsSymbolName(for:)``): a known currency draws its own
    /// SF Symbol (`eurosign`/`dollarsign`/…), an unknown/empty code falls back to the generic
    /// `coloncurrencysign` (¤) — never a hard-coded `$` (the currency is dynamic; EUR observed, #142).
    /// Rendered as a **palette image** in the marker's pacing colour (``creditsIconColor(_:)``) — a system
    /// semantic colour resolved in the draw handler's appearance, matching the rest of the widget. Drawn
    /// with `respectFlipped: true` because this view is `isFlipped` (same as the ⚠️ glyph).
    @discardableResult
    private func drawCreditsIcon(_ credits: CreditsMarker, atX x: CGFloat, in rect: NSRect) -> CGFloat {
        guard let symbol = creditsSymbolImage(credits) else { return x }
        let size = symbol.size
        let drawRect = NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        return x + ceil(size.width)
    }

    /// Draw the money-credits glyph at the **right edge** of `rect` (trailing, just left of the service
    /// dot whose width the caller reserved). Used only by the diagnostic ``MenuBarMode/error`` state,
    /// which has no leading pause sequence; the bars modes draw it leading via ``drawCreditsIcon(_:atX:in:)``.
    private func drawCreditsIconTrailing(_ credits: CreditsMarker, in rect: NSRect) {
        guard let symbol = creditsSymbolImage(credits) else { return }
        let size = symbol.size
        let x = rect.maxX - Metrics.hPadding - size.width
        let drawRect = NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }

    /// The configured currency-symbol image for a credits marker, or `nil` if the SF Symbol can't be
    /// built. Shared by the leading and trailing draw paths so both render identically.
    private func creditsSymbolImage(_ credits: CreditsMarker) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.creditsIconSize, weight: .semibold)
            .applying(.init(paletteColors: [creditsIconColor(credits)]))
        return NSImage(
            systemSymbolName: Self.creditsSymbolName(for: credits.currency),
            accessibilityDescription: "usage credits")?
            .withSymbolConfiguration(config)
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

    /// The colour of the money-credits icon. Unlike the pacing bars, this glyph uses a deliberately
    /// **three-step** scale — white → orange → red — and never green or yellow.
    ///
    /// The bars grade green/yellow/orange/red because they show *how you are pacing*. The credits glyph
    /// answers a different question — *is real money moving, and how close is it to the cap* — where a
    /// green "all good" tint would be misleading (money is being spent either way) and yellow adds a rung
    /// that carries no action. So:
    /// - `bar == nil` (unlimited monthly limit) → the neutral menu-bar foreground: credits are active but
    ///   there is no cap to pace against.
    /// - on pace / behind, or only mildly ahead → **white**: spending is under control.
    /// - strongly ahead of pace → **orange**.
    /// - at the cap → **red** (`aheadColor`'s `usage >= 1` rung).
    ///
    /// Calm mode (#105) still mutes the calm states to the calm white, which this scale already agrees
    /// with — so the two paths cannot disagree.
    private func creditsIconColor(_ credits: CreditsMarker) -> NSColor {
        if calmColorMode.mutesCalm && credits.isCalm { return bright(Palette.calmWhite) }
        guard let l = credits.bar else { return bright(Palette.foreground) }   // unlimited → neutral
        // At the cap → red. Otherwise only a *strong* ahead reads as orange; on-pace/behind and the
        // mild-ahead rung (which the bars paint yellow) both render white. The thresholds mirror
        // `PopupBarView.aheadColor` so the glyph and the bars never disagree about which rung we're on.
        if l.usageFraction >= 1 { return accent(ColorStore.shared.color(.red)) }
        guard l.timeFraction < l.usageFraction else { return bright(Palette.calmWhite) }
        let stronglyAhead = l.remainingSeconds <= PacingModel.pacingOrangeOverrideSeconds
            || (l.usageFraction - l.timeFraction) >= PacingModel.aheadThreshold(timeFraction: l.timeFraction)
        return stronglyAhead ? accent(ColorStore.shared.color(.orange)) : bright(Palette.calmWhite)
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

    private func drawExpanded(fiveHour: BarView?, sevenDay: BarView?, reset: String?, in rect: NSRect) {
        // Leading decorations first (#199, #227): the red pause glyph (when blocked) then the credits
        // icon (when present), each shifting the bars right past it — the same leading pattern the ⚠️
        // error state uses. Order: pause → credits → bars.
        let originX = drawLeadingDecorations(in: rect)
        drawBars(fiveHour: fiveHour, sevenDay: sevenDay, reset: reset, originX: originX, in: rect)
    }

    /// Draw the red "pause" glyph at leading `x`, vertically centred on `rect`, and return its right-edge
    /// x so the caller can place the next element beside it (#199, #227). A non-template palette image in
    /// ``Palette/pauseRed``, drawn with `respectFlipped: true` (this view is `isFlipped`). Only reached
    /// when `layout.blockedPause` is set (fully blocked). If `pause.fill` is unavailable the caller falls
    /// back to `x` (glyph omitted).
    @discardableResult
    private func drawPauseGlyph(atX x: CGFloat, in rect: NSRect) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.pauseGlyphSize, weight: .semibold)
            .applying(.init(paletteColors: [accent(Palette.pauseRed)]))
        guard let symbol = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "all limits reached")?
            .withSymbolConfiguration(config) else {
            return x
        }
        let size = symbol.size
        let drawRect = NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        return x + ceil(size.width)
    }

    /// Snap `y` to the nearest **half-point**, the grid a bar edge must sit on to render sharp.
    ///
    /// The widget image is drawn into an `NSStatusBarButton` whose frame is centred at a half-point y in
    /// its status window (`(33 - 22) / 2 = 5.5`, measured on macOS 15). Screen y is therefore
    /// `image y + 5.5`, so `x.5` inside the image lands on a whole point on screen — and a whole point
    /// inside the image lands halfway between two, which the compositor antialiases into the blur that
    /// only the two-bar stack showed. The single-bar branch already sits at 8.5 for the same reason, so
    /// this makes the stacked pair agree with it rather than changing how one bar looks.
    ///
    /// Rounds to the nearest half-point (never by more than 0.25 pt), so the block stays visually centred.
    private func halfPointAligned(_ y: CGFloat) -> CGFloat {
        (y - 0.5).rounded() + 0.5
    }

    /// Draw the pacing bars starting at `originX`; the reset label is drawn to their right only when
    /// `reset != nil`. Two layouts by **how many** bars are present:
    /// - **both**: 5h on top, 7d below, the pair vertically centred as one block.
    /// - **one** (the other was hidden while calm — ``CalmBarHiding``, ADR-0086): that bar **alone**,
    ///   vertically centred on the item — so a single bar sits mid-height, not clinging to the top row.
    ///   The geometry depends on the *count*, not on which window survived, so a lone 7-day bar lands
    ///   exactly where a lone 5-hour bar used to (#94).
    ///
    /// Shared by ``drawExpanded(fiveHour:sevenDay:reset:in:)`` and the bars-beside-⚠️ error phase so
    /// the geometry is identical; only the left origin differs (the error glyph shifts it right). The
    /// error phase always passes both bars (they are diagnostic there, never hidden) and a non-nil
    /// `reset`; in the normal expanded mode `nil` `reset` means the countdown was dropped per the
    /// selection table (ADR-0029).
    private func drawBars(fiveHour: BarView?, sevenDay: BarView?, reset: String?,
                          originX: CGFloat, in rect: NSRect) {
        // Right edge of the bar column (same `barWidth` for one or two bars) — where the reset label
        // starts. The item width does not change when the 7-day bar is hidden (only the vertical
        // layout does), so this stays aligned with `barsBlockWidth`/`itemWidth`.
        let barsMaxX = originX + Metrics.barWidth

        switch (fiveHour, sevenDay) {
        case let (.some(five), .some(seven)):
            // Two bars stacked, vertically centred as a block, then nudged onto the pixel grid.
            //
            // `NSStatusBarButton` sits at a **half-point** y inside its window — its 22 pt frame is
            // centred in a 33 pt status window, giving `(33 - 22) / 2 = 5.5` (measured, macOS 15). Every
            // point in this image therefore lands on screen at `y + 5.5`, so a bar edge is only pixel-
            // aligned when its y *inside the image* is itself a half-point. Two 5 pt bars with a 4 pt gap
            // centre at a whole 4.0, which becomes a blurred 9.5 on screen; the single-bar branch happens
            // to sit at 8.5 → a sharp 14.0, which is why only the stacked pair looked fuzzy.
            let blockHeight = Metrics.barHeight * 2 + Metrics.barGap
            let topY = halfPointAligned(rect.minY + (rect.height - blockHeight) / 2)
            drawBar(five, in: NSRect(
                x: originX, y: topY,
                width: Metrics.barWidth, height: Metrics.barHeight
            ))
            drawBar(seven, in: NSRect(
                x: originX, y: topY + Metrics.barHeight + Metrics.barGap,
                width: Metrics.barWidth, height: Metrics.barHeight
            ))
        case let (.some(only), nil), let (nil, .some(only)):
            // One bar (the other was hidden while calm): vertically centred on the item. Same y for
            // either window — a lone 7-day bar sits exactly where a lone 5-hour bar did before ADR-0086.
            drawBar(only, in: NSRect(
                x: originX, y: rect.midY - Metrics.barHeight / 2,
                width: Metrics.barWidth, height: Metrics.barHeight
            ))
        case (nil, nil):
            // Unreachable: `CalmBarHiding` elides at most one bar, so `.expanded` always carries one
            // (see `MenuBarMode.expanded`'s invariant), and the error phase passes both or neither —
            // and the neither case never reaches here (`drawError` draws the glyph alone instead).
            // A silent no-op rather than an assertion: the view stays a thin shell (ADR-0009).
            break
        }

        if let reset {
            drawResetLabel(reset, slotAt: barsMaxX + Metrics.labelGap, in: rect)
        }
    }

    // MARK: Error (issue #12)

    /// Draw the error state: the ⚠️ glyph at the left, and — during the 30–60 min stale phase —
    /// the last known bars + reset beside it (all bars `nil` past 60 min / cold start → glyph alone).
    private func drawError(fiveHour: BarView?, sevenDay: BarView?, reset: String?, in rect: NSRect) {
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
        // Idle 5h bar (#100, ADR-0027): no pacing zones — "no active session".
        // The bar's `layout`/`indicator` are inert here.
        //
        // Idle is drawn the same way in **both** styles (#325): the bare grey track, plus the minimum
        // pill at the left edge — the shape any zero-length ribbon draws. Progress adds its identifying
        // time marker on top, parked at `timeFraction` = 0 (the window has just rolled), which covers
        // the pill; that marker is the only difference between the two styles here.
        //
        // Progress used to fill the whole bar solid blue, which read exactly like a Pressure bar at
        // *full* pressure — the loudest mark for the calmest state. Zero usage is zero on both scales.
        // Mirror of `PopupBarView.draw`'s idle branch.
        if bar.idle {
            // Idle bar fill (#100/#158): blocked → base track grey; ready+calm → quiet neutral;
            // ready+normal → the "ready to start" blue.
            //
            // Calm uses the same `calmWhite` neutral as every muted pacing bar, not a dimmer tone of
            // its own (#307): idle sitting quieter than the calm bars beside it made the "nothing is
            // happening" state read as "something is wrong with this bar".
            // Blue only while the week has headroom (`PacingModel.weeklyHasHeadroom`): the "ready to
            // start" blue claims quota to burn, which is wrong once the week runs ahead of pace — it
            // degrades to green there, the same way the pacing blue does. Grey still means blocked.
            let idleReady = bar.weeklyHeadroom ? Palette.idleBlue : Palette.gapGreen
            let idleTarget: NSColor = bar.blocked
                ? Palette.unusedGrey
                : (calmColorMode.mutesCalm ? Palette.calmWhite : accent(idleReady))
            // Animated like any other bar colour, so idle→active (blue→green) and the blocked grey
            // swap fade rather than snap.
            let fill = animated(idleTarget, window: bar.window, part: .fill)
            let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
            // Gauge's zero is the centre, so its idle pill sits there rather than at the left edge —
            // the same "grey track + zero pill" shape ADR-0078 fixes for every style, drawn on this
            // style's own scale. Its centre tick goes down first, under the track, exactly as the
            // pacing path does: the tick is drawn in *every* state, which is what makes the zero
            // findable at all.
            let idleZero = barStyle.scale == .centred ? 0.5 : 0.0
            if barStyle.scale == .centred { drawCentreTick(in: rect) }
            // Zero pressure — the same pill `fillZone(floorEmptyToPill:)` draws for a zero ribbon.
            // The grey track goes down first, exactly as the pacing path does: without it the pill
            // would hang in empty space while every neighbouring bar shows a track.
            Palette.unusedGrey.setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            fillZone(from: idleZero, to: idleZero, in: rect, width: rect.width, color: fill,
                     floorEmptyToPill: true)
            NSGraphicsContext.restoreGraphicsState()
            // Progress keeps its identifying mark: the marker at `timeFraction` = 0, drawn over the pill.
            if barStyle.showsTimeMarker { drawTimeMarker(at: 0, colour: fill, in: rect) }
            return
        }

        let l = bar.layout
        let w = rect.width

        // Gauge's centre tick goes down BEFORE the track (#326): the track then covers its middle and
        // only the ends stand proud, which is what keeps it from reading as a Progress time marker.
        if barStyle.scale == .centred { drawCentreTick(in: rect) }

        // Whole-bar rounded grey track (drawn first; the gap paints over it). Both flanks of the gap —
        // the used head and the future/unused tail — are this one tone, so they read identical.
        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.barCorner, yRadius: Metrics.barCorner)
        Palette.unusedGrey.setFill()   // the dimmed "moon" base
        path.fill()

        // Clip the coloured fill to the rounded shape so corners stay clean.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        // Pressure style (#224, rescaled in #307): a left-anchored ribbon coloured by the SAME pacing
        // state colour a Progress gap would use (`calmedGapColor` — carries calm-muting / work-harder
        // too), with no time-indicator marker. The ribbon's LENGTH is `BarLayout.pressureLength` —
        // the gap measured against the time left before the reset, NOT the window-scale gap width
        // Progress draws. So the two styles no longer show the same amount of colour: Pressure is
        // wider exactly where the state is more urgent. Mirror of `PopupBarView.draw`'s Pressure branch.
        // The `color-cycle` stub pins the strip's length so only the colour moves — see
        // `frozenStripFraction`; it overrides the length, so the stub is unaffected by the rescale.
        // The *style* still decides whether a marker follows, so Progress keeps its full anatomy under
        // the stub instead of collapsing into Pressure.
        // Gauge (#326, ADR-0079): the ribbon runs from the bar's CENTRE to `0.5 + offset/2`, so its
        // direction carries ahead-vs-behind and its length carries by how much. Same colour source as
        // every other style — this changes the geometry, never the verdict. The floor applies for the
        // same reason it does on the Pressure branch, but about the centre: `u == t` is a real,
        // recurring state (and the exact one this style is built to show as "on pace"), so a
        // degenerate span becomes a centred pill rather than a blank track. `pinsStart` stays off:
        // both edges here are data, and the floor must grow symmetrically about the zero — pinning
        // would shove the pill off-centre and make "dead on pace" read as a small lead.
        if barStyle.scale == .centred {
            let offset = frozenStrip(for: bar).map { $0 * 2 - 1 } ?? l.gaugeOffset
            let far = 0.5 + offset / 2
            fillZone(from: min(0.5, far), to: max(0.5, far), in: rect, width: w,
                     color: calmedGapColor(l, window: bar.window), floorEmptyToPill: true,
                     anchoredAt: 0.5)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        if !barStyle.showsTimeMarker {
            // A **zero-length** ribbon still has to read as "zero", not as an empty track. Without a time
            // marker this branch is the bar's only mark, so `stripRect`'s degenerate-span `nil` would
            // leave the widget completely blank — which is exactly what the reset boundary produces:
            // `applyIdleGrace`/`suppress` (ADR-0041, ADR-0045) render 0 % against a freshly rolled
            // `resets_at = now + 5h`, i.e. `usage == time == 0`, so `pressureLength` is *exactly* 0
            // for the first ticks of every new 5-hour window. A 1-minute-old window already draws the
            // min-width pill, so flooring the span here keeps 0 looking like 0 instead of blinking the
            // bar off. Progress is deliberately excluded: there an empty gap means "dead on pace" and
            // the marker already carries the position.
            let ribbon = frozenStrip(for: bar) ?? l.pressureLength
            fillZone(from: 0, to: ribbon, in: rect, width: w,
                     color: calmedGapColor(l, window: bar.window), floorEmptyToPill: true)
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // Pacing gap: [gapStart, gapEnd). Ahead-of-pace uses the SAME graded colour as the popup
        // (`PopupBarView.aheadColor`: amber → orange → red by how far ahead), so the menu-bar bar and
        // the popup row agree — e.g. a yellow 7-day here reads yellow in the dropdown too. On pace →
        // `.systemGreen`.
        let gapColor = calmedGapColor(l, window: bar.window)
        // Under the stub the gap is pinned to `0…frozen` (and the marker parks at its end), so the
        // Pace & Time anatomy stays intact while nothing but the colour moves.
        let frozen = frozenStrip(for: bar)
        let gapFrom = frozen != nil ? 0 : l.gapStart
        let gapTo = frozen ?? l.gapEnd
        // The gap's left edge is `usage` — pinned, so a gap narrower than the min-width floor grows
        // rightwards instead of bleeding colour back over the already-spent zone (#323). Not applied
        // under the stub, whose pinned `0…frozen` span is a ribbon from the origin.
        fillZone(from: gapFrom, to: gapTo, in: rect, width: w, color: gapColor, pinsStart: frozen == nil)

        NSGraphicsContext.restoreGraphicsState()

        // Time-indicator marker at timeFraction (drawn on top, unclipped so it stands proud).
        // The marker takes the EXACT colour of this state's pacing gap (`calmedGapColor`) — one tone
        // per pacing status, so the "you are here" tick reads as the same colour as the zone it marks.
        drawTimeMarker(at: frozen ?? l.timeFraction,
                       colour: calmedGapColor(l, window: bar.window, part: .marker),
                       in: rect)
    }

    /// The **Gauge** centre tick (#326, ADR-0079): a permanent 1 pt vertical mark at the bar's
    /// midpoint, in the neutral tick tone, drawn **under** the track so only its protruding ends
    /// show.
    ///
    /// Deliberately *not* built on ``drawTimeMarker(at:colour:in:)`` despite the similar shape — the
    /// semantics are opposite, and every difference here is doing work. That marker is data (it moves
    /// with `timeFraction`, takes the pacing colour, and sits on top with a `.copy` reset and flanking
    /// outline); this is a fixed rule of the scale. Drawing it under the track in grey at a fifth the
    /// width is what stops a lone vertical mark on a 34 pt bar from reading as Progress's marker —
    /// the objection that kept ticks out of the menu bar entirely under Pressure (see
    /// `PopupBarView.tickFractions`). It is drawn in **every** Gauge state, idle included: a direction
    /// needs something to be a direction from.
    private func drawCentreTick(in rect: NSRect) {
        let cx = PopupBarView.scaleX(0.5, in: rect).rounded()
        let w = Metrics.centreTickWidth
        let h = Metrics.tickHeight
        // Neutral `centreTick` (secondaryLabelColor) — never a pacing colour: this is scale furniture,
        // not data. Its own role rather than the marker's ring or the popup ruler's tick, both of
        // which sit dimmer: those only ever separate or annotate shapes that are already visible,
        // whereas this is the sole landmark the whole reading is relative to.
        Palette.centreTick.setFill()
        NSRect(x: cx - w / 2, y: rect.midY - h / 2, width: w, height: h).fill()
    }

    /// The time-indicator marker: a slim, lightly-rounded vertical bar rather than a dot — reads as a
    /// crisp position tick, standing proud of the bar on both sides.
    ///
    /// Factored out because **idle draws it too** (#307): under Progress the marker is what identifies
    /// the style, so an idle bar without it is indistinguishable from a Pressure bar at full pressure.
    /// There `fraction` is 0 — the window has just rolled, so no time has elapsed.
    private func drawTimeMarker(at fraction: Double, colour: NSColor, in rect: NSRect) {
        let cx = PopupBarView.scaleX(CGFloat(fraction), in: rect)
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
        colour.setFill()
        marker.fill()
        // Edge outline only where the marker overlaps the bar (`quaternaryLabelColor`): two short vertical
        // strokes down the marker's left and right edges, clipped to the bar's height — the parts of the
        // marker that stand proud above/below the bar carry no outline.
        strokeMarkerEdges(markerRect, in: rect, width: Metrics.tickStroke)
    }

    /// The pacing-gap fill colour, with calm mode (#105) applied. Normally this is the on-pace green
    /// or the graded ahead colour (`PopupBarView.aheadColor`). When `calmColorMode.mutesCalm` is on, the **calm**
    /// states (`BarLayout.isCalm`: on-pace green + mild-ahead yellow) mute to white; the strong warnings
    /// (orange/red) stay coloured.
    ///
    /// `window` identifies which bar this is, so the transition registry can keep the 5-hour and
    /// 7-day fades apart; `part` separates the strip from the time marker (they share a colour but
    /// are resolved at different points in the draw). The animator wraps the **final** tone — after
    /// `bright()`/`accent()` and after the calm decision — so the "coloured → calm neutral" switch
    /// fades too, and the ADR-0059 alpha/desaturation rules stay untouched.
    private func calmedGapColor(_ l: BarLayout, window: LimitWindow, part: BarPart = .fill) -> NSColor {
        animated(gapColorTarget(l), window: window, part: part)
    }

    /// The bar's pacing colour for the current state, **before** the transition layer.
    private func gapColorTarget(_ l: BarLayout) -> NSColor {
        // Calm neutral is a bright tone (labelColor at the text opacity, via `bright`); the coloured
        // pacing gap is an accent (scaled by accentSaturation). Neither is the dimmed bar track.
        // When `mutesBlue` is off (the old "Work harder") the far-behind blue is exempt from muting so
        // a big surplus stays coloured.
        if calmColorMode.mutesCalm && l.isCalm && !(l.severity == .farBehind && !calmColorMode.mutesBlue) {
            return bright(Palette.calmWhite)
        }
        if l.pacing == .ahead {
            return accent(PopupBarView.aheadColor(
                usage: l.usageFraction, time: l.timeFraction, remainingSeconds: l.remainingSeconds))
        }
        // Calm side: the menu bar only carries base 5h/7d bars, so split green↔blue unconditionally.
        return accent(PopupBarView.behindColor(l))
    }

    /// Route a bar colour through the transition layer (ADR-0070), or return it unchanged when no
    /// animator is attached (the dev-tools preview renders without one).
    private func animated(_ target: NSColor, window: LimitWindow, part: BarPart) -> NSColor {
        guard let colorAnimator else { return target }
        return colorAnimator.resolve(
            .bar(surface: .menuBar, row: window.id, part: part), target: target)
    }

    /// Whether this strip is rendering the **yellow** (mild-lead) pacing colour, and so wants the
    /// transparent gutter beneath it (#326).
    ///
    /// Returns `false` outright under calm colours: `mutesCalm` folds yellow into `calmWhite`, so there
    /// is no yellow left to rescue and cutting the track would only punch a hole under a neutral strip.
    /// Otherwise the *rendered* colour is compared against the live `.yellow` role — it has already been
    /// through the animator, so a mid-transition frame correctly counts as not-yet-yellow. Both sides
    /// are converted into one colour space first; a dynamic catalogue colour never compares equal to a
    /// resolved one directly.
    private func isYellow(_ colour: NSColor) -> Bool {
        guard !calmColorMode.mutesCalm else { return false }
        guard let a = colour.usingColorSpace(.sRGB),
              let b = ColorStore.shared.color(.yellow).usingColorSpace(.sRGB) else { return false }
        let tolerance = 0.02
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// Fill the coloured strip spanning the fraction range `[from, to)` of a bar as a rounded capsule.
    /// Shares `PopupBarView`'s inset-scale geometry: the span is mapped through the same `minStripWidth/2`
    /// inset and floored to a minimum width, so a near-zero span reads as a rounded "pill" (rounded on
    /// both ends) instead of a hairline, and its cap never overhangs the rounded track — matching the
    /// popup exactly. An end reaching the track's own edge snaps flush to it, so no grey sliver shows
    /// before the fill. `width` is unused now (the map reads `rect.width`); kept for call-site symmetry.
    /// `floorEmptyToPill` keeps an **exactly empty** span visible as the same min-width pill a hair-thin
    /// span already draws — used by the markerless (Simple/Mixed) ribbon, where the strip is the bar's
    /// only mark and `nil` would blank the widget. Off by default so Pace & Time's empty gap stays empty.
    /// `pinsStart` forwards to ``PopupBarView/stripRect(from:to:in:pinsStart:)`` and is set by the
    /// Progress gap, whose left edge is `usage` and so must not drift leftwards under the marker (#323).
    private func fillZone(from: Double, to: Double, in rect: NSRect, width: CGFloat, color: NSColor,
                          floorEmptyToPill: Bool = false, pinsStart: Bool = false,
                          anchoredAt anchor: Double? = nil) {
        let span = floorEmptyToPill && to <= from
            ? PopupBarView.pillRect(at: anchor ?? from, in: rect)
            : PopupBarView.stripRect(from: from, to: to, in: rect, pinsStart: pinsStart,
                                     anchoredAt: anchor)
        guard let stripRect = span else { return }
        // The strip takes the TRACK's corner radius, not a capsule's. `min(w,h)/2` rounds a 5 pt-tall
        // strip to 2.5 pt — visibly rounder than the `barCorner` 1.5 pt track it sits in, so a full-width
        // ribbon bulged past the track's own corners and a short one read as a lozenge on a rectangle.
        // Two shapes in one bar should share one corner. The popup keeps its capsule: there the bar is
        // 6 pt and the strip genuinely is a pill (`PopupBarView.draw`).
        let r = min(Metrics.barCorner, min(stripRect.width, stripRect.height) / 2)
        // Knock a transparent gutter out of the grey track under a **yellow** strip (#326), mirroring
        // the popup: yellow is the one pacing colour close enough in luminance to the track to lose its
        // edge against it, so the wallpaper is let through on either side to separate the two. Narrower
        // here (1.25 pt) than the popup's 1.5, in proportion to the shorter 5 pt bar.
        //
        // `.clear` with `.copy` REPLACES the track's pixels rather than blending over them — plain
        // `.sourceOver` of a clear colour is a no-op. `drawBar` has already clipped to the rounded bar,
        // so the cut cannot escape it; the state is saved anyway so `.copy` never leaks into the fill.
        if isYellow(color) {
            let gutter = stripRect.insetBy(dx: -Metrics.yellowGutter, dy: 0)
            let gr = min(r, min(gutter.width, gutter.height) / 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(roundedRect: gutter, xRadius: gr, yRadius: gr).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        color.setFill()
        NSBezierPath(roundedRect: stripRect, xRadius: r, yRadius: r).fill()
    }

    /// Draw the reset countdown text, centred inside its reserved slot (#303).
    ///
    /// `slotX` is the slot's **left edge**, not the text's: the slot is a fixed ``resetLabelSlot`` wide
    /// whatever the label says, and the text is centred in it, so the spare space splits evenly either
    /// side. Left-aligning would pile all of it against the item's right edge and read as the label
    /// having come unstuck from it; right-aligning would pile it into the gap after the bars instead.
    private func drawResetLabel(_ reset: String, slotAt slotX: CGFloat, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.resetLabelFont,
            .foregroundColor: bright(Palette.foreground),   // labelColor at the system text opacity
        ]
        let label = NSAttributedString(string: reset, attributes: attrs)
        let size = label.size()
        // Rounded to a whole point so the glyphs stay on the pixel grid — a half-point origin renders
        // the text softer than the bars beside it.
        let x = slotX + ((resetLabelWidth(reset) - size.width) / 2).rounded()
        label.draw(at: NSPoint(x: x, y: rect.minY + (rect.height - size.height) / 2))
    }

    /// Draw the blocked-state countdown **alone** (#194) — no bars, just the reset label at the left
    /// inset, vertically centred. Reuses the same monospaced-digit font and foreground colour as
    /// ``drawResetLabel(_:slotAt:in:)`` so the countdown looks identical whether or not the bars are
    /// hidden; `itemWidth` reserves the same fixed slot (via ``resetLabelWidth(_:)``) the bars mode does,
    /// so the item keeps its width as the digit count changes (#303). The blocked mode carries no pacing
    /// colour to mute, so `calmColorMode` is irrelevant here — the label is always the neutral foreground.
    ///
    /// When `layout.blockedPause` is set (fully blocked), the red pause glyph is drawn first, then the
    /// credits icon (when present), and the countdown shifts right past them — the same leading pattern
    /// the bars use in ``drawExpanded``, so the pause icon appears whether or not the bars are hidden
    /// (#199, #227). Order: pause → credits → countdown.
    private func drawBlockedReset(_ reset: String, in rect: NSRect) {
        let originX = drawLeadingDecorations(in: rect)
        drawResetLabel(reset, slotAt: originX, in: rect)
    }

    // MARK: Helpers

    /// The item width for a given layout — narrow for the glyph-only error/cold-start case, wider for
    /// the bars + label, widest for the ⚠️ + stale-bars phase (the glyph adds its own width). Driven
    /// dynamically so the item hugs exactly the content currently drawn.
    private func itemWidth(for layout: MenuBarLayout?) -> CGFloat {
        // The service dot (#31) is always a **trailing** inset (dot + gap). The money-credits icon (#144)
        // is a **leading** inset in the bars modes (between the pause glyph and the bars, #227) but a
        // **trailing** inset in the diagnostic `.error`/cold-start states (no leading sequence there).
        let dotInset = layout?.serviceProblem != nil ? Metrics.statusDotDiameter + Metrics.statusDotGap : 0
        let creditsInset = layout?.credits.map { creditsIconWidth(for: $0.currency) + Metrics.creditsIconGap } ?? 0
        // Leading red pause glyph (#199, #227) reserves its width + gap in both bars modes, mirroring the
        // origin shift in `drawLeadingDecorations`; zero when not fully blocked.
        let pauseInset = (layout?.blockedPause == true) ? pauseGlyphWidth() + Metrics.pauseGlyphGap : 0
        // Awaiting-input hand (#233) is the first leading element in the bars modes. Reserved from the
        // **option alone**, not from the live count (#283), so the widget keeps its width as sessions
        // start and stop waiting. Mirrors the origin advance in `drawLeadingDecorations`.
        let awaitingInset = reservesAwaitingSlot ? awaitingIconWidth() + Metrics.awaitingIconGap : 0
        // Leading decorations in the bars modes: awaiting hand → pause glyph → credits icon.
        let leadingInset = awaitingInset + pauseInset + creditsInset
        switch layout?.mode {
        case .none:
            // Cold start (no layout / `.error` reached via trailing credits): credits is trailing here.
            return Metrics.height + dotInset + creditsInset
        case let .expanded(_, _, resetToShow):
            return dotInset + Metrics.hPadding + leadingInset
                + barsBlockWidth(reset: resetToShow?.display) + Metrics.hPadding
        case let .blockedReset(reset, _):
            // No bars (#194): the item hugs the leading decorations (pause + credits) plus the countdown.
            return dotInset + Metrics.hPadding + leadingInset + resetLabelWidth(reset) + Metrics.hPadding
        case let .error(five, _, reset, _):
            // ⚠️ alone (cold start / >60 min) → compact; ⚠️ + stale bars (30–60 min) → glyph + bars.
            // Credits stays **trailing** in the error state (no leading pause sequence).
            guard five != nil, let reset else { return Metrics.height + dotInset + creditsInset }
            return dotInset + creditsInset + Metrics.hPadding + errorGlyphWidth() + Metrics.errorGlyphGap
                + barsBlockWidth(reset: reset) + Metrics.hPadding
        }
    }

    /// Width of the bars block + (optionally) its reset label (no outer padding) — shared by the
    /// expanded and error-with-bars widths so they stay in sync with
    /// ``drawBars(fiveHour:sevenDay:reset:originX:in:)``. A `nil` `reset` omits the label (and its
    /// leading gap), so the item hugs just the bars (ADR-0029); the error path always passes non-nil.
    private func barsBlockWidth(reset: String?) -> CGFloat {
        guard let reset else { return Metrics.barWidth }
        return Metrics.barWidth + Metrics.labelGap + resetLabelWidth(reset)
    }

    /// The font the reset countdown is both **measured** and **drawn** in. One constant rather than a
    /// literal at each site: the reserved slot (``resetLabelSlot``), the per-string measurement and the
    /// centring in ``drawResetLabel(_:slotAt:in:)`` must agree exactly, and a font that drifted between
    /// them would offset the text inside its own slot.
    private static let resetLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Width reserved for the reset label — the **widest** string the formatter can produce, so the
    /// item stops changing width as the digit count does (#303). Measured once, lazily, from
    /// ``resetLabelFont``, never hard-coded: a literal would silently stop matching the drawn text if
    /// the font or its size ever changed.
    ///
    /// Four probes cover the whole range because the font is monospaced-**digit**, so every digit is
    /// the same width — `00m`/`00h`/`00d` therefore stand in for every two-digit value, and `<1m` for
    /// the only non-digit form. Sweeping all of `1…49m` / `1…22h` / `1…30d` yields the identical
    /// number (24 pt) at ~500× the cost, so the probes are the whole set, not a sample of it.
    ///
    /// Independent of display scale: text metrics are in **points**, so the backing scale factor
    /// (1×/2×/3×) changes rasterisation, not width — verified identical across all three. Nothing to
    /// recompute when the widget moves between a Retina and a non-Retina screen.
    private static let resetLabelSlot: CGFloat = ["<1m", "00m", "00h", "00d"]
        .map { measuredResetLabelWidth($0) }
        .max() ?? 24

    /// Width the reserved slot gives a reset label. Constant at ``resetLabelSlot`` across every label
    /// (#303) — `10h` → `9h` used to shrink the item by 7 pt, and the menu bar is right-aligned, so
    /// every such swing shifted other apps' status items.
    ///
    /// `max` rather than the bare slot as a guard against silent clipping: a future formatter change or
    /// a longer-horizon window could produce a string wider than the probes above, and this widens the
    /// item — today's behaviour — instead of cutting the glyph off. No live case reaches it: a blocked
    /// countdown resolves through `BlockingReset.forBlocked`, which needs *every* window exhausted, and
    /// the 7-day window resets within 7 days (`7d`, 14 pt); even a credits/monthly reset tops out at
    /// `30d` (21 pt).
    private func resetLabelWidth(_ reset: String) -> CGFloat {
        max(Self.resetLabelSlot, Self.measuredResetLabelWidth(reset))
    }

    /// Rendered width of a reset label in ``resetLabelFont`` — the exact font ``drawResetLabel`` draws
    /// it in. Rounded up so sub-pixel widths never clip the last glyph.
    private static func measuredResetLabelWidth(_ reset: String) -> CGFloat {
        ceil((reset as NSString).size(withAttributes: [.font: resetLabelFont]).width)
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

    /// Rendered width of the red pause glyph at ``Metrics/pauseGlyphSize`` — measured the same way it is
    /// drawn so the reserved width in ``itemWidth(for:)`` matches ``drawPauseGlyph(atX:in:)`` exactly.
    /// Falls back to the glyph point size if the symbol is unavailable (a tiny over-reservation, never
    /// a clip — consistent with `drawPauseGlyph` omitting the glyph in that case).
    private func pauseGlyphWidth() -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.pauseGlyphSize, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return ceil(symbol?.size.width ?? Metrics.pauseGlyphSize)
    }

    /// The reserved width of the awaiting-input `hand.raised` icon (#233), measured the same way it is
    /// drawn — so `itemWidth` reserves exactly what `drawAwaitingIcon` paints.
    private func awaitingIconWidth() -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.awaitingIconSize, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return ceil(symbol?.size.width ?? Metrics.awaitingIconSize)
    }
}
