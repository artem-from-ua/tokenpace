import AppKit
import TokenPaceKit

/// The single point size for **every** piece of text in the dropdown menu — the popup's own labels
/// (`PopupViewController`) and the native menu items below it ("Settings…"/"Troubleshoot…", "Quit…"
/// in `App.swift`, pinned to this via `attributedTitle`). One shared constant instead of two
/// independently-tuned values, so the two can never visually drift apart again (see git history:
/// `NSFont.menuFont(ofSize: 0)` and an empirically-picked 16 pt both mismatched the native items —
/// there is no reliable way to *read* AppKit's real menu-item size, so instead both sides are forced
/// to *write* the same one). `NSFont.systemFontSize` (13 pt) is the documented default UI text size.
let dropdownTextSize: CGFloat = NSFont.systemFontSize

// MARK: - PopupBarView

/// A pacing bar drawn inside the popup, in the **same** three-zone style as the menu-bar widget:
/// used (grey) → pacing gap (green/red) → future (teal), with a time-indicator dot. The geometry
/// is a `BarLayout` from `PacingModel`; the colours are the fixed statusline palette (ADR-0005),
/// kept in sync with `StatusItemView` by mirroring the same sRGB values.
final class PopupBarView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed with a clear backing so `.clear`-composited cuts (the gaps flanking the coloured
        // gap and around the marker) become genuinely transparent holes — the card plate shows through
        // them — rather than painting black (which a non-layer-backed view would do). #188 follow-up.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

    /// Whether this is the **idle** 5-hour bar (#100, ADR-0027): a solid-blue knobless track (no pacing
    /// zones, no time-indicator dot) for a 5h window with no active session. The under-bar tick ruler
    /// still draws (`subdivisions`), keeping the row's anatomy in family with the active bars.
    var idle: Bool = false {
        didSet {
            guard idle != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether this idle bar is **blocked** (#158): the 7-day limit is exhausted and paid credits cannot
    /// cover, so the solid track is drawn **grey** (`monochromeGrey`) instead of the "ready" blue —
    /// "waiting for a limit to reset", not "ready to start". Only meaningful alongside ``idle``.
    var blocked: Bool = false {
        didSet {
            guard blocked != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether this is a **base** 5h/7d limit row (as opposed to a per-model/per-service row or the
    /// credits bar). Only base bars render the far-behind **blue** zone (``behindColor``); everything
    /// else keeps the plain green on the calm side. Set from the row-build loop; the raw
    /// `addBar(bar:…)` path (credits) leaves it `false`.
    var isBaseLimit: Bool = false {
        didSet {
            guard isBaseLimit != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Bar presentation style (#224). ``BarStyle/pacing`` draws the gap + time-indicator marker + gap
    /// dividers; ``BarStyle/simple`` draws a left-anchored ribbon coloured by the pacing state and keeps
    /// the under-bar tick ruler, but no marker or dividers. Pushed in from `PopupViewController.addBar`.
    /// Mirror of `StatusItemView.barStyle` — keep the two draw paths in sync. Default `.progress`.
    var barStyle: BarStyle = .progress {
        didSet {
            guard barStyle != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether the under-bar tick ruler is drawn (#224). Pushed in from `PopupViewController.addBar`.
    /// Default `true`.
    var showTicks: Bool = true {
        didSet {
            guard showTicks != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Drives the smooth colour transitions (ADR-0070), shared with the menu-bar widget. The
    /// animation state lives in the animator, **not** here: `PopupViewController.rebuild()` discards
    /// and recreates every bar view on each update, so anything kept on the view would be lost on
    /// the very next poll. `nil` renders every colour at its target (the old, instant behaviour).
    weak var colorAnimator: ColorAnimator?

    /// This bar's identity in the transition registry — `LimitRow.title` for a limit window, or
    /// `nil` for the credits bar, which has no row and keys on ``TweenKey/credits(surface:part:)``.
    /// Keyed by name rather than by position because per-model rows come and go, which would
    /// otherwise hand a vanishing row's in-flight fade to its neighbour.
    var tweenRow: String?

    /// Pins the coloured strip to this fraction of the track for the `color-cycle` stub, so only the
    /// colour changes on screen. Mirrors `StatusItemView.frozenStripFraction`; `nil` everywhere else.
    var frozenStripFraction: Double?

    private enum Metrics {
        /// Height of the pacing bar itself (the coloured zones + indicator dot).
        static let barHeight: CGFloat = 6
        static let corner: CGFloat = 2
        /// Width of the time-indicator marker — a slim vertical bar, narrower than the old dot so it
        /// reads as a crisp position tick rather than a blob.
        static let indicatorWidth: CGFloat = 7
        /// Height of the time-indicator marker — taller than the bar (≈2×) so it reads clearly as the
        /// primary time marker, standing proud above and below the pacing zones.
        static let indicatorHeight: CGFloat = 14
        /// Corner radius of the time-indicator marker (lightly rounded, matching the bar corners).
        static let indicatorCorner: CGFloat = 2
        /// Width of each flanking edge-outline stroke on the marker/bar intersection (`quaternaryLabelColor`).
        static let indicatorStroke: CGFloat = 2
        // Tick ruler, drawn *below* the bar like an axis (issue #38, "under-bar ruler" style). Made
        // more prominent (2×5) in #224 so the marks read clearly against the dimmer popup track.
        static let tickLength: CGFloat = 5
        static let tickGap: CGFloat = 2
        static let tickWidth: CGFloat = 2
        /// Total view height: tall enough for the bar + under-bar tick ruler **and** for the marker,
        /// which is centred on the bar and so overhangs it by `indicatorHeight/2 − barHeight/2`
        /// on top; without that headroom a taller marker would be clipped by the view's frame.
        static let height: CGFloat = max(
            barHeight + tickGap + tickLength,
            indicatorHeight + tickGap + tickLength)
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
    @MainActor
    private enum Palette {
        /// Pacing gap colours — the unified semantic hues shared with the menu bar. Green (on pace) is
        /// `.systemGreen`; the ahead-of-pace grade is `.systemYellow` (mild lead) → `.systemOrange`
        /// (strong lead) → `.systemRed` (exhausted), via `aheadColor`.
        static var gapGreen: NSColor { ColorStore.shared.color(.green) }
        /// The **idle** 5-hour bar's solid fill (#100, ADR-0027): the 5h window has no active session, so
        /// the bar is a knobless solid track meaning "ready to start, full quota available" — plain
        /// `.systemBlue`, the appearance-aware pair to the on-pace green; the unified `blue` role, so it
        /// flips light/dark like the native icons and matches the menu-bar idle bar exactly.
        static var idleBlue: NSColor { ColorStore.shared.color(.blue) }
        static var gapRed: NSColor { ColorStore.shared.color(.red) }
        static var gapYellow: NSColor { ColorStore.shared.color(.yellow) }
        static var gapOrange: NSColor { ColorStore.shared.color(.orange) }
        /// The **far-behind** pacing gap (deep behind pace / big surplus) on the base 5h/7d bars —
        /// `.systemBlue` via the dedicated `paceBlue` role (distinct from the idle-bar `blue`). Chosen
        /// by `behindColor` when the surplus is above the dynamic behind-threshold; otherwise green.
        static var gapBlue: NSColor { ColorStore.shared.color(.paceBlue) }

        /// Indicator-dot ring: a soft separation between the dot and the bar beneath it. `separatorColor`
        /// — the unified `indicatorRing` role, the same semantic hairline the menu-bar ring uses.
        static var indicatorStroke: NSColor { ColorStore.shared.color(.indicatorRing) }

        /// Tick-ruler marks below the bar: `tertiaryLabelColor` (the `.tick` role) — a muted neutral that
        /// flips light/dark and reads weaker than the indicator dot.
        static var tick: NSColor { ColorStore.shared.color(.tick) }

        /// The monochrome base-zone grey (the bar's `used` + future/unused zones). **Popup-only**: a tone
        /// **half-way between** `tertiaryLabelColor` and the dimmest `quaternaryLabelColor` — dimmer than
        /// the menu bar's `barTrack` (`labelColor@0.22`) so the popup track recedes into the NSMenu
        /// material, but not as dark as full quaternary (#224). The menu-bar widget keeps its own
        /// `barTrack` tone unchanged — only this popup surface is quieter.
        ///
        /// A **dynamic** `NSColor(name:)` whose blend is computed **inside**
        /// `performAsCurrentDrawingAppearance`, so it re-resolves per appearance and flips light/dark —
        /// exactly like ``PopupViewController/defaultDimmedLabel``. A plain `.blended(...)` (even from a
        /// computed `var`) bakes in whatever appearance was current at the call site: under an NSMenu-hosted
        /// view the drawing appearance is not reliably current when `draw()` reads it, so the light theme
        /// rendered the dark tone (and vice-versa). `blended` returns non-nil for these dynamic label
        /// colours in a real drawing context; the `?? tertiary` fallback keeps it total.
        static let monochromeGrey = NSColor(name: nil) { appearance in
            var mixed: NSColor = .tertiaryLabelColor
            appearance.performAsCurrentDrawingAppearance {
                mixed = NSColor.tertiaryLabelColor.blended(withFraction: 0.5, of: .quaternaryLabelColor)
                    ?? .tertiaryLabelColor
            }
            return mixed
        }
    }

    // MARK: - Shipped colour defaults

    // The one remaining per-appearance provider backing `ColorRole.defaultColor`. The semantic hues and
    // greys are now plain system/semantic colours resolved directly in `ColorRole.defaultColor`; only
    // `defaultDimmedLabel` (below) still computes a per-appearance blend, so it stays a provider.

    /// The grey both bar base zones (`used` + future/unused tail) render in — the **popup-only** tone
    /// half-way between tertiary and quaternary label (quieter than the menu bar's `barTrack`), where
    /// only the pacing gap + dot carry colour. Backed by the **dynamic** `Palette.monochromeGrey`
    /// provider, which resolves its blend per appearance (so it flips light/dark correctly). Menu-bar
    /// `drawBar` reads it live the same way.
    static var monochromeGrey: NSColor { Palette.monochromeGrey }

    /// The exhausted-pacing red (`aheadColor`'s cap rung). Exposed so the popup can paint the **one**
    /// blocking reset time red (#158) in the same tone the bars use for an exhausted limit. Computed (not
    /// a `static let`) for the same appearance-freshness reason as ``monochromeGrey``.
    static var gapRed: NSColor { Palette.gapRed }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height) }

    override func draw(_ dirtyRect: NSRect) {
        // The bar sits below a top margin equal to the marker's overhang — the marker is centred on
        // the bar, so a marker taller than the bar sticks out by `(height − barHeight)/2` on each side;
        // the margin keeps that top overhang inside the view (the tick ruler fills the strip below).
        let overhang = max(0, (Metrics.indicatorHeight - Metrics.barHeight) / 2)
        let rect = NSRect(
            x: bounds.minX, y: bounds.minY + overhang, width: bounds.width, height: Metrics.barHeight)

        // Idle 5h bar (#100, ADR-0027): no pacing zones, "no active session, full quota available".
        // Rendered before the pacing path so the (inert, zeroed) `bar` layout is never consulted.
        //
        // The shape follows the **style**, so idle cannot be mistaken for a pacing state (#307):
        // - **Progress** — the solid track, plus the time marker parked at the left edge. Idle means
        //   the window has just rolled, so `timeFraction` is 0 and the marker belongs at zero. Without
        //   it a Progress idle bar is indistinguishable from a Pressure bar reading "full pressure".
        // - **Pressure** — the minimum pill, the same shape any zero-length ribbon draws. On the
        //   renormalised track idle *is* zero pressure, so a full-width fill would be the loudest
        //   possible mark for the calmest possible state.
        if idle {
            // Blocked idle (#158) → grey (no path to start); otherwise the "ready to start" blue.
            // Grey (blocked) is an already-translucent neutral — leave it; only the blue hue is tinted (#188).
            // Animated so idle→active reads as a fade (ADR-0070); the glow follows automatically
            // because it is derived from this same colour.
            let idleColor = blocked ? Self.monochromeGrey : animated(Palette.idleBlue, part: .fill)
            // Under Pressure the mark is a pill, so the grey track has to go down first — exactly as
            // the pacing path does. Without it the pill hangs in empty space while every neighbouring
            // row shows a track. Progress fills the whole width, so there the fill *is* the track.
            if barStyle.popupUsesPressureScale {
                Self.monochromeGrey.setFill()
                NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner).fill()
            }
            let idleShape = barStyle.popupUsesPressureScale
                ? Self.pillRect(at: 0, in: rect)
                : rect
            if let idleShape {
                let corner = barStyle.popupUsesPressureScale
                    ? min(idleShape.width, idleShape.height) / 2      // capsule, like any pill
                    : Metrics.corner
                let idlePath = NSBezierPath(roundedRect: idleShape, xRadius: corner, yRadius: corner)
                if blocked {
                    idleColor.setFill()
                    idlePath.fill()
                } else {
                    // The idle strip carries the same ambient glow as a pacing strip (#188),
                    // with the same parameters — one halo treatment across every strip.
                    withGlow(idleColor, radius: Self.gapGlowRadius, strength: Self.gapGlowStrength) {
                        idleColor.setFill()
                        idlePath.fill()
                    }
                }
            }
            drawTicks(in: rect)
            // Progress keeps its identifying mark even here: the marker sits at `timeFraction` = 0.
            if barStyle.popupShowsTimeMarker { drawTimeMarker(at: 0, colour: idleColor, in: rect) }
            return
        }

        guard let l = bar else { return }

        // Pacing-gap colour, routed through the transition layer so a threshold crossing fades
        // instead of blinking (ADR-0070).
        let gapColor = animated(gapColorTarget(l), part: .fill)

        // 1. Full-length grey track (rounded), drawn first as the base.
        Self.monochromeGrey.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner).fill()

        // 2. Coloured strip laid exactly over its span, both ends fully rounded (capsule). Progress uses
        //    the gap `gapStart..gapEnd` on the window scale; Pressure uses a left-anchored ribbon
        //    `0..pressureLength` on the renormalised `[now..reset]` scale (#307). A flush end rounds
        //    identically to the grey bar's own cap, so it reads as one continuous rounded edge.
        //    3. The strip carries the ambient glow.
        // The `color-cycle` stub pins the strip so only the colour moves (`frozenStripFraction`); it
        // overrides the length, so the stub is unaffected by the rescale.
        let stripFrom = frozenStripFraction != nil ? 0 : (barStyle.popupShowsTimeMarker ? l.gapStart : 0)
        let stripTo = frozenStripFraction ?? (barStyle.popupShowsTimeMarker ? l.gapEnd : l.pressureLength)
        // A **zero-length** Pressure ribbon still has to read as "zero", not as an empty track: with no
        // marker the ribbon is this bar's only mark, and `stripRect` returns nil for a degenerate span.
        // `usage == time` is a real recurring state (every 5-hour reset renders 0 % against a freshly
        // rolled `resets_at`), so floor it to the pill — mirroring `StatusItemView`'s
        // `fillZone(floorEmptyToPill:)`, which has always done this in the menu bar. Progress is
        // deliberately excluded: there an empty gap means "dead on pace" and the marker carries the
        // position.
        // Progress pins the strip's start: its left edge is `usage`, so the min-width floor and the
        // flush-to-track snap must not drag it leftwards into the "already spent" zone (#323).
        let span = Self.stripRect(from: stripFrom, to: stripTo, in: rect,
                                  pinsStart: frozenStripFraction == nil && barStyle.popupShowsTimeMarker)
            ?? (barStyle.popupUsesPressureScale ? Self.pillRect(at: stripFrom, in: rect) : nil)
        if let stripRect = span {
            let capsule = min(stripRect.width, stripRect.height) / 2
            let stripPath = NSBezierPath(roundedRect: stripRect, xRadius: capsule, yRadius: capsule)
            withGlow(gapColor, radius: Self.gapGlowRadius, strength: Self.gapGlowStrength) {
                gapColor.setFill()
                stripPath.fill()
            }
        }

        drawTicks(in: rect)

        // Simple style (#224): no time marker — the ribbon above already conveys pacing by colour + length.
        if !barStyle.popupShowsTimeMarker { return }

        // 4. Time-indicator marker at `timeFraction`. 5. It carries a stronger ambient glow.
        // Under the `color-cycle` stub the marker parks at the pinned strip's end, so Progress keeps
        // its full anatomy (strip + marker) while still holding the geometry still.
        drawTimeMarker(at: frozenStripFraction ?? l.timeFraction, colour: indicatorColor(l), in: rect)
    }

    /// The time-indicator marker: a slim rounded vertical bar in `colour`, with a border in the
    /// grey-track tone that separates it from the strip underneath.
    ///
    /// Factored out because **idle draws it too** (#307): under Progress the marker is the mark that
    /// identifies the style, so an idle bar without it would read as a Pressure bar at full pressure.
    /// There `fraction` is 0 — the window has just rolled, so no time has elapsed.
    ///
    /// Pixel-snaps the centre x so the vertical edges land on whole pixels; a fractional scaled x
    /// otherwise smears the thin border across two columns (the "crooked outline").
    private func drawTimeMarker(at fraction: Double, colour: NSColor, in rect: NSRect) {
        let cx = Self.scaleX(CGFloat(fraction), in: rect).rounded()
        let cy = rect.midY
        let mw = Metrics.indicatorWidth
        let mh = Metrics.indicatorHeight
        let markerRect = NSRect(x: cx - mw / 2, y: cy - mh / 2, width: mw, height: mh)
        let marker = NSBezierPath(
            roundedRect: markerRect, xRadius: Metrics.indicatorCorner, yRadius: Metrics.indicatorCorner)
        // Border as a filled frame (not a centred stroke, which straddles the edge and reads crooked on a
        // 6-pt marker): fill the outer rounded rect in the grey-track-toned border colour, then fill an
        // inset rounded rect in the marker colour on top — leaving a crisp `bw`-wide even border. The whole
        // thing carries the ambient glow.
        let bw: CGFloat = 1
        let border = (Self.monochromeGrey.blended(withFraction: 0.4, of: colour) ?? Self.monochromeGrey)
            .withAlphaComponent(0.9)
        let innerRect = markerRect.insetBy(dx: bw, dy: bw)
        let inner = NSBezierPath(roundedRect: innerRect,
                                 xRadius: max(0, Metrics.indicatorCorner - bw),
                                 yRadius: max(0, Metrics.indicatorCorner - bw))
        withGlow(colour, radius: Self.markerGlowRadius, strength: Self.markerGlowStrength) {
            border.setFill()
            marker.fill()
            colour.setFill()
            inner.fill()
        }
    }

    // MARK: - Inset scale (min-strip geometry)

    /// The minimum width of the coloured strip — so a near-zero span renders as a rounded "pill"
    /// (a short capsule with fully-rounded ends) rather than a hairline sliver. Set to ¾ of the bar
    /// height, i.e. slightly shorter than a full circle (whose diameter would be the height).
    static func minStripWidth(_ rect: NSRect) -> CGFloat { 0.75 * rect.height }

    /// Map a fraction `f ∈ [0,1]` to an x inside the bar, with a symmetric inset (`minStripWidth/2`)
    /// on each end reserved for the min-strip's rounded caps. The 0..100 % scale therefore lives in
    /// `[minX+BS, maxX−BS]`, so the pill at 0 % (or 100 %) has its rounded end land flush *inside* the
    /// rounded track — never overhanging the track's cap. The tick ruler and time marker use the same
    /// map so they stay aligned with the strip.
    static func scaleX(_ f: CGFloat, in rect: NSRect) -> CGFloat {
        let bs = minStripWidth(rect) / 2
        return rect.minX + bs + f * (rect.width - 2 * bs)
    }

    /// The coloured strip's rect for the fraction span `from..to`, mapped through ``scaleX`` and
    /// floored to ``minStripWidth`` (expanded symmetrically about its centre) so a tiny non-zero span
    /// reads as a pill. An end that lands inside the inset band reserved by ``scaleX`` is snapped
    /// flush to the track's own end, so the strip's cap meets the track's cap with no grey sliver
    /// left between them. Returns `nil` for an empty span (`to <= from`) — nothing to draw.
    ///
    /// `pinsStart` marks the span's **left edge as meaningful data** rather than a mere ribbon origin,
    /// and is set by the Progress gap `gapStart..gapEnd`, whose left edge is `min(usage, time)` (#323).
    /// There everything left of the strip reads as "already spent", so neither the min-width floor nor
    /// the flush-to-track snap may move that edge leftwards.
    ///
    /// This is **not** a zero-spend special case: the floor fires on any gap narrower than `minStripWidth`
    /// — i.e. whenever spending tracks the clock closely — and expanding it about the centre always
    /// bleeds colour past `usage`. At `u = 0.40, t = 0.405` the strip started a full point left of the
    /// usage edge. `usage = 0` is merely where it is loudest, because the left cap then also lands inside
    /// the band snapped flush to `minX`, so the pill escapes from under the time marker (2.25 pt at
    /// `t = 0.005`) and paints green over a window in which nothing has been spent at all.
    ///
    /// With the pin the floor grows the strip to the **right** and the left snap is skipped, so the strip
    /// starts exactly at `usage`. A gap wider than the floor is untouched either way. Pressure's ribbon
    /// leaves the pin off: that span genuinely starts at the track's origin.
    static func stripRect(from: Double, to: Double, in rect: NSRect, pinsStart: Bool = false) -> NSRect? {
        var sx0 = scaleX(CGFloat(from), in: rect)
        var sx1 = scaleX(CGFloat(to), in: rect)
        guard sx1 > sx0 else { return nil }
        let msw = minStripWidth(rect)
        if sx1 - sx0 < msw {
            if pinsStart {
                // Grow rightwards only — the left edge is `usage` and must not drift under the marker.
                sx1 = sx0 + msw
            } else {
                let c = (sx0 + sx1) / 2
                sx0 = c - msw / 2
                sx1 = c + msw / 2
            }
        }
        // Snap an end that lands within the reserved cap band flush to the track. `scaleX` insets the
        // 0..100 % scale by `bs` on each side so a cap never overhangs the rounded track — but at the
        // track's own ends there is nothing to overhang (`drawBar`/`draw` clip the fill to the rounded
        // track anyway), and that inset reads as a grey sliver past the end of the fill.
        //
        // The test is "within the cap band", not "exactly at 0 % / 100 %": a full bar rarely maps to a
        // clean 1.0. In the menu bar's Simple/Mixed styles the strip is the ribbon `0..(gapEnd-gapStart)`,
        // so a 100 %-used window whose clock has barely moved yields `0.9987`, not `1` — close enough
        // that the leftover is pure inset, but too far for an equality test to catch.
        //
        // The band is the strip's own cap radius (half the bar height) rather than `bs`: the leftover at
        // `0.9987` is `bs` plus a sliver of scaled span, which just overshoots `bs` itself. Anything
        // thinner than a cap cannot read as a deliberate gap — it only reads as the fill missing the end.
        //
        // Applied after the min-width floor, which would otherwise push a snapped end back off the edge.
        //
        // Skipped on the left when `pinsStart`: there the leftover strip of track is not an inset
        // artefact but the "already spent" zone, which has to stay grey up to `usage` whatever `usage`
        // is. The right end still snaps — `gapEnd` reaching 100 % is a real full bar either way.
        let band = rect.height / 2
        if !pinsStart, sx0 - rect.minX <= band { sx0 = rect.minX }
        if rect.maxX - sx1 <= band { sx1 = rect.maxX }
        return NSRect(x: sx0, y: rect.minY, width: sx1 - sx0, height: rect.height)
    }

    /// The min-width pill for a **degenerate** (zero-length) span at fraction `f` — the shape
    /// ``stripRect(from:to:in:)`` produces for a hair-thin span, but for a span of exactly zero, where it
    /// returns `nil` instead. Same ``minStripWidth`` floor and same end-snapping, so a 0 % strip and a
    /// 0.3 %-strip are indistinguishable rather than one of them vanishing.
    ///
    /// Needed because `usage == time == 0` is a real, recurring state, not a rounding artefact: after
    /// every 5-hour reset `PollingEngine.applyIdleGrace`/`suppress` (ADR-0041, ADR-0045) hold a "ready"
    /// frame of 0 % against `resets_at = now + 5h` until the first token spend lands.
    static func pillRect(at f: Double, in rect: NSRect) -> NSRect? {
        let msw = minStripWidth(rect)
        let c = scaleX(CGFloat(f), in: rect)
        var sx0 = c - msw / 2
        var sx1 = c + msw / 2
        let band = rect.height / 2
        if sx0 - rect.minX <= band { sx0 = rect.minX }
        if rect.maxX - sx1 <= band { sx1 = rect.maxX }
        guard sx1 > sx0 else { return nil }
        return NSRect(x: sx0, y: rect.minY, width: sx1 - sx0, height: rect.height)
    }

    /// The fractions the tick ruler marks — chosen by the bar's **scale**, not by the data (#307).
    ///
    /// - **Progress** marks each interior window boundary (`k / subdivisions`): the hour lines of a
    ///   5-hour window, the day lines of a 7-day one. Those are real positions on the window scale,
    ///   and the time marker lands among them.
    /// - **Pressure** draws on the renormalised `[now .. reset]` track, where window subdivisions
    ///   have no position at all — an hour boundary is not at a fixed fraction of the time remaining.
    ///   What *is* fixed there is where the severity bands meet, so mark the one that matters:
    ///   **0.20 is exactly on pace** (`u == t`), at any point in the window (#307,
    ///   ``TokenPaceKit/BarLayout/pressureLength``). A ribbon short of the tick means headroom, past
    ///   it means a lead. One tooth, not a ruler — the other boundary (0.328, yellow→orange) is
    ///   already carried by the colour change, and a second tooth 4 pt away would read as noise.
    ///
    /// The menu bar gets no tick at all: a lone vertical tooth on a 34 pt bar is exactly what the
    /// Progress time marker looks like, so the two styles would stop being distinguishable there.
    ///
    /// Keyed off `barStyle` alone: `drawTicks` also runs for the **idle** bar, which has no
    /// `BarLayout` to consult.
    private var tickFractions: [CGFloat] {
        if barStyle.popupUsesPressureScale { return [0.20] }
        guard subdivisions >= 2 else { return [] }
        return (1 ..< subdivisions).map { CGFloat($0) / CGFloat(subdivisions) }
    }

    /// Draw the under-bar tick ruler: vertical teeth at each fraction in ``tickFractions``,
    /// pixel-snapped on x. No-op when there is nothing to mark.
    private func drawTicks(in barRect: NSRect) {
        guard showTicks else { return }                    // #224 — tick ruler opt-out
        let fractions = tickFractions
        guard !fractions.isEmpty else { return }
        let top = barRect.maxY + Metrics.tickGap           // flipped: just below the bar
        let bottom = top + Metrics.tickLength
        Palette.tick.setFill()
        // Rounded (capsule) teeth — corner = half the width so the ends read soft, not blocky.
        let corner = Metrics.tickWidth / 2
        for f in fractions {
            // Pixel-snap the tooth's centre so it stays crisp at @1x and @2x. Mapped through the same
            // inset scale as the coloured strip / marker so the ruler stays aligned with them (#…).
            let cx = Self.scaleX(f, in: barRect).rounded()
            let rect = NSRect(x: cx - Metrics.tickWidth / 2, y: top, width: Metrics.tickWidth, height: bottom - top)
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
        }
    }

    private func indicatorColor(_ l: BarLayout) -> NSColor {
        // The dot uses the exact pacing-bar colours so it reads as the same colour as the gap zone it
        // sits over, not a separate shade. A tie (usage == time) is still on pace → green/blue.
        let target: NSColor
        if l.usageFraction > l.timeFraction {
            target = Self.aheadColor(usage: l.usageFraction, time: l.timeFraction, remainingSeconds: l.remainingSeconds)
        } else {
            // Calm side: base 5h/7d bars split green↔blue via behindColor; per-model/credits stay green.
            target = isBaseLimit ? Self.behindColor(l) : Palette.gapGreen
        }
        return animated(target, part: .marker)
    }

    /// This bar's pacing colour for the current state, **before** the transition layer.
    private func gapColorTarget(_ l: BarLayout) -> NSColor {
        if l.pacing == .ahead {
            return Self.aheadColor(usage: l.usageFraction, time: l.timeFraction,
                                   remainingSeconds: l.remainingSeconds)
        }
        // Calm side: base 5h/7d bars split green↔blue via behindColor; per-model/credits stay green.
        return isBaseLimit ? Self.behindColor(l) : Palette.gapGreen
    }

    /// Route a colour through the transition layer (ADR-0070), or return it unchanged when no
    /// animator is attached (the dev-tools preview renders without one).
    private func animated(_ target: NSColor, part: BarPart) -> NSColor {
        guard let colorAnimator else { return target }
        let key: TweenKey = tweenRow.map { .bar(surface: .popup, row: $0, part: part) }
            ?? .credits(surface: .popup, part: part)
        return colorAnimator.resolve(key, target: target)
    }

    /// The gap/dot colour when **ahead of pace** (`usage > time`), graded by how far ahead — the same
    /// system colours the Claude status dots use:
    /// - limit exhausted (`usage >= 1`) → red (the worst; also where the bar is full)
    /// - window resets in `≤ 20 min` (`PacingModel.pacingOrangeOverrideSeconds`) → orange (no time left
    ///   to coast back onto pace, so any lead is worth flagging)
    /// - ahead by less than the dynamic threshold → yellow (mild)
    /// - ahead by `≥` the dynamic threshold → orange (worse)
    ///
    /// The threshold is `PacingModel.aheadThreshold(timeFraction:)` = `0.16 · (1 − time)` — 16 pts of
    /// slack early in a window, shrinking to 0 at the end. Shared with `BarLayout.severity` (Kit) so
    /// colour and severity never drift; the `< threshold` comparison is strict (a lead exactly at the
    /// threshold is orange).
    /// The ahead-of-pace grade, shared by both surfaces: they now resolve the same unified
    /// `red`/`yellow`/`orange` roles, so the menu-bar bar and popup bar always agree.
    static func aheadColor(usage: Double, time: Double, remainingSeconds: TimeInterval) -> NSColor {
        let red = ColorStore.shared.color(.red)
        let yellow = ColorStore.shared.color(.yellow)
        let orange = ColorStore.shared.color(.orange)
        if usage >= 1 { return red }
        if remainingSeconds <= PacingModel.pacingOrangeOverrideSeconds { return orange }
        return (usage - time) < PacingModel.aheadThreshold(timeFraction: time) ? yellow : orange
    }

    /// The calm-side (`usage <= time`) gap/dot colour — the mirror of ``aheadColor``, splitting the
    /// on-pace/behind range into **green** (mild) and **blue** (`farBehind`, deep behind / big surplus):
    /// - within the first 20 min of the window (`pacingBlueStartOverrideSeconds`) → green (blue must
    ///   not flicker at window start)
    /// - surplus (`time − usage`) `>` the fixed-width ``PacingModel/behindThreshold(windowDurationSeconds:)``
    ///   (60 min / 5h, 24 h / 7d) → blue
    /// - otherwise → green
    ///
    /// Takes the whole `BarLayout` (it carries `windowDurationSeconds`, needed for the start override)
    /// so this and Kit's `BarLayout.severity` compute the identical split and never drift. Restricted
    /// to base 5h/7d bars by the caller (`isBaseLimit`); per-model / credits rows stay green.
    static func behindColor(_ l: BarLayout) -> NSColor {
        let green = ColorStore.shared.color(.green)
        // `behindMultiplier == 0` (FarBehindInterval.off): blue is disabled — always green, any surplus.
        if l.behindMultiplier == 0 { return green }
        let elapsed = Double(l.windowDurationSeconds) - l.remainingSeconds
        if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return green }
        return (l.timeFraction - l.usageFraction) > PacingModel.behindThreshold(windowDurationSeconds: l.windowDurationSeconds, multiplier: l.behindMultiplier)
            ? ColorStore.shared.color(.paceBlue) : green
    }

    /// Glow radii (#188 follow-up): a soft coloured halo (ambient) behind the coloured pacing strip, the
    /// time marker, and the service-status dots so they lift off the card.
    /// Bar strip glow: a large, soft, low-intensity halo. The idle strip shares these parameters.
    private static let gapGlowRadius: CGFloat = 21
    private static let gapGlowStrength: CGFloat = 0.35
    /// Marker glow: a soft halo, kept subtle so the marker doesn't bloom over the card.
    private static let markerGlowRadius: CGFloat = 6
    private static let markerGlowStrength: CGFloat = 0.5

    /// Run `body` with a coloured drop-shadow (blur = `radius`, no offset) set as the current shadow, so
    /// whatever `body` fills gets a soft same-colour halo. Wrapped in a graphics-state save/restore so the
    /// shadow does not leak into later drawing.
    private func withGlow(_ color: NSColor, radius: CGFloat, strength: CGFloat, _ body: () -> Void) {
        guard radius > 0, strength > 0 else { body(); return }   // glow off — draw plainly, no shadow
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(min(1, strength))
        glow.shadowBlurRadius = radius
        glow.shadowOffset = .zero
        glow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - CardBackdropView

/// The Control-Center-style rounded "plate" behind the whole Claude section (#188). An inset, rounded
/// plate that floats above the popup background — the native `NSMenu` vibrancy material shows as a margin
/// around it (the popup is always translucent).
///
/// A flat, layer-backed fill using the dynamic `underPageBackgroundColor` system colour, which resolves to
/// a raised-surface tone in each theme automatically (dark ≈ #282828, light ≈ a mid grey) — so it adapts
/// to light/dark with no per-theme constants. (A `.behindWindow` `NSVisualEffectView` was tried first for
/// a wallpaper-tone "vibe", but inside the `NSMenu` it degrades to a flat control colour and shows no tint,
/// so a predictable flat fill is used instead.) Layer-backed with `updateLayer` (like `PillView`) so the
/// fill + border CGColors re-resolve on a theme flip; corner radius is set in both `updateLayer` and
/// `layout` so it survives resize.
final class CardBackdropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = PopupViewController.cardCornerRadius
        layer?.borderWidth = PopupViewController.cardBorderWidth
        layer?.backgroundColor = NSColor.cardPlateFill.cgColor
        layer?.borderColor = NSColor.cardPlateBorder.cgColor
        // Soft drop shadow so the plate reads as raised above the popup background (#188). `masksToBounds`
        // stays false (default) so the shadow is visible outside the rounded fill.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = PopupViewController.cardCornerRadius
    }
}

extension NSColor {
    /// The popup card's background **as the real `NSMenu` renders it on screen**, for surfaces outside a
    /// menu (the dev colour-tuner's "Popup Preview" window, #185). Inside the real menu the vibrancy
    /// material yields **#2C2C2C** in dark; the preview is a plain borderless window, where a
    /// `windowBackgroundColor` fill renders a visibly lighter **#414141**. In **light** the two already
    /// match exactly (#EFEFEF), so only the **dark** branch is overridden; light falls through to
    /// `windowBackgroundColor`.
    ///
    /// The dark value is sRGB **#212121** — the colour the real `NSMenu` popup shows, verified live with
    /// Digital Color Meter in **sRGB** mode (popup `0x212121`, this fill `0x212121`). It is darker than
    /// `windowBackgroundColor`, whose fill reads noticeably lighter here. Screenshots are not a reliable
    /// reference for this — `screencapture` colour-management shifts both surfaces so they look equal in
    /// the file while differing on the live display; the value was matched against the live sRGB meter, not
    /// a captured image. Dynamic (`NSColor(name:)`) so it re-resolves on a theme flip.
    static let popupMenuMatchedBackground = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(srgbRed: 0x21/255, green: 0x21/255, blue: 0x21/255, alpha: 1)
                      : .windowBackgroundColor
    }

    /// The thin light hairline a real `NSMenu` popup draws around its rounded edge, for the dev-tuner
    /// preview window which — being a plain borderless window — has no such system chrome. A subtle grey,
    /// darker than the card so it reads as an edge; dynamic so it tracks the theme.
    ///
    /// Deliberately **not** a `ColorRole` (audit #206): this hairline is **preview-only** chrome. The
    /// shipped popup lives inside an `NSMenu`, which draws its own edge — this border is never rendered
    /// in the real UI, so a tuner slider for it would only affect the preview window. Left as a fixed
    /// pair verified against dark/light: #4D4D4D dark, #C4C4C4 light.
    static let popupMenuBorder = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(srgbRed: 0x4D/255, green: 0x4D/255, blue: 0x4D/255, alpha: 1)
                      : NSColor(srgbRed: 0xC4/255, green: 0xC4/255, blue: 0xC4/255, alpha: 1)
    }

    /// Fill of the Control-Center-style section card (`CardBackdropView`, #188). `controlBackgroundColor`
    /// (light #FFFFFF, dark #1E1E1E) at **partial alpha**, so the `NSMenu` vibrancy material below the card
    /// shows through and lends the plate a subtle tone, while our chosen colour sits on top. (True
    /// wallpaper `.behindWindow` tint is impossible inside an NSMenu — the menu window is system-opaque —
    /// so this translucency over the menu's own material is the closest achievable "vibe".) `cardPlateAlpha`
    /// is the single knob for how much tone bleeds in.
    static var cardPlateFill: NSColor { NSColor.controlBackgroundColor.withAlphaComponent(cardPlateAlpha) }

    /// How opaque the section-card fill is; the remainder lets the layer below (menu material when #188 is
    /// on) tint the plate. 1.0 = fully our colour (no bleed); lower = more tone from below. Tunable.
    static let cardPlateAlpha: CGFloat = 0.85

    /// Hairline edge of the section card (`CardBackdropView`). A subtle border that reads on both the
    /// opaque and translucent backgrounds; dynamic so it tracks the theme.
    static let cardPlateBorder = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(white: 1, alpha: 0.10)
                      : NSColor(white: 0, alpha: 0.08)
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

// MARK: - SubscribeRowView

/// The episode subscribe/unsubscribe row (#279) — an icon carrying the **state** and secondary text
/// naming the **action**.
///
/// That split is deliberate. A bare toggle icon is ambiguous in the Play/Pause way: a struck-through
/// bell reads equally as "notifications are off" and as "press to turn them off". Pairing a state
/// icon with an action label removes the ambiguity, and the row is a wide, obvious click target in a
/// place where a lone glyph would not be.
///
/// Implemented as a plain `NSView` with `mouseDown`, not an `NSButton`. The popup is hosted in
/// `NSMenuItem.view`, where AppKit's control machinery has repeatedly failed this project — the
/// `.link` handling of `NSTextField` (ADR-0013 §4), native `isAlternate`, and
/// `addLocalMonitorForEvents` under menu tracking (ADR-0020 §3). `StatusLineLabel` proves `mouseDown`
/// does arrive, so this follows the technique already known to work here.
final class SubscribeRowView: NSView {

    /// Invoked on click. The controller owns what a click means; this view only reports it.
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// Tracks hover so the row can hint that it is interactive — in a surface with no other controls,
    /// nothing else signals clickability.
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbolName: String, text: String, filled: Bool) {
        super.init(frame: .zero)
        wantsLayer = true

        let config = NSImage.SymbolConfiguration(
            pointSize: PopupViewController.Metrics.textSize, weight: filled ? .semibold : .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)?
            .withSymbolConfiguration(config)
        // The icon carries the state, so it takes the full label colour when active and the dimmed
        // one when not — the same weight the text has in each state.
        iconView.contentTintColor = filled
            ? ColorStore.shared.color(.label)
            : PopupViewController.dimmedLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = .systemFont(ofSize: PopupViewController.Metrics.textSize)
        // Secondary colour throughout: the subject of the popup is the service and incident rows
        // above, and a call to action must not outweigh them.
        label.textColor = PopupViewController.dimmedLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)

        // The icon is **centred on the status dots' axis**, not flush with the row's leading edge.
        // Both used to start at x=0, but a 9-pt dot and a 15-pt glyph then have centres 3 pt apart —
        // enough to read as a misaligned column down the left of the section. Centring on the dot's
        // midpoint puts the bell directly under them whatever the glyph's own width turns out to be.
        //
        // The text then starts where every service/incident name starts (dot width + gap), so the
        // two columns hold across the whole block.
        let dotDiameter = PopupViewController.Metrics.statusDotDiameter
        let gap = PopupViewController.Metrics.statusDotGap
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: dotDiameter / 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: dotDiameter + gap),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let inset = bounds.insetBy(dx: -4, dy: -1)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - PillView

/// A small rounded, layer-backed badge — the blocking-reset badge on a limit row (#158, the exhausted
/// red). The corner radius is a fraction of the height (`cornerFraction`) — a softly rounded rect
/// rather than a full pill (#224) — and the fill CGColor is re-resolved in `updateLayer()` because
/// CGColor is not appearance-dynamic (the standard layer-backed dark/light trap).
///
/// Since #254 this is the popup's **only** filled badge: the credits "in use" marker moved to the
/// knocked-out glyph of ``KnockoutGlyphBadge``, so a solid fill now means exactly one thing — the
/// reset that unblocks work.
final class PillView: NSView {
    /// The badge fill. Defaults to the accent blue; callers set it (e.g. the exhausted red). A closure
    /// (not a stored `NSColor`) so a dynamic colour re-resolves per appearance.
    var fill: () -> NSColor = { .controlAccentColor }

    /// Corner radius as a fraction of the height. `0.5` is a full pill; lower is a softer rounded rect.
    private static let cornerFraction: CGFloat = 0.35

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height * Self.cornerFraction
    }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height * Self.cornerFraction
        layer?.backgroundColor = fill().cgColor
    }
}

// MARK: - KnockoutGlyphBadge

/// A filled badge with a symbol **knocked out** of it (#254): the plaque is drawn in a solid colour and
/// the glyph is punched through it, so the popup background shows through the symbol itself rather than
/// the symbol being painted on top.
///
/// This is the third "credits are in use" anatomy under discussion — a `label`-coloured plaque carrying a
/// see-through currency glyph. It reads as a *chip* (a mode marker) rather than an alarm, because the
/// colour is the ordinary label ink rather than a status red, while still being a solid, deliberate
/// object next to the heading.
///
/// **How the knockout works.** The badge layer is filled with `fill()`, and a mask layer whose contents
/// are the *inverted* glyph is applied: the mask is opaque everywhere except where the symbol is, so the
/// fill is erased exactly under the glyph. Both the fill colour and the mask are rebuilt in
/// `updateLayer()`/`layout()` because CGColor and rendered images are not appearance-dynamic — the same
/// dark/light trap `PillView` documents.
final class KnockoutGlyphBadge: NSView {
    /// The plaque fill. A closure so a dynamic colour re-resolves per appearance.
    var fill: () -> NSColor = { ColorStore.shared.color(.label) }

    /// The SF Symbol punched out of the plaque.
    var symbolName: String = "eurosign"

    /// Point size of the knocked-out glyph.
    var symbolPointSize: CGFloat = 11

    /// Padding around the glyph inside the plaque. `hInset` is per-side, so the plaque is `2 × hInset`
    /// wider than the glyph's box; it runs a little wider than `vInset` because a currency glyph is
    /// narrow and tall, and equal padding on both axes leaves it looking pinched left-to-right.
    private static let hInset: CGFloat = 5.5
    private static let vInset: CGFloat = 3

    /// Corner radius as a fraction of the height — matches `PillView` so the two badge anatomies share a
    /// silhouette family.
    private static let cornerFraction: CGFloat = 0.35

    override var wantsUpdateLayer: Bool { true }

    /// Plaque size: the glyph's box padded by the insets, rounded to whole points.
    ///
    /// Deliberately simple. Measuring the glyph's ink and trying to centre on it exactly chases a
    /// sub-point difference that survives every rounding (an SF Symbol's ink sits half a point off inside
    /// its own box, which is a whole pixel on a 2× display) — so instead the glyph is box-centred and a
    /// single hand-tuned ``opticalNudge`` corrects what is left. Cheap, legible, and adjustable by eye,
    /// which is how this kind of optical alignment is settled anyway.
    override var intrinsicContentSize: NSSize {
        let box = glyphImage()?.size ?? NSSize(width: symbolPointSize, height: symbolPointSize)
        return NSSize(width: (box.width + Self.hInset * 2).rounded(),
                      height: (box.height + Self.vInset * 2).rounded())
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height * Self.cornerFraction
        applyMask()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The mask is rendered for a specific size; rebuild it whenever the plaque is resized, or the
        // glyph stays centred on the old bounds and drifts off-centre.
        applyMask()
    }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height * Self.cornerFraction
        layer?.backgroundColor = fill().cgColor
        applyMask()
    }

    /// Horizontal correction applied to the box-centred glyph, in points.
    ///
    /// A currency SF Symbol's ink sits slightly off-centre inside its own bounding box, so a box-centred
    /// glyph reads as sitting too far right — it needs a sliver of extra space on its right to look
    /// balanced. Computing the exact correction is possible but chases a sub-point difference that every
    /// rounding step reintroduces, and the pixel extents of the knocked-out hole turn out not to predict
    /// what the eye reads; a fixed nudge settled by eye is simpler and does the job.
    ///
    /// Negative moves the glyph **left**, opening up space on the right.
    private static let opticalNudge: CGFloat = -0.4

    /// The symbol image used both for sizing and for building the knockout mask.
    private func glyphImage() -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolPointSize, weight: .bold))
    }

    /// Build and attach the inverted-glyph mask: opaque plaque everywhere except the symbol, which is
    /// cleared so the popup background shows through.
    ///
    /// The glyph is punched out with `NSCompositingOperation.destinationOut` rather than a CoreGraphics
    /// blend mode: an SF Symbol is a **template** image, and `CGContext.setBlendMode(.destinationOut)`
    /// leaves the mask fully opaque (the symbol never erases anything, so nothing shows through). Drawing
    /// the symbol black first and then compositing gives a fully transparent knockout instead of the
    /// partial ~0.6 alpha a straight template composite produces at the glyph's antialiased edges.
    private func applyMask() {
        guard bounds.width > 0, bounds.height > 0, let glyph = glyphImage() else { return }
        let size = bounds.size
        let g = glyph.size
        // Box-centre the glyph, plus a fixed optical nudge — see `opticalNudge`.
        let rect = CGRect(x: (size.width - g.width) / 2 + Self.opticalNudge,
                          y: (size.height - g.height) / 2,
                          width: g.width, height: g.height)
        // A solid-black copy of the symbol: a template image draws in whatever colour is set, and an
        // opaque source is what makes `destinationOut` erase all the way to zero alpha.
        let solid = NSImage(size: g, flipped: false) { _ in
            NSColor.black.set()
            glyph.draw(in: CGRect(origin: .zero, size: g), from: .zero, operation: .sourceOver, fraction: 1)
            CGRect(origin: .zero, size: g).fill(using: .sourceAtop)
            return true
        }
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            CGRect(origin: .zero, size: size).fill()
            solid.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = image
        mask.contentsScale = window?.backingScaleFactor ?? 2
        layer?.mask = mask
    }
}

// MARK: - GlowDotView

/// A service-status colour dot with an ambient glow (#188), as a **layer-backed subview** rather than a
/// baked text-attachment image — so both the fill and the coloured glow re-resolve on a light/dark theme
/// flip (a baked image would freeze the appearance it was rendered in). `fill` is a closure so the dynamic
/// `.system*` colour re-resolves per appearance in `updateLayer` (the standard layer-backed dark/light
/// trap); the shadow colour tracks it. The dot is a `diameter`-wide circle centred in the view; the view
/// itself is sized to `diameter` (the glow spills outside its bounds via the layer shadow, which is not
/// clipped).
final class GlowDotView: NSView {
    var fill: () -> NSColor = { .systemGray }
    var glowRadius: CGFloat = 5
    var glowStrength: CGFloat = 1.0

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.masksToBounds = false
        let c = fill()
        layer?.backgroundColor = c.cgColor
        layer?.shadowColor = c.withAlphaComponent(min(1, glowStrength)).cgColor
        layer?.shadowRadius = glowRadius
        layer?.shadowOpacity = 1
        layer?.shadowOffset = .zero
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
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


    /// Invoked when the subscribe row is clicked. The controller reports the click; `AppDelegate`
    /// owns what it means (subscribe to the current episode, or stop following it) and persists it.
    /// A closure rather than a delegate protocol — this is the popup's only outbound action.
    var onToggleSubscription: (() -> Void)?

    /// The clock the status/incident ages are measured against. Injected (not `Date()` inline) so a
    /// date-decoupled stub renders the same frame every time, matching how the engine takes its
    /// `now` — otherwise a screenshot frame would drift with the wall clock.
    var now: () -> Date = { Date() }

    /// Whether ⌥ Option is currently held (ADR-0020's modifier-poll timer feeds this live while the
    /// dropdown is open). It reveals the on-demand data age ("2m ago") in the "Claude Code" header,
    /// and — once the first status poll has succeeded — the service-status rows: while ⌥ is up they
    /// show only when a component is non-operational, and holding ⌥ reveals **all** components even
    /// when every one is green (`rebuild()`'s `showStatusRows`). It is also the escape hatch for the
    /// two ``PopupSectionVisibility`` groups: in `.nonCalm` it reveals a calm group, and in
    /// `.optionOnly` it is the *only* thing that reveals one.
    var optionHeld = false {
        didSet {
            guard isViewLoaded, optionHeld != oldValue else { return }
            rebuild()
        }
    }

    /// Drives the smooth colour transitions (ADR-0070), shared with the menu-bar widget and owned by
    /// `AppDelegate`. Handed to each `PopupBarView` and status dot during `rebuild()`, so the
    /// animation state survives those views being recreated on every update.
    weak var colorAnimator: ColorAnimator?

    /// Pins the **5-hour** bar's coloured strip to this fraction of its track for the `color-cycle`
    /// stub, so the only thing moving on screen is the colour. Every other row keeps its real
    /// geometry, staying a motionless reference beside it. `nil` on every real data path.
    var frozenStripFraction: Double?

    /// The row the colour walk drives — matched against `LimitRow.title` (`PopupLayout` titles the
    /// base 5-hour window this way).
    private let frozenStripRow = "5-hour"

    /// Bar presentation style (#224), governing every bar in the popup. Pushed into each `PopupBarView`
    /// during `rebuild()` → `addBar`. Child bars are built fresh on each rebuild, so a change here must
    /// rebuild (not just redraw) to reach them — mirrors `optionHeld`. Default `.pacing`.
    var barStyle: BarStyle = .progress {
        didSet {
            guard isViewLoaded, barStyle != oldValue else { return }
            rebuild()
        }
    }

    /// Whether the under-bar tick ruler is drawn on the pacing bars (#224). Pushed into each
    /// `PopupBarView` during `rebuild()` → `addBar`, like `barStyle`. Default `true`.
    var showTicks: Bool = true {
        didSet {
            guard isViewLoaded, showTicks != oldValue else { return }
            rebuild()
        }
    }

    /// When the per-model / per-service rows are shown (#211). The gate lives here rather than in
    /// `PopupLayout` because it depends on ``optionHeld``, which changes while the menu is open and
    /// without a re-poll. Like `barStyle`, a change rebuilds.
    var modelLimitsVisibility: PopupSectionVisibility = .nonCalm {
        didSet {
            guard isViewLoaded, modelLimitsVisibility != oldValue else { return }
            rebuild()
        }
    }

    /// When the "Extra usage" credits section is shown. Independent of the menu-bar credits icon,
    /// which keeps its own boolean gate in `PersistedConfig.showExtraUsage`.
    var extraUsageVisibility: PopupSectionVisibility = .nonCalm {
        didSet {
            guard isViewLoaded, extraUsageVisibility != oldValue else { return }
            rebuild()
        }
    }

    // `fileprivate`, not `private`: `SubscribeRowView` (#279) is a sibling type in this file and
    // sizes itself from the same metrics, so the two rows cannot drift apart.
    fileprivate enum Metrics {
        /// Popup width. Sized so the inner content column stays 252 pt once the Control-Center-style card
        /// adds its outer margin (308 − 2·14 card inset − 2·14 inner = 252).
        static let width: CGFloat = 312
        static let hPadding: CGFloat = 16
        /// Outer margin between the popup edge and the rounded "card". Matched to the horizontal inset of
        /// the native menu separator so the card is exactly as wide as the divider between the menu items
        /// below it (the Control-Center float gap; the menu material shows in this strip around the plate).
        static let cardInset: CGFloat = 14
        /// Top outer margin. Smaller than `cardInset` because `NSMenu` already adds its own vertical pad
        /// above our hosted item view, so a full `cardInset` on top would read as a larger gap than the
        /// sides. Trimmed so the visible top gap looks balanced against the sides.
        static let cardTopInset: CGFloat = 10
        /// Bottom outer margin — trimmed below `cardInset` so the gap between the card and the native
        /// "Settings…" item beneath it is tighter (NSMenu adds its own pad there too).
        static let cardBottomInset: CGFloat = 4
        /// Corner radius of the section card — matches Control Center's ~10 pt rounded plate.
        static let cardCornerRadius: CGFloat = 10
        /// Hairline width of the card's subtle edge.
        static let cardBorderWidth: CGFloat = 0.5
        static let vPadding: CGFloat = 10
        /// Top **inner** padding — space between the card's top edge and the "Claude" header. Matched to
        /// `hPadding` so the gap above the header equals the gap from the card's left edge to it.
        static let topPadding: CGFloat = 16
        /// Bottom **inner** padding — space between the last bar's tick ruler and the card's bottom edge.
        /// Roomier now that the content sits on its own card (a tight 3 pt left the ticks crowding the
        /// rounded edge).
        static let bottomPadding: CGFloat = 12
        static let rowSpacing: CGFloat = 3
        /// Gap after an incident row (#279). Larger than ``rowSpacing`` because an incident is a
        /// wrapped block rather than a single line: at 3 pt two incidents run together and read as
        /// one paragraph. Applied after **every** incident, so the distance between two of them and
        /// the distance from the last one to the subscribe row are the same.
        static let incidentRowSpacing: CGFloat = 8
        static let sectionSpacing: CGFloat = 14
        /// Gap **between limit blocks** (after each section's bar) — a touch tighter than
        /// `sectionSpacing` so the limit list reads as a group without the header's larger breathing room.
        static let limitSpacing: CGFloat = 10
        static let textSize: CGFloat = dropdownTextSize
        /// Diameter of the service-status glow dot (#188), the gap between it and the component name, and
        /// the extra leading inset that pushes the dot in from the card's left edge.
        static let statusDotDiameter: CGFloat = 9
        static let statusDotGap: CGFloat = 10
        static let statusRowLeadingInset: CGFloat = 15
        /// The inner content column width for fixed-width rows/labels — the popup width minus the card's
        /// outer inset on both sides minus the inner horizontal padding on both sides. Held constant at
        /// 252 pt (296 − 2·8 − 2·14) so bar/label wrapping is identical to before the card was added.
        static let contentWidth: CGFloat = width - 2 * cardInset - 2 * hPadding
    }

    private let stack = NSStackView()

    /// Corner radius / border width of the section card, exposed for `CardBackdropView` (which lives
    /// outside this type and cannot read the private `Metrics`).
    static var cardCornerRadius: CGFloat { Metrics.cardCornerRadius }
    static var cardBorderWidth: CGFloat { Metrics.cardBorderWidth }

    /// The Control-Center-style rounded plate behind the whole Claude section (#188). Created once in
    /// `loadView`, sits below `stack`, inset from the popup edge. The `NSMenu` vibrancy shows through the
    /// margin around it; the popup has no opaque backdrop of its own (always translucent).
    private var cardView: CardBackdropView?

    /// The bold header of the popup's first section — "Claude" covers the update-cadence line and the
    /// per-component service status rows beneath it (see `rebuild`).
    private static let claudeCodeSectionTitle = "Claude"

    /// The status word shown flush-right on the **idle** 5-hour row (#100, ADR-0027): the 5h window has
    /// no active session, so the row reads "5-hour  ready to start" with a solid-blue bar and no second
    /// line. The localisation seam (ADR-0009) — like the other status phrases, the English word lives
    /// here, not in the kit.
    static let idleStatusText = "ready to start"

    /// The status word for a **blocked** idle 5-hour row (#158): the 5h window is idle, but the 7-day
    /// limit is exhausted and paid credits cannot cover, so there is no path to start — the user is
    /// waiting for a reset, not "ready to start". Neutral wording (not "7d" specifically) because the
    /// blocker can be the 7-day limit *or* a reached credits cap. The localisation seam (ADR-0009).
    static let blockedStatusText = "waiting for limit reset"

    /// The heading of the "Extra usage" money-credits section (#145) — the localisation seam. Styled
    /// like the limit-window titles (plain label colour), the section reads from its numbers/bar.
    static let extraUsageTitle = "Extra usage"

    /// Anthropic's official primary accent colour (`#d97757`, a terracotta orange) — confirmed
    /// against `anthropics/skills`' `brand-guidelines/SKILL.md` on GitHub, the same value the local
    /// Claude Code "claude" theme slot resolves to. Used only for the "Claude Code" section header,
    /// so the popup echoes the CLI's own brand mark rather than a generic label colour.
    private static var claudeBrandColor: NSColor { ColorStore.shared.color(.claudeBrand) }

    /// `Metrics.textSize`, bold — the "Claude Code" section header and the two native menu items
    /// below it (via `App.swift`'s `attributedTitle`) all resolve to this exact font, so there is no
    /// visual mismatch to chase.
    private static var menuItemFont: NSFont {
        NSFontManager.shared.convert(.systemFont(ofSize: Metrics.textSize), toHaveTrait: .boldFontMask)
    }

    /// The left half of the "Claude" section header: **"Claude"** in the bold ``menuItemFont``, and —
    /// when a plan label is present (e.g. "Max 5x", from the Keychain rate-limit tier) — a bold `･`
    /// separator followed by the plan in the *regular* weight of the same size. All three parts share
    /// ``claudeBrandColor``: the plan reads as part of the same brand mark, distinguished from "Claude"
    /// by weight, not colour (the plan itself is deliberately **not** bold; the `･` separator is, to
    /// match "Claude"). Returns a single attributed label so the parts share one baseline.
    private static func brandTitleLabel(plan: String?) -> NSTextField {
        let bold: [NSAttributedString.Key: Any] = [.font: menuItemFont, .foregroundColor: claudeBrandColor]
        let title = NSMutableAttributedString(string: claudeCodeSectionTitle, attributes: bold)
        if let plan, !plan.isEmpty {
            // Bold `･` separator (halfwidth katakana middle dot, U+FF65), then the regular-weight plan.
            title.append(NSAttributedString(string: " ･ ", attributes: bold))
            title.append(NSAttributedString(
                string: plan,
                attributes: [
                    .font: NSFont.systemFont(ofSize: Metrics.textSize),
                    .foregroundColor: claudeBrandColor,
                ]))
        }
        let label = NSTextField(labelWithAttributedString: title)
        return label
    }

    /// Dimmed text colour for supporting numbers/rows ("88% used", "resets in …", "Updated …",
    /// service-status words) — neither `secondaryLabelColor` (too light) nor `tertiaryLabelColor`
    /// (too dark) alone; AppKit has no built-in "in-between" semantic label colour, so this blends the
    /// two. A **dynamic** `NSColor(name:)`: the blend is computed *inside* the provider, in the target
    /// appearance, so it re-resolves per view and adapts to light/dark. A plain `static let ...
    /// .blended(...)` bakes in whatever appearance was current at first access — which made it render
    /// near-black under the dark system theme.
    static var dimmedLabelColor: NSColor { ColorStore.shared.color(.dimmedLabel) }

    /// The shipped default for ``dimmedLabelColor`` — a **dynamic** `NSColor(name:)` whose blend is
    /// computed inside the provider (see the note above). Source of truth for `ColorRole.defaultColor`.
    static let defaultDimmedLabel = NSColor(name: nil) { appearance in
        var mixed: NSColor = .secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            mixed = NSColor.tertiaryLabelColor.blended(withFraction: 0.5, of: .secondaryLabelColor)
                ?? .secondaryLabelColor
        }
        return mixed
    }


    override func loadView() {
        let container = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Control-Center-style card: inset from the popup edge, with `stack` pinned inside it (inner
        // padding). Added before `stack` so it sits below the content; the menu vibrancy shows around it.
        let card = CardBackdropView()
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        container.addSubview(stack)
        cardView = card

        NSLayoutConstraint.activate([
            // Card inset from the container. Top uses the trimmed `cardTopInset` to offset NSMenu's own
            // vertical padding above our item view, so the visible top gap matches the sides.
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.cardTopInset),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.cardInset),
            container.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: Metrics.cardInset),
            container.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: Metrics.cardBottomInset),
            // Content pinned inside the card with the existing inner padding.
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.topPadding),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.hPadding),
            card.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Metrics.hPadding),
            card.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Metrics.bottomPadding),
            container.widthAnchor.constraint(equalToConstant: Metrics.width),
        ])
        self.view = container
        rebuild()
    }

    // MARK: Rendering

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let layout else { return }

        // The "Claude Code" section header (first line): the brand-coloured, bold title (always
        // shown — see `claudeBrandColor`) flush left. Its right half carries the dim data age
        // ("2m ago"): shown **whenever the data is stale** — the age has grown past
        // ``Self.staleAgeThreshold`` (2× the poll floor) so it becomes worth surfacing on its own — and
        // otherwise **only while ⌥ Option is held** (the age is an on-demand detail when data is fresh).
        //
        // The service status rows (issue #31, #89) show **when there is a real problem** —
        // `worstProblem != nil`, i.e. at least one monitored component is non-operational — **or**
        // whenever ⌥ Option is held (once the first status poll has succeeded, `status != nil`).
        // With no problem and ⌥ up, the all-operational lines add nothing worth the space, so the
        // healthy status stays hidden; holding ⌥ reveals it on demand. When rows are shown we show
        // **only the problematic components** by default and **all** monitored components (the healthy
        // ones for context: `API`, `Code`, `WEB/Desktop`, `Cowork` when enabled) while ⌥ is held.
        let status = layout.serviceStatus
        // The status section shows when something is wrong, when a component recovered within the
        // last few minutes (so a fix that just landed is not indistinguishable from "nothing ever
        // happened"), or — under ⌥ — when there are incidents to switch the dimension to. With ⌥ held
        // and no incidents, there is nothing for that dimension to show, so the section stays away
        // rather than falling back to the service rows the user was already looking at.
        let hasRecentRecovery = status?.checks.flatMap(\.components)
            .contains { Self.isRecentlyRecovered($0, now: now()) } ?? false
        let showStatusRows = status != nil
            && (status?.worstProblem != nil || hasRecentRecovery || (optionHeld && !layout.incidents.isEmpty))
        let showAge = optionHeld || layout.lastUpdateAge >= Self.staleAgeThreshold
        let ageString = showAge ? Self.ageText(layout.lastUpdateAge) : ""
        // Header layout (#233): the "Claude" brand title with the "Nm ago" age beside it on the left —
        // **always**, whether or not an awaiting-input count exists. The age belongs to the brand title,
        // not to the right edge: pushing it flush right (the old no-awaiting fallback) made it jump
        // across the header the moment the awaiting count dropped to zero or the feature was off.
        // The right slot is reserved for the awaiting-input indicator (hand + count) and stays empty
        // otherwise.
        // The brand title — "Claude" plus the plan label ("Max 5x") when present, both in brand colour.
        let brand = Self.brandTitleLabel(plan: layout.planLabel)
        let age = NSTextField(labelWithString: ageString)
        age.font = .systemFont(ofSize: Metrics.textSize)
        age.textColor = Self.dimmedLabelColor
        let leading = NSStackView(views: [brand, age])
        leading.orientation = .horizontal
        leading.alignment = .firstBaseline
        leading.spacing = 8
        // Right slot: the summary badge when there is an awaiting count and ⌥ is up; nothing when ⌥ is
        // held (the per-project breakdown below supersedes it — but the age stays put next to the brand
        // title, it does not move to where the badge was) or when there is no awaiting count at all.
        let right: NSView
        if let awaiting = layout.awaitingInput, !optionHeld {
            right = makeAwaitingBadge(awaiting)
        } else {
            right = NSView()
        }
        let sectionHeader = addSplitRow(leadingView: leading, rightView: right)
        stack.setCustomSpacing(Metrics.sectionSpacing, after: sectionHeader)

        // #233: while ⌥ is held, reveal the per-project awaiting breakdown right under the header —
        // one row per project with a coloured hand chip per non-empty time-to-deletion bucket.
        if optionHeld, let awaiting = layout.awaitingInput {
            var lastRow: NSView?
            for stat in awaiting.perProject {
                lastRow = makeAwaitingProjectRow(stat)
            }
            if let lastRow { stack.setCustomSpacing(Metrics.sectionSpacing, after: lastRow) }
        }

        if showStatusRows, let status {
            var lastRow: NSView?
            let now = self.now()
            if optionHeld, !layout.incidents.isEmpty {
                // ⌥ switches the **dimension**, not the level of detail (ADR-0071 §2): the service
                // rows are replaced by the incidents behind them. Green service lines are not shown
                // here — under ⌥ the question is "what is broken", and a green row does not answer it.
                for incident in layout.incidents {
                    let row = addIncidentRow(incident, now: now)
                    // One gap for the whole block: the same distance between two incidents as
                    // between the last incident and the subscribe row. The default `rowSpacing`
                    // alone does not achieve that — a wrapped, multi-line description carries
                    // trailing line leading that the single-line subscribe row does not, so equal
                    // spacing values render as visibly unequal gaps.
                    stack.setCustomSpacing(Metrics.incidentRowSpacing, after: row)
                    lastRow = row
                }
            } else {
                // Default: only the non-operational components — plus any that went green within the
                // recovery window, so a fix that just landed is visible rather than leaving a blank
                // popup that looks identical to "nothing ever happened".
                let components = status.checks.flatMap(\.components)
                    .filter { $0.status.isProblem || Self.isRecentlyRecovered($0, now: now) }
                for component in components {
                    lastRow = addServiceStatusRow(
                        label: Self.displayName(component),
                        status: component.status,
                        age: component.stateAge(at: now))
                }
            }
            if let subscribeRow = addSubscribeRowIfNeeded(layout) { lastRow = subscribeRow }
            if let lastRow { stack.setCustomSpacing(Metrics.sectionSpacing, after: lastRow) }
        }

        // Error block (when failing): two lines — a bold title led by the ⚠️ symbol, then the
        // detail. Shown immediately on any failure (SPEC), so the problem is read before the limit
        // sections. No trailing rule (see above).
        if let reason = layout.warning {
            addWarningTitle(Self.warningTitle(reason))
            let detail = addWrappingLabel(
                Self.warningDetail(reason), font: .systemFont(ofSize: Metrics.textSize), secondary: true)
            // The error block ends a section (like the header and the service-status rows above it), so
            // the first limit row below it needs the full `sectionSpacing` gap — not the default
            // `rowSpacing`, which left the error detail visually glued to the "5-hour" row (issue: the
            // error block had no trailing custom spacing while every other section boundary set one).
            stack.setCustomSpacing(Metrics.sectionSpacing, after: detail)
        }

        // One section per limit row: "title · status" line + "reset · %" line + bar. No rule
        // between sections — the only interior rule in the popup is the one after the title block;
        // sections below it are told apart by the bold per-row title and the `limitSpacing` gap
        // after each bar, not by a line.
        // The optional per-model group is hidden by *skipping* rows, never by filtering the array:
        // `layout.blockingReset` keys its `.token(id:)` pick to the full row order, and `isBlockingRow`
        // matches it against this `index`. Renumbering would paint the red badge on the wrong row.
        let showPerModel = modelLimitsVisibility.shows(
            isNonCalm: layout.perModelRowsAreNonCalm, optionHeld: optionHeld)
        let showCredits = layout.credits != nil && extraUsageVisibility.shows(
            isNonCalm: layout.creditsIsNonCalm, optionHeld: optionHeld)
        // Which row ends the visible list — the last one actually drawn, so the "no gap after the last
        // bar" rule follows what's on screen rather than what the model built.
        let lastVisibleRowIndex = showPerModel ? layout.rows.count - 1 : layout.perModelRowsStart - 1

        for (index, row) in layout.rows.enumerated() {
            if index >= layout.perModelRowsStart, !showPerModel { continue }
            addTitleStatusLine(title: row.title, status: Self.statusText(row, isBaseLimit: index <= 1))
            // The idle 5-hour row (#100) has **no** second line at all — no "0%", no reset — so it reads
            // as a compact "5-hour  ready to start" (or "waiting for limit reset" when blocked, #158) +
            // solid bar. Every other row shows the detail; its reset goes red when it is *the* blocking
            // reset (the "last stand" pick from `layout.blockingReset`).
            if !row.sessionIdle {
                addDetailLine(
                    used: Self.usedText(row, verbose: optionHeld),
                    reset: Self.resetText(row, verbose: optionHeld),
                    resetIsBlocking: Self.isBlockingRow(index, in: layout))
            }
            // No inter-section gap after the **last** bar — but only when there is no credits section
            // below. If the "Extra usage" block follows, this bar is *not* the last thing in the popup,
            // so it needs the normal inter-section gap; the credits block then owns the tight-to-separator
            // bottom instead.
            let isLastLimitRow = index == lastVisibleRowIndex
            // The far-behind blue zone is restricted to the base 5h/7d rows. `PopupLayout.rows`
            // always emits them first (index 0 = 5h, 1 = 7d); everything appended after is a
            // per-model / per-service row and stays green on the calm side.
            addBar(row, isLast: isLastLimitRow && !showCredits, isBaseLimit: index <= 1)
        }

        // The "Extra usage" (money-credits) section (#145), rendered below the limit windows when
        // credits are active for this snapshot **and** the user's visibility mode allows it. Two shapes,
        // keyed by whether a cap is set — see `addCreditsSection`.
        if showCredits, let credits = layout.credits {
            addCreditsSection(credits, resetIsBlocking: Self.isBlockingCredits(in: layout))
        }
    }

    /// Whether popup row `index` is the one carrying the **blocking** reset (#158) — the single reset
    /// `layout.blockingReset` picked (the "last stand" rule). `false` unless the layout is blocked and
    /// the pick is that row. Drives the red reset colour on exactly one row.
    private static func isBlockingRow(_ index: Int, in layout: PopupLayout) -> Bool {
        if case let .token(id, _)? = layout.blockingReset { return id == index }
        return false
    }

    /// Whether the "Extra usage" credits section carries the blocking reset (#158).
    private static func isBlockingCredits(in layout: PopupLayout) -> Bool {
        if case .credits? = layout.blockingReset { return true }
        return false
    }

    // MARK: Extra usage (money-credits) section (#145)

    /// Render the "Extra usage" section from a ``CreditsRow``. Two shapes:
    ///
    /// - **Limit set** (`credits.bar != nil`): a full section mirroring a limit window —
    ///   ```
    ///   Extra usage ............... on pace | ahead | limit reached
    ///   €10.8 of €15 .............. 5d on Friday
    ///   ```
    ///   plus a pacing bar (same `PopupBarView`, coloured by `credits.bar` via `aheadColor`).
    /// - **Unlimited** (`credits.bar == nil`): a single bare line, no bar, no reset —
    ///   ```
    ///   Extra usage ............... €10.8 spent
    ///   ```
    ///
    /// The heading "Extra usage" is styled like the limit-window titles (plain `labelColor`, not the
    /// brand-coloured "Claude" header): the section reads from its numbers and bar, not a heavy heading.
    private func addCreditsSection(_ credits: CreditsRow, resetIsBlocking creditsResetIsBlocking: Bool = false) {
        guard let bar = credits.bar, let limit = credits.limit else {
            // Unlimited: "Extra usage … €X.XX spent". No bar, no reset line — no cap to pace.
            addTitleStatusLine(
                title: Self.extraUsageTitle,
                status: Self.creditsSpentOnlyText(credits.spent, verbose: optionHeld))
            return
        }

        // Limit set: title (+ "in use" badge when credits are actually covering an exhausted limit) +
        // status word, then "spent / limit … <reset line>", then the bar. The reset uses the same
        // unified line as the token rows (`resetText`) — "5d on Friday", "20h at 03:00" — no prefix
        // (#167). When this reset is the one blocking work it's shown as a red badge instead
        // (`resetIsBlocking`).
        addTitleStatusLine(
            title: Self.extraUsageTitle,
            status: Self.creditsStatusText(bar),
            badge: credits.inUse ? makeInUseMarker(currency: credits.spent.currency) : nil)
        addDetailLine(
            used: Self.creditsAmountText(spent: credits.spent, limit: limit, verbose: optionHeld),
            reset: (optionHeld ? credits.resetLineVerbose : credits.resetLine) ?? "resetting…",
            resetIsBlocking: creditsResetIsBlocking)
        // Credits pace over the whole calendar month; there is no window-tick ruler like the token bars,
        // so the bar draws with no subdivisions (a plain pacing bar). `isLast: true` — the credits
        // section is always the popup's final block, so it sits tight above the menu separator.
        addBar(bar: bar, subdivisions: 0, idle: false, isLast: true)
    }

    /// The section's first line: title and pacing status, both `labelColor` — the same weight and
    /// colour the dropdown's own "Settings…" text uses. `status` sits flush **right**, lined up with
    /// the detail line and bar below it, instead of trailing right after the title on the left.
    /// Neither half is bold — the section reads from the bar and numbers, not a heavier heading. Both
    /// the window titles (`"5-hour"`/`"7-day"`) and the bare per-model names (`"Opus"`/`"Fable"`) render
    /// whole in `labelColor`.
    @discardableResult
    private func addTitleStatusLine(title: String, status: String, badge: NSView? = nil) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = font
        titleLabel.textColor = ColorStore.shared.color(.label)
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = font
        statusLabel.textColor = ColorStore.shared.color(.label)
        guard let badge else {
            return addSplitRow(leftLabel: titleLabel, rightLabel: statusLabel)
        }
        // With a badge, the left half is [title • badge]; the status stays flush right.
        let leading = NSStackView(views: [titleLabel, badge])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 6
        return addSplitRow(leadingView: leading, rightLabel: statusLabel)
    }

    /// The awaiting-input indicator (#233) shown flush-right in the "Claude" header: a `hand.raised`
    /// icon tinted by urgency (red < 7d / orange < 15d left before Claude Code deletes the session /
    /// neutral otherwise), followed by the count when `count ≥ 2` (a single session shows the bare icon).
    /// Hovering shows a tooltip inviting ⌥ Option, which reveals the per-project breakdown inline
    /// (built in `rebuild()`). `sessions.count` is always `≥ 1` here (caller passes `nil` for "hide").
    private func makeAwaitingBadge(_ sessions: AwaitingSessions) -> NSView {
        // Header badge: bare hand when a single session, hand + count otherwise. Icon + count share
        // the urgency tint.
        let chip = makeHandChip(count: sessions.count, tint: Self.awaitingTint(sessions.urgency),
                                showCountForOne: false)
        chip.toolTip = "Sessions waiting for your answer.\nHold ⌥ (Option) for per-project stats"
        return chip
    }

    /// A `hand.raised` icon + count chip (#233), the icon tinted by `tint`, the count kept neutral
    /// (uncoloured). When `showCountForOne` is false a count of `1` renders as the bare hand (the
    /// header badge); the per-project rows pass `true` so every bucket shows the count including 1.
    private func makeHandChip(count: Int, tint: NSColor, showCountForOne: Bool) -> NSStackView {
        let size = Metrics.textSize
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "hand.raised", accessibilityDescription: "sessions awaiting input")?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = tint

        let stack = NSStackView()
        // Count **before** the icon — reads as "N sessions" (numeral + noun), the natural English
        // count order. The count is dimmed (same colour as the "20%" utilisation text); the hand keeps
        // its bucket colour (red/orange, or the plain label colour when neutral).
        if count >= 2 || showCountForOne {
            let countLabel = NSTextField(labelWithString: "\(count)")
            countLabel.font = .systemFont(ofSize: size)
            countLabel.textColor = Self.dimmedLabelColor
            stack.addArrangedSubview(countLabel)
        }
        stack.addArrangedSubview(iconView)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        return stack
    }

    /// One per-project breakdown row (#233), revealed while ⌥ is held: the project name flush-left, a
    /// hand chip per **non-empty** bucket flush-right — neutral (>15d left), orange (<15d), red (<7d),
    /// in that order — each showing its count (including 1). The hand carries the bucket colour; the count is
    /// neutral.
    private func makeAwaitingProjectRow(_ stat: ProjectAwaitingStats) -> NSView {
        let name = NSTextField(labelWithString: stat.projectName)
        name.font = .systemFont(ofSize: Metrics.textSize)
        name.textColor = ColorStore.shared.color(.label)

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 8
        // Order: neutral → orange → red; only non-empty buckets. Each chip's tooltip states its
        // time-to-deletion bucket.
        let buckets: [(Int, NSColor, String)] = [
            (stat.recent, ColorStore.shared.color(.label), ">15d till deletion"),
            (stat.orange, .systemOrange, "<15d till deletion"),
            (stat.red, .systemRed, "<7d till deletion"),
        ]
        for (n, color, tip) in buckets where n > 0 {
            let chip = makeHandChip(count: n, tint: color, showCountForOne: true)
            chip.toolTip = tip
            chips.addArrangedSubview(chip)
        }
        return addSplitRow(leadingView: name, rightView: chips)
    }

    /// The AppKit colour for an awaiting-input urgency, shared by the icon and the count label so they
    /// read as one unit (#233). Matches the menu-bar tint mapping in `StatusItemView`.
    private static func awaitingTint(_ urgency: AwaitingUrgency) -> NSColor {
        switch urgency {
        case .red:     return .systemRed
        case .orange:  return .systemOrange
        case .neutral: return ColorStore.shared.color(.label)
        }
    }

    /// The **"in use"** marker shown next to the "Extra usage" heading while paid credits are actually
    /// covering an exhausted plan limit (`CreditsRow.inUse`): a `label`-coloured plaque with the currency
    /// glyph **knocked out** of it, so the popup background shows through the symbol (#254).
    ///
    /// Replaces the solid red `active` pill this badge used to be (#224). Crossing onto paid credit is a
    /// *mode change* worth flagging, but a red fill made it a *severity*: it took the same token as the
    /// blocking-reset badge — the one badge that means "you are stopped" — and it fired at its loudest at
    /// €0.00 spent, leaving nothing louder for the cap. A neutral plaque states the mode without claiming
    /// the row is blocked, and reuses the menu bar's own currency glyph
    /// (``StatusItemView/creditsSymbolName(for:)``) so both surfaces mark this feature with one symbol.
    private func makeInUseMarker(currency: String) -> NSView {
        let badge = KnockoutGlyphBadge()
        badge.symbolName = StatusItemView.creditsSymbolName(for: currency)
        badge.symbolPointSize = Metrics.textSize - 1
        badge.fill = { ColorStore.shared.color(.inUsePill) }
        badge.wantsLayer = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.toolTip = Self.inUseHint
        badge.setAccessibilityLabel(Self.inUseAccessibilityLabel)
        // Pin the plaque to its intrinsic size: inside the title stack an unpinned view is stretched to
        // fill, which widens the plaque without moving the knocked-out glyph — it reads as a lopsided
        // badge with too much padding on one side.
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .vertical)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .vertical)
        return badge
    }

    /// Hover text for the "in use" marker — the words the old `active` badge used to spell out, stating
    /// explicitly that the spending is happening *right now*.
    static let inUseHint = "Currently spending Extra Usage Credit — your plan limit is exhausted"

    /// VoiceOver label for the "in use" marker.
    static let inUseAccessibilityLabel = "currently spending Extra Usage Credit"

    /// The blocking-reset badge (#158): a red capsule carrying the reset countdown (e.g. "4d"), shown
    /// flush-right on the one row whose reset actually unblocks work. Same pill shape as the "in use"
    /// badge, filled with the exhausted red (`PopupBarView.gapRed`) so it reads as the blocker. A
    /// hover tooltip ("Effective blocker") explains why this one reset is highlighted.
    private func makeResetBadge(text: String) -> NSView {
        let pill = Self.makePill(text: text, fill: { PopupBarView.gapRed })
        pill.toolTip = Self.blockingResetHint
        return pill
    }

    /// Localisation seam for the blocking-reset badge's hover hint (#158).
    static let blockingResetHint = "Effective blocker"

    /// Shared pill factory (#146/#158): white medium text on a rounded, layer-backed capsule whose
    /// fill is `fill()` (re-resolved per appearance). Sizing comes from the text + insets; the radius is
    /// half the height, so it reads as a pill at any font size.
    private static func makePill(text: String, fill: @escaping () -> NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Metrics.textSize - 2, weight: .medium)
        label.textColor = ColorStore.shared.color(.pillText)
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = PillView()
        pill.fill = fill
        pill.wantsLayer = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        let hInset: CGFloat = 6, vInset: CGFloat = 2
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: hInset),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -hInset),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: vInset),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -vInset),
        ])
        return pill
    }

    @discardableResult
    private func addLabel(_ text: String, font: NSFont, secondary: Bool = false, color: NSColor? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color ?? (secondary ? Self.dimmedLabelColor : ColorStore.shared.color(.label))
        stack.addArrangedSubview(label)
        return label
    }

    /// The per-limit detail line: `used` percent flush left, `reset` countdown flush **right** against
    /// the content width — the percent leads the line (under the "% used" reading) while the reset time
    /// lines up with the bar's right edge below it.
    @discardableResult
    private func addDetailLine(used: String, reset: String, resetIsBlocking: Bool = false) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let usedLabel = NSTextField(labelWithString: used)
        usedLabel.font = font
        usedLabel.textColor = Self.dimmedLabelColor
        // When this reset is the one blocking work (#158), show it as a red **badge** so the eye lands on
        // the single reset that will actually unblock — every other reset stays the plain dimmed label,
        // even if its own limit is also exhausted.
        if resetIsBlocking {
            return addSplitRow(leadingView: usedLabel, rightView: makeResetBadge(text: reset))
        }
        let resetLabel = NSTextField(labelWithString: reset)
        resetLabel.font = font
        resetLabel.textColor = Self.dimmedLabelColor
        return addSplitRow(leftLabel: usedLabel, rightLabel: resetLabel)
    }

    /// A two-column row spanning the full content width: `left` flush against the leading edge,
    /// `right` flush against the trailing edge — the shared layout behind `addTitleStatusLine` and
    /// `addDetailLine`, both of which right-align their second half to line up with the bar beneath.
    @discardableResult
    private func addSplitLine(
        left: String, right: String, leftFont: NSFont, rightFont: NSFont,
        leftColor: NSColor, rightColor: NSColor
    ) -> NSView {
        let leftLabel = NSTextField(labelWithString: left)
        leftLabel.font = leftFont
        leftLabel.textColor = leftColor
        let rightLabel = NSTextField(labelWithString: right)
        rightLabel.font = rightFont
        rightLabel.textColor = rightColor
        return addSplitRow(leftLabel: leftLabel, rightLabel: rightLabel)
    }

    /// The shared layout behind every split line: a full-content-width horizontal row that pins
    /// `leftLabel` flush leading and `rightLabel` flush trailing. Callers build the two labels —
    /// plain (``addSplitLine``) or attributed (``addTitleStatusLine`` per-model heading) — this only
    /// arranges them.
    @discardableResult
    private func addSplitRow(leftLabel: NSTextField, rightLabel: NSTextField) -> NSView {
        addSplitRow(leadingView: leftLabel, rightLabel: rightLabel)
    }

    /// `addSplitRow` variant whose leading half is an arbitrary view (e.g. a `[title • badge]` stack),
    /// not just a label — the trailing label still pins flush right at the content width.
    private func addSplitRow(leadingView: NSView, rightLabel: NSTextField) -> NSView {
        addSplitRow(leadingView: leadingView, rightView: rightLabel)
    }

    /// `addSplitRow` variant whose **trailing** half is an arbitrary view (e.g. the blocking-reset
    /// pill, #158), not just a label — the leading view still pins flush left at the content width.
    @discardableResult
    private func addSplitRow(leadingView: NSView, rightView: NSView) -> NSView {
        let row = NSStackView(views: [leadingView, rightView])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        stack.addArrangedSubview(row)
        return row
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
        label.textColor = secondary ? Self.dimmedLabelColor : ColorStore.shared.color(.label)
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        let contentWidth = Metrics.contentWidth
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
        let font = NSFont.boldSystemFont(ofSize: Metrics.textSize)
        let color = ColorStore.shared.color(.red)
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

    /// Add a pacing bar for one ``LimitRow`` (token windows) — a thin wrapper over the raw
    /// ``addBar(bar:subdivisions:idle:isLast:)`` that unpacks the row's geometry.
    private func addBar(_ row: LimitRow, isLast: Bool, isBaseLimit: Bool) {
        addBar(bar: row.bar, subdivisions: row.subdivisions, idle: row.sessionIdle,
               blocked: row.sessionBlocked, isLast: isLast, isBaseLimit: isBaseLimit,
               tweenRow: row.title)
    }

    /// Add a pacing bar from raw geometry — shared by the token limit rows and the "Extra usage"
    /// credits section (#145), which has no ``LimitRow``. `subdivisions == 0` draws no tick ruler
    /// (the credits bar paces the whole calendar month, with no window boundaries to mark); `idle`
    /// draws the solid-blue knobless 5h track (#100). When `bar` is `nil` the view draws nothing —
    /// but callers only reach here with a real bar (idle uses the flag, not the layout).
    private func addBar(bar: BarLayout?, subdivisions: Int, idle: Bool, blocked: Bool = false,
                        isLast: Bool, isBaseLimit: Bool = false, tweenRow: String? = nil) {
        let view = PopupBarView()
        view.bar = bar
        // Colour-transition wiring (ADR-0070). `tweenRow` is the row's title for a limit window and
        // nil for the credits bar (which keys on `.credits`); the animator itself is owned by the
        // app delegate, so the state survives this view being rebuilt on the next update.
        view.colorAnimator = colorAnimator
        view.tweenRow = tweenRow
        // The colour walk only drives the 5-hour row; every other bar keeps its real geometry so it
        // stays a still reference beside the animated one (ADR-0070).
        view.frozenStripFraction = tweenRow == frozenStripRow ? frozenStripFraction : nil
        view.subdivisions = subdivisions
        view.idle = idle   // solid-blue knobless track when the 5h window is idle (#100)
        view.blocked = blocked   // grey instead of blue when that idle state is blocked (#158)
        view.isBaseLimit = isBaseLimit   // only base 5h/7d rows render the far-behind blue zone
        view.barStyle = barStyle   // pacing (gap+marker) vs simple (left-anchored ribbon) — #224
        view.showTicks = showTicks   // under-bar tick ruler on/off — #224
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        view.heightAnchor.constraint(equalToConstant: PopupBarView.viewHeight).isActive = true
        stack.addArrangedSubview(view)
        // Between-section gap after every bar except the last (the last sits above the menu separator).
        if !isLast { stack.setCustomSpacing(Metrics.limitSpacing, after: view) }
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
    private func addServiceStatusRow(label: String, status: ServiceStatus, age: TimeInterval? = nil) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)

        // Leading half: the colour dot (#130) as a glowing layer-backed subview (#188 — re-resolves on a
        // theme flip, unlike a baked image) + the component's display label (e.g. "API"). No status word
        // here — it is the trailing half, so every status word right-aligns into one column.
        let dot = makeStatusDot(status: status, animatorKey: label)
        dot.toolTip = status == .operational ? "operational" : "issue"
        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = font
        nameLabel.textColor = ColorStore.shared.color(.label)
        let leadingLabel = NSStackView(views: [dot, nameLabel])
        leadingLabel.orientation = .horizontal
        leadingLabel.alignment = .centerY
        leadingLabel.spacing = Metrics.statusDotGap
        // Dot flush-left with the rest of the widget's text (no extra leading inset), so the status
        // rows align on the same left edge as "5-hour"/"7-day" and the per-project rows (#233).

        // Trailing half, pinned flush-right: how long the component has been in this state, then the
        // status word. Operational → plain dimmed text (no link); otherwise → underlined link colour,
        // opened on click by StatusLineLabel over the word's range.
        //
        // The word keeps linking to the **general** status page rather than to a specific incident:
        // a component can be degraded by more than one incident at once (measured — two incidents
        // named the same four components), so there is no single right target here. The per-incident
        // link lives on the incident row, where the question "which one" has an answer (ADR-0071 §3).
        let wordLabel = Self.makeLinkWord(
            Self.word(status),
            url: status == .operational ? nil : StatusHealth.pageURL,
            prefix: age.map { Self.durationMinutes(Int($0)) + " · " })

        return addSplitRow(leadingView: leadingLabel, rightView: wordLabel)
    }

    /// The popup's status dot: a glowing, layer-backed circle whose colour re-resolves through the
    /// animator on every update (ADR-0070) rather than being baked once — so a status change fades
    /// and a light/dark flip repaints correctly.
    ///
    /// `animatorKey` distinguishes one dot's animation from another's. It used to be the display
    /// label, which meant two rows sharing a label would also share an animation; the incident rows
    /// pass their incident id, so each animates on its own.
    private func makeStatusDot(status: ServiceStatus, animatorKey: String) -> GlowDotView {
        let dot = GlowDotView()
        let animator = colorAnimator
        dot.fill = {
            let target = Self.dotColor(status)
            guard let animator else { return target }
            return animator.resolve(.serviceDot(surface: .popup, component: animatorKey), target: target)
        }
        dot.glowRadius = Self.dotGlowRadius
        dot.glowStrength = Self.dotGlowStrength
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Metrics.statusDotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Metrics.statusDotDiameter),
        ])
        return dot
    }

    /// A trailing label whose final word is a clickable link, optionally preceded by dimmed text.
    ///
    /// The click is handled explicitly by ``StatusLineLabel``: `NSTextField`'s built-in `.link`
    /// handling needs first-responder plumbing that does not work inside an `NSMenu`-hosted view
    /// (ADR-0013 §4). Passing `url: nil` yields plain dimmed text with no link and no hand cursor.
    private static func makeLinkWord(_ word: String, url: URL?, prefix: String? = nil) -> StatusLineLabel {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let attributed = NSMutableAttributedString()
        if let prefix {
            attributed.append(NSAttributedString(
                string: prefix, attributes: [.font: font, .foregroundColor: dimmedLabelColor]))
        }
        let wordStart = attributed.length
        // A linked word takes the link colour; an unlinked one (`operational`) takes the **label**
        // colour rather than the dimmed one. It is the answer to "can I work", so it should read as
        // content, not as a footnote — only the age beside it is secondary.
        attributed.append(NSAttributedString(string: word, attributes: url != nil
            ? [.font: font, .foregroundColor: ColorStore.shared.color(.link),
               .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: ColorStore.shared.color(.label)]))

        let label = StatusLineLabel(labelWithAttributedString: attributed)
        if let url {
            label.linkRange = NSRange(location: wordStart, length: (word as NSString).length)
            label.linkURL = url
        }
        return label
    }

    /// How long a component keeps its row after going green (#279). Without this the popup snaps from
    /// "two red rows" to completely blank the instant a fix lands, which reads exactly like "nothing
    /// was ever wrong" — the one moment a user most wants confirmation that it was, and is over.
    static let recoveryWindow: TimeInterval = 15 * 60

    /// Whether this component is `operational` but only recently became so — worth one more row.
    ///
    /// Leans on `components[].updated_at` (verified to move only on a status change), so the window
    /// is measured from the actual recovery rather than from when this process happened to notice —
    /// and therefore survives a relaunch mid-incident.
    static func isRecentlyRecovered(_ component: ResolvedComponent, now: Date) -> Bool {
        guard component.status == .operational, let age = component.stateAge(at: now) else { return false }
        return age < recoveryWindow
    }

    /// The episode subscribe row, when there is an episode to subscribe to.
    ///
    /// Shown in **both** dimensions and always in the same place: the control means the same thing
    /// with ⌥ held or not, so moving it between the two would read as two different controls. It is
    /// deliberately absent when nothing is wrong — there is nothing to be notified about, and a dead
    /// control is worse than none.
    @discardableResult
    private func addSubscribeRowIfNeeded(_ layout: PopupLayout) -> NSView? {
        guard let state = layout.subscription else { return nil }
        let row = SubscribeRowView(
            symbolName: Self.subscribeSymbol(state),
            text: Self.subscribeText(state),
            filled: state == .subscribed)
        row.onClick = { [weak self] in self?.onToggleSubscription?() }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    /// The SF Symbol for each subscribe state. It reports the **current state**, never the action a
    /// click would take: a toggle whose icon shows the action is the Play/Pause ambiguity, where the
    /// glyph reads equally as "this is the state" and "press for this".
    static func subscribeSymbol(_ state: EpisodeSubscriptionState) -> String {
        switch state {
        case .notSubscribed: return "bell.slash"
        case .subscribed:    return "bell.fill"
        // A pulse, not a wrench: `monitoring` means the repair is done and Anthropic is watching, so
        // a tool icon would say the opposite of what the stage means.
        case .fixDeployed:   return "waveform.path.ecg"
        }
    }

    /// The action text beside the icon. Exhaustive, no `default` — a new state must be worded.
    static func subscribeText(_ state: EpisodeSubscriptionState) -> String {
        switch state {
        case .notSubscribed: return "Notify me when it's fixed"
        case .subscribed:    return "Following the incidents"
        case .fixDeployed:   return "Fix deployed · monitoring"
        }
    }

    /// One incident row (#279): a severity dot, the incident's description, and `age · stage` set
    /// flush right **on the description's last line** — dropping to a line of its own when that line
    /// is too full to share.
    ///
    /// The description is the incident's `name`, which is all Statuspage offers: there is no separate
    /// description field, and the other text it carries (`incident_updates[]`) describes the current
    /// stage rather than the incident. Measured across 50 real incidents the median is 34 characters
    /// (one line) and the longest 107 (three), so `maxDescriptionLines` is insurance rather than an
    /// everyday truncation.
    ///
    /// The right-aligned chip is done with a tail-indented paragraph and a right tab stop rather than
    /// a second view: only text layout can put something on the *last wrapped line* of a paragraph,
    /// which a stack view cannot express. The stage word is the link, and unlike the service rows it
    /// points at **this** incident (`shortlink`) — ADR-0071 §3.
    @discardableResult
    private func addIncidentRow(_ incident: VisibleIncident, now: Date) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let dot = makeStatusDot(status: incident.severity, animatorKey: "incident-\(incident.id)")
        dot.toolTip = Self.word(incident.severity)

        let meta = Self.incidentMetaText(incident, now: now)
        let text = NSMutableAttributedString(
            string: incident.name + "\t",
            attributes: [.font: font, .foregroundColor: ColorStore.shared.color(.label)])

        let ageAndSeparator = meta.age.map { "\($0) · " } ?? ""
        if !ageAndSeparator.isEmpty {
            text.append(NSAttributedString(
                string: ageAndSeparator, attributes: [.font: font, .foregroundColor: Self.dimmedLabelColor]))
        }
        let stageStart = text.length
        text.append(NSAttributedString(string: meta.stage, attributes: incident.shortlink != nil
            ? [.font: font, .foregroundColor: ColorStore.shared.color(.link),
               .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: Self.dimmedLabelColor]))

        // A right tab stop at the content's trailing edge pulls everything after the tab flush right;
        // the description wraps ahead of it and the chip settles on whatever line it lands on.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: Self.incidentTextWidth)]
        // Word-wrapping, **not** truncating: a truncating line-break mode in the paragraph style
        // suppresses wrapping outright, so the description collapsed to a single elided line no
        // matter what `maximumNumberOfLines` said (measured: 16 pt tall for an 87-character name).
        // The line cap is enforced by `maximumNumberOfLines`, which still elides the last line.
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

        let label = StatusLineLabel(labelWithAttributedString: text)
        // `labelWithAttributedString` hands back a single-line field, and `usesSingleLineMode`
        // silently overrides `maximumNumberOfLines` — so the description would truncate at one line
        // no matter what the paragraph style said. Clearing it (and giving the cell a wrapping line
        // break) is what actually lets the text wrap.
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.maximumNumberOfLines = Self.maxIncidentDescriptionLines
        label.preferredMaxLayoutWidth = Self.incidentTextWidth
        if let shortlink = incident.shortlink {
            label.linkRange = NSRange(location: stageStart, length: (meta.stage as NSString).length)
            label.linkURL = shortlink
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        // Pin the text column so the right tab stop lands where the paragraph style expects; without
        // a fixed width the field sizes to its content and the chip drifts.
        label.widthAnchor.constraint(equalToConstant: Self.incidentTextWidth).isActive = true

        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Metrics.statusDotGap
        row.translatesAutoresizingMaskIntoConstraints = false
        // Centre the dot on the **first line** of the wrapped description, so it sits against the
        // text exactly as a service row's dot does — those rows get it from `.centerY`, which a
        // multi-line row cannot use (it would centre on the whole block and drift lower with every
        // extra line). Derived from the font rather than eyeballed: half the line height less half
        // the dot. At 13 pt that is 3.5, where a hand-picked 5 sat the dot 1.5 pt low.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let dotTop = (lineHeight - Metrics.statusDotDiameter) / 2
        dot.topAnchor.constraint(equalTo: row.topAnchor, constant: dotTop).isActive = true

        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    /// Width available to an incident's text: the content width less the dot and its gap. Also the
    /// location of the right tab stop the `age · stage` chip aligns to.
    static var incidentTextWidth: CGFloat {
        Metrics.contentWidth - Metrics.statusDotDiameter - Metrics.statusDotGap
    }

    /// How many lines an incident description may occupy before truncating. Three covers the longest
    /// name in a 50-incident sample (107 characters); beyond that the popup would grow without
    /// telling the user anything the linked page would not.
    static let maxIncidentDescriptionLines = 3

    /// The `age · stage` chip's two halves. Age is the **incident's** age (from `started_at`), not
    /// how long the current stage has lasted; it is `nil` when the start is unknown, in which case the
    /// row shows the stage alone rather than inventing a duration.
    static func incidentMetaText(_ incident: VisibleIncident, now: Date) -> (age: String?, stage: String) {
        (incident.age(at: now).map { durationMinutes(Int($0)) }, stageWord(incident.stage))
    }

    /// The human word for an incident's workflow stage. Exhaustive, no `default`, so a new case has
    /// to be worded consciously — the same discipline as ``word(_:)``. An unrecognised stage renders
    /// the server's own string rather than hiding the row.
    static func stageWord(_ stage: IncidentStage) -> String {
        switch stage {
        case .investigating:    return "investigating"
        case .identified:       return "identified"
        case .monitoring:       return "monitoring"
        case .resolved:         return "resolved"
        case .postmortem:       return "postmortem"
        case .unknown(let raw): return raw
        }
    }

    /// AppKit colour for one service status — the popup's indicator palette. Appearance-aware
    /// `system*` colours (not the fixed sRGB bar palette) so the dot keeps contrast on light and
    /// dark panels, exactly like the warning triangle's `.systemRed`. Exhaustive, no `default`.
    static func dotColor(_ status: ServiceStatus) -> NSColor {
        switch status {
        case .operational:      return ColorStore.shared.color(.green)
        case .degraded:         return ColorStore.shared.color(.yellow)
        case .partialOutage:    return ColorStore.shared.color(.orange)
        case .majorOutage:      return ColorStore.shared.color(.red)
        case .underMaintenance: return ColorStore.shared.color(.blue)
        case .unknown:          return ColorStore.shared.color(.gray)
        }
    }

    /// A `circle.fill` colour-dot text attachment, **baseline-nudged** so the dot sits on the text's
    /// optical centre rather than dropping to the baseline (#130). Shared by the popup's service-status
    /// rows and the update menu item, so both align identically — like the menu-bar widget's dot.
    ///
    /// A raw symbol attachment aligns its *bottom* to the text baseline, which leaves a round dot
    /// sitting visibly low next to lowercase text. Raising `bounds.origin.y` by roughly the gap between
    /// the font's cap height and the dot's height centres it. `fontSize` defaults to the dropdown text
    /// size (the popup rows and menu items share it); `pointSize` is the symbol's own size. Returns
    /// `nil` only if the system symbol can't be created (never, in practice).
    static func dotAttachment(
        color: NSColor,
        accessibility: String,
        pointSize: CGFloat = 9,
        fontSize: CGFloat = dropdownTextSize
    ) -> NSTextAttachment? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: accessibility)?
            .withSymbolConfiguration(config) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = symbol
        // Lift the dot to the cap-height optical centre: (capHeight − dotHeight) / 2, rounded. Keeps the
        // dot vertically centred against uppercase text instead of resting on the baseline.
        let font = NSFont.systemFont(ofSize: fontSize)
        let dotHeight = symbol.size.height
        let rise = ((font.capHeight - dotHeight) / 2).rounded()
        attachment.bounds = CGRect(x: 0, y: rise, width: symbol.size.width, height: dotHeight)
        return attachment
    }

    /// Ambient-glow parameters for the popup service-status dots (#188 — `GlowDotView`).
    static let dotGlowRadius: CGFloat = 5
    static let dotGlowStrength: CGFloat = 0.75

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

    /// The popup label for one monitored component (#89) — the localisation seam: the kit carries the
    /// component's matching name (`ResolvedComponent.name`), and the short label the user reads is
    /// assembled here (ADR-0009/0013). Each monitored component gets its own row (`Cowork` is its own
    /// line, not a suffix), so the mapping is per-component. Names are shown bare (no "Claude" prefix)
    /// under the "Claude" section header. An unrecognised name falls back to itself, so a future
    /// component still renders rather than vanishing.
    static func displayName(_ component: ResolvedComponent) -> String {
        switch component.name {
        case StatusHealth.claudeAPIComponentName:    return "API"
        case StatusHealth.claudeCodeComponentName:   return "Code"
        case StatusHealth.claudeWebComponentName:    return "Web/Desktop"
        case StatusHealth.claudeCoworkComponentName: return "Cowork"
        default:                                     return component.name
        }
    }

    // MARK: - Pure text formatters (the localisation seam)

    /// The per-limit detail line's **left**-aligned half: `"20% used"`.
    ///
    /// The qualifier earns its place under #307: on the **Pressure** scale the capsule's far edge is
    /// no longer `usageFraction` — the ribbon measures pressure against the time left, not the level
    /// spent — so this number is the only place the quota consumed is stated. Paired with the reset
    /// on the right, the line reads "how much is gone ↔ when it comes back".
    ///
    /// The `"used"` noun is an **⌥ detail** — at rest the line is the bare `"20%"`. Both halves of the
    /// detail line drop their words together (`resetText`), so holding Option turns
    /// `"20%   2h at 02:50"` into the full sentence `"20% used   resets in 2h at 02:50"` and the
    /// resting line stays as narrow as the numbers themselves.
    ///
    /// Token rows only; the credits section has its own `creditsAmountText` (money, not a percentage).
    static func usedText(_ row: LimitRow, verbose: Bool = false) -> String {
        verbose ? "\(percent(row.utilization)) used" : percent(row.utilization)
    }

    /// The per-limit detail line's **right**-aligned half: the unified reset line
    /// (`ResetClock.resetLine`) — `"20h at 03:00"` for a near reset, `"5d on Friday"` /
    /// `"7d next Monday"` for a far one, `"15d"` for a distant one — or `"resetting…"` when the model
    /// carries no line (reset is now/past). One shape for every limit, credits included (#167).
    ///
    /// Under ⌥ the line switches to the layout's precomputed verbose form, which prepends
    /// `"resets in"` — the same gate `usedText` uses, so both halves gain their words at once. The
    /// `"resetting…"` fallback is already a sentence and is unchanged by the gate.
    static func resetText(_ row: LimitRow, verbose: Bool = false) -> String {
        (verbose ? row.resetLineVerbose : row.resetLine) ?? "resetting…"
    }

    /// Data-age threshold past which the header timestamp is shown **unconditionally** (not just under
    /// ⌥): `2 ×` the healthy base poll cadence (`PollingEngine.baseInterval`, 180 s → 360 s / 6 min).
    /// Below it the data is at most one missed poll old — normal jitter — so the age stays an on-demand
    /// ⌥ detail; past two full cadences a poll has clearly been missed and the age is worth surfacing on
    /// its own. Derived from the engine cadence so the two never drift.
    static let staleAgeThreshold: TimeInterval = PollingEngine.baseInterval * 2

    /// The data age shown flush-right in the "Claude Code" header (under the ⌥/stale gate):
    /// `"2m ago"`, or `"just now"` for anything under a full minute — the age never shows seconds
    /// (user preference), so a sub-minute age reads as "just now", not "40s".
    static let justNowThreshold = 60
    static func ageText(_ ageSeconds: TimeInterval) -> String {
        let age = Int(ageSeconds)
        return age < justNowThreshold
            ? "just now"
            : "\(durationMinutes(age)) ago"
    }

    /// Like ``duration`` but **never** emits a seconds component — minutes are the finest unit, so
    /// the data-age text stays second-free even just past the minute boundary.
    ///
    /// Compound values are written closed-up (`2h7m`, not `2h 7m`): the duration is one quantity, and
    /// spacing it invites the eye to read two. It matters most in the status rows, where the age sits
    /// against a `·` separator and a status word — three gaps in a row made the line hard to parse.
    static func durationMinutes(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let m = minutes % 60
            return m == 0 ? "\(hours)h" : "\(hours)h\(m)m"
        }
        let days = hours / 24
        let h = hours % 24
        return h == 0 ? "\(days)d" : "\(days)d\(h)h"
    }

    // MARK: Warning banner (issue #12)

    /// The bold first line of the warning banner — a short title per failure cause. For an HTTP
    /// auth error it embeds the status code; the body text goes on the detail line below.
    static func warningTitle(_ reason: FailureReason) -> String {
        switch reason {
        case .notSignedIn:               return "Missing auth token"
        case .tokenExpired:              return "Auth token expired"
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
        case .tokenExpired:
            return "Refreshing via the claude CLI — open Claude Code if this persists"
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

    /// Pacing/severity in words. Severity (critical/warning) wins over the plain pacing direction. When
    /// ahead of pace, the wording grades with the gap colour (see ``PopupBarView/aheadColor``): a lead
    /// that reads orange (`≥` the dynamic threshold, or `≤ 20 min` to reset) is "well ahead of pace"; a
    /// smaller one (yellow) stays "ahead of pace".
    ///
    /// The pacing colour (green→yellow→orange→red) now carries the "how far ahead" signal on its own,
    /// so we no longer append a `⚠` glyph in the `.warning` band (usage > 90 % before 90 % of the
    /// window elapsed) — that was a statusline carry-over, and our bar has outgrown it. `.warning` and
    /// `.neutral` now read the same "(well) ahead of pace" wording; only the exhausted rung (`.critical`,
    /// `usage == 100`) still gets its own "limit reached".
    private static func statusText(_ row: LimitRow, isBaseLimit: Bool) -> String {
        // Idle 5-hour row (#100): "ready to start" instead of a pacing phrase — there is no active
        // window to pace. When that idle state is also blocked (#158 — 7d exhausted, credits cannot
        // cover) it becomes "waiting for limit reset". Guarded first so the inert placeholder
        // indicator/pacing are never consulted.
        if row.sessionIdle { return row.sessionBlocked ? blockedStatusText : idleStatusText }
        if row.indicator == .critical { return "limit reached" }
        if row.pacing == .ahead { return aheadPhrase(row) }
        // On-pace/behind side: base 5h/7d bars read "far behind pace" when the gap is blue
        // (``PopupBarView/behindColor``); everything closer to the line (and all per-model rows) is
        // "on pace". Word and colour agree via ``isFarBehind(_:)`` (gated by `isBaseLimit`).
        return (isBaseLimit && isFarBehind(row.bar)) ? "far behind pace" : "on pace"
    }

    /// "well ahead of pace" when the bar reads orange (the ``isWellAhead(_:)`` condition), else "ahead
    /// of pace" (yellow). Same threshold as the gap colour, so word and colour agree.
    private static func aheadPhrase(_ row: LimitRow) -> String {
        isWellAhead(row.bar) ? "well ahead of pace" : "ahead of pace"
    }

    /// Whether this bar reads **orange** (well ahead of pace) — the exact complement of the `<` yellow
    /// test in ``PopupBarView/aheadColor``, so the wording and the gap colour always agree: orange when
    /// the window resets in `≤ 20 min` (``PacingModel/pacingOrangeOverrideSeconds``), or when the lead
    /// is `≥` the dynamic threshold (``PacingModel/aheadThreshold(timeFraction:)``).
    private static func isWellAhead(_ bar: BarLayout) -> Bool {
        if bar.remainingSeconds <= PacingModel.pacingOrangeOverrideSeconds { return true }
        return (bar.usageFraction - bar.timeFraction) >= PacingModel.aheadThreshold(timeFraction: bar.timeFraction)
    }

    /// Whether this bar reads **blue** (far behind pace) — the exact match of the `>` blue test in
    /// ``PopupBarView/behindColor``, so the wording and the gap colour always agree: on the
    /// on-pace/behind side, past the 20-min start override, with a surplus `>` the fixed-width
    /// ``PacingModel/behindThreshold(windowDurationSeconds:)``. The caller gates this on `isBaseLimit` so only
    /// the base 5h/7d rows (which render blue) get the "far behind pace" wording.
    private static func isFarBehind(_ bar: BarLayout) -> Bool {
        guard bar.pacing == .onPaceOrBehind else { return false }
        if bar.behindMultiplier == 0 { return false }   // FarBehindInterval.off → never blue
        let elapsed = Double(bar.windowDurationSeconds) - bar.remainingSeconds
        if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return false }
        return (bar.timeFraction - bar.usageFraction) > PacingModel.behindThreshold(windowDurationSeconds: bar.windowDurationSeconds, multiplier: bar.behindMultiplier)
    }

    // MARK: Extra usage (money-credits) formatters (#145)

    /// The credits section's status word (limit set), from the pacing bar — the money counterpart of
    /// ``statusText(_:)``. Uses the **same** thresholds/wording family as the token bars so the two
    /// agree at a glance:
    /// - cap reached (`usageFraction >= 1`) → "limit reached" (the red rung of `aheadColor`);
    /// - ahead of pace (`usage > time`) → "ahead of pace" / "well ahead of pace" by the ``isWellAhead(_:)``
    ///   condition (the yellow→orange split, matching ``aheadPhrase(_:)``);
    /// - otherwise (`.onPaceOrBehind`, incl. the tie) → "on pace".
    static func creditsStatusText(_ bar: BarLayout) -> String {
        if bar.usageFraction >= 1 { return "limit reached" }
        guard bar.pacing == .ahead else { return "on pace" }
        return isWellAhead(bar) ? "well ahead of pace" : "ahead of pace"
    }

    /// The detail line's **left** half when a cap is set: `"€10.8 of €15"` at rest, the exact
    /// `"€10.77 of €15.00"` under ⌥ — spent out of limit, both formatted from their exact ``Money``
    /// integers (never a rounded `Double`).
    ///
    /// The precision is an **⌥ detail**, the same gate `usedText`/`resetText` use: at rest the amounts
    /// carry three significant digits so the line stays as narrow as the numbers themselves, and holding
    /// Option reveals every cent of both.
    ///
    /// At rest the two halves are formatted **differently on purpose**: the spend keeps the ladder
    /// (``compactMoneyText(_:)``), the cap additionally drops a zero fraction
    /// (``CompactMoney/capText(_:)`` → `€15`, not `€15.0`). They are different kinds of number — the
    /// spend moves and its precision carries information, the cap is a constant the user typed into
    /// billing, and every captured limit is whole. Under ⌥ both go exact, so the asymmetry exists only
    /// in the narrow resting form.
    static func creditsAmountText(spent: Money, limit: Money, verbose: Bool = false) -> String {
        guard !verbose else { return "\(moneyText(spent)) of \(moneyText(limit))" }
        return "\(compactMoneyText(spent)) of \(CompactMoney.capText(limit))"
    }

    /// The **unlimited** line's right half: `"€10.8 spent"` — the spent amount with a trailing word,
    /// no cap and no reset (there is nothing to pace against). Same ⌥ precision gate as
    /// ``creditsAmountText(spent:limit:verbose:)``: three significant digits at rest, exact under Option.
    static func creditsSpentOnlyText(_ spent: Money, verbose: Bool = false) -> String {
        "\(verbose ? moneyText(spent) : compactMoneyText(spent)) spent"
    }

    /// Format a ``Money`` for display. For a **known** currency the symbol sits in that currency's
    /// standard position — `"$10.77"` and `"€10.77"` (symbol before) but `"10,77 kr"` (symbol after) —
    /// resolved by `NumberFormatter`'s `.currency` style, which carries ICU's per-currency placement
    /// and grouping. For an **unknown** currency there is no reliable symbol/placement, so we render
    /// the amount followed by the ISO code — `"12.00 UAH"`.
    ///
    /// The amount always comes from the **integer** minor units + exponent (`amount_minor / 10^exponent`),
    /// so no representation error creeps into the shown value; `NumberFormatter` is asked for exactly
    /// `exponent` fraction digits (not the currency's own default) so the value we computed is what
    /// shows. The currency is resolved from the code — never hard-coded to USD (the spike saw EUR, #142).
    static func moneyText(_ money: Money) -> String {
        let value = Double(money.amountMinor) / pow(10, Double(money.exponent))
        let digits = max(0, money.exponent)
        if isKnownCurrency(money.currency), let text = currencyFormatted(value, code: money.currency, digits: digits) {
            return text
        }
        // Unknown currency → amount then ISO code (e.g. "12.00 UAH"); no symbol/placement to trust.
        let amount = String(format: "%.\(digits)f", value)
        let code = money.currency.isEmpty ? "" : " \(money.currency.uppercased())"
        return "\(amount)\(code)"
    }

    /// The resting, **three-significant-digit** form of a ``Money`` — the credits line's default, with
    /// the exact ``moneyText(_:)`` reserved for ⌥. Delegates to ``CompactMoney/text(_:)`` in the Kit,
    /// where the ladder (and its rounding boundaries) is unit-tested; see that type for the table.
    static func compactMoneyText(_ money: Money) -> String {
        CompactMoney.text(money)
    }

    /// Whether we treat this ISO code as "known" — mirrors ``StatusItemView/creditsSymbolName(for:)``
    /// so the menu-bar glyph and the dropdown label agree on which currencies get a symbol vs. a code.
    static func isKnownCurrency(_ code: String) -> Bool {
        ["EUR", "USD", "GBP", "JPY", "CNY", "INR"].contains(code.uppercased())
    }

    /// `NumberFormatter`-formatted currency string with the symbol in the currency's standard position
    /// and exactly `digits` fraction digits. Returns `nil` if formatting fails (caller falls back to the
    /// code form). A fixed `en_US_POSIX` base locale keeps grouping/decimal marks deterministic across
    /// the user's locale while `currencyCode` still drives the symbol and its placement.
    private static func currencyFormatted(_ value: Double, code: String, digits: Int) -> String? {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US_POSIX")
        f.currencyCode = code.uppercased()
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        guard let s = f.string(from: NSNumber(value: value)) else { return nil }
        // en_US_POSIX inserts a NBSP (U+00A0, or narrow NBSP U+202F) between a leading symbol and the
        // digits (rendered as `€ 10.77`); the conventional form is `€10.77`. Strip that space only when
        // it sits between a non-digit (the symbol) and the first digit — a trailing-symbol currency's
        // space (`10,77 kr`) is preceded by a digit, so it is left untouched.
        return s.replacingOccurrences(
            of: "(?<=\\D)[\u{00A0}\u{202F}](?=\\d)", with: "", options: .regularExpression)
    }

}
