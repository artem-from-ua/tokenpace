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
    /// Mirror of `StatusItemView.barStyle` — keep the two draw paths in sync. Default `.pacing`.
    var barStyle: BarStyle = .pacing {
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

    private enum Metrics {
        /// Height of the pacing bar itself (the coloured zones + indicator dot).
        static let barHeight: CGFloat = 6
        static let corner: CGFloat = 2
        /// Width of the time-indicator marker — a slim vertical bar, narrower than the old dot so it
        /// reads as a crisp position tick rather than a blob.
        static let indicatorWidth: CGFloat = 6
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
        let w = rect.width

        // Idle 5h bar (#100, ADR-0027): a solid blue track + the under-bar tick ruler, but no pacing
        // zones and no time-indicator dot ("no active session, full quota available"). Rendered before
        // the pacing path so the (inert, zeroed) `bar` layout is never consulted.
        if idle {
            let idlePath = NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner)
            // Blocked idle (#158) → grey (no path to start); otherwise the "ready to start" blue.
            // Grey (blocked) is an already-translucent neutral — leave it; only the blue hue is tinted (#188).
            if blocked {
                Self.monochromeGrey.setFill()
                idlePath.fill()
            } else {
                // The solid idle strip carries the same ambient glow as a pacing strip (#188).
                let idleColor = Palette.idleBlue
                withGlow(idleColor, radius: Self.idleGlowRadius, strength: Self.idleGlowStrength) {
                    idleColor.setFill()
                    idlePath.fill()
                }
            }
            drawTicks(in: rect, width: w)
            return
        }

        guard let l = bar else { return }

        // Pacing-gap colour.
        let gapColor: NSColor
        if l.pacing == .ahead {
            gapColor = Self.aheadColor(usage: l.usageFraction, time: l.timeFraction, remainingSeconds: l.remainingSeconds)
        } else {
            // Calm side: base 5h/7d bars split green↔blue via behindColor; per-model/credits stay green.
            gapColor = isBaseLimit ? Self.behindColor(l) : Palette.gapGreen
        }

        // 1. Full-length grey track (rounded), drawn first as the base.
        Self.monochromeGrey.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner).fill()

        // 2. Coloured strip laid exactly over its span, both ends fully rounded (capsule). Pace & Time uses
        //    the gap `gapStart..gapEnd`; Simple uses a left-anchored ribbon `0..(gapEnd-gapStart)`. A flush
        //    end rounds identically to the grey bar's own cap, so it reads as one continuous rounded edge.
        //    3. The strip carries the ambient glow.
        let stripFrom = barStyle.popupShowsTimeMarker ? l.gapStart : 0
        let stripTo = barStyle.popupShowsTimeMarker ? l.gapEnd : (l.gapEnd - l.gapStart)
        let sx0 = rect.minX + CGFloat(stripFrom) * w
        let sx1 = rect.minX + CGFloat(stripTo) * w
        if sx1 > sx0 {
            let capsule = rect.height / 2
            let stripRect = NSRect(x: sx0, y: rect.minY, width: sx1 - sx0, height: rect.height)
            let stripPath = NSBezierPath(roundedRect: stripRect, xRadius: capsule, yRadius: capsule)
            withGlow(gapColor, radius: Self.gapGlowRadius, strength: Self.gapGlowStrength) {
                gapColor.setFill()
                stripPath.fill()
            }
        }

        drawTicks(in: rect, width: w)

        // Simple style (#224): no time marker — the ribbon above already conveys pacing by colour + length.
        if !barStyle.popupShowsTimeMarker { return }

        // 4. Time-indicator marker at `timeFraction`: a slim rounded vertical bar filled with the pacing
        //    colour, with a border in the grey-track tone (blended 85 %) that separates it from the strip —
        //    replacing the old transparent slivers. 5. The marker carries a stronger ambient glow.
        // Pixel-snap the marker's centre x so its vertical edges land on whole pixels — a fractional
        // `timeFraction * w` otherwise smears the thin border across two columns (the "crooked outline").
        let cx = (rect.minX + CGFloat(l.timeFraction) * w).rounded()
        let cy = rect.midY
        let mw = Metrics.indicatorWidth
        let mh = Metrics.indicatorHeight
        let markerRect = NSRect(x: cx - mw / 2, y: cy - mh / 2, width: mw, height: mh)
        let marker = NSBezierPath(
            roundedRect: markerRect, xRadius: Metrics.indicatorCorner, yRadius: Metrics.indicatorCorner)
        let markerColor = indicatorColor(l)
        // Border as a filled frame (not a centred stroke, which straddles the edge and reads crooked on a
        // 6-pt marker): fill the outer rounded rect in the grey-track-toned border colour, then fill an
        // inset rounded rect in the marker colour on top — leaving a crisp `bw`-wide even border. The whole
        // thing carries the ambient glow.
        let bw: CGFloat = 1
        let border = (Self.monochromeGrey.blended(withFraction: 0.4, of: markerColor) ?? Self.monochromeGrey)
            .withAlphaComponent(0.9)
        let innerRect = markerRect.insetBy(dx: bw, dy: bw)
        let inner = NSBezierPath(roundedRect: innerRect,
                                 xRadius: max(0, Metrics.indicatorCorner - bw),
                                 yRadius: max(0, Metrics.indicatorCorner - bw))
        withGlow(markerColor, radius: Self.markerGlowRadius, strength: Self.markerGlowStrength) {
            border.setFill()
            marker.fill()
            markerColor.setFill()
            inner.fill()
        }
    }

    /// Draw the under-bar tick ruler: vertical teeth at each interior window boundary
    /// (`k / subdivisions` for `k` in `1 ..< subdivisions`), pixel-snapped on x. No-op when
    /// `subdivisions < 2` (nothing to subdivide).
    private func drawTicks(in barRect: NSRect, width: CGFloat) {
        guard showTicks, subdivisions >= 2 else { return }   // #224 — tick ruler opt-out
        let top = barRect.maxY + Metrics.tickGap           // flipped: just below the bar
        let bottom = top + Metrics.tickLength
        Palette.tick.setFill()
        // Rounded (capsule) teeth — corner = half the width so the ends read soft, not blocky.
        let corner = Metrics.tickWidth / 2
        for k in 1 ..< subdivisions {
            let f = CGFloat(k) / CGFloat(subdivisions)
            // Pixel-snap the tooth's centre so it stays crisp at @1x and @2x.
            let cx = (barRect.minX + f * width).rounded()
            let rect = NSRect(x: cx - Metrics.tickWidth / 2, y: top, width: Metrics.tickWidth, height: bottom - top)
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
        }
    }

    private func indicatorColor(_ l: BarLayout) -> NSColor {
        // The dot uses the exact pacing-bar colours so it reads as the same colour as the gap zone it
        // sits over, not a separate shade. A tie (usage == time) is still on pace → green/blue.
        if l.usageFraction > l.timeFraction {
            return Self.aheadColor(usage: l.usageFraction, time: l.timeFraction, remainingSeconds: l.remainingSeconds)
        }
        // Calm side: base 5h/7d bars split green↔blue via behindColor; per-model/credits stay green.
        return isBaseLimit ? Self.behindColor(l) : Palette.gapGreen
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
    /// Bar strip glow: a large, soft, low-intensity halo.
    private static let gapGlowRadius: CGFloat = 21
    private static let gapGlowStrength: CGFloat = 0.25
    /// Idle-bar glow: half the pacing-strip radius (the idle strip spans the whole bar, so a big halo
    /// reads as too much), twice the strength.
    private static let idleGlowRadius: CGFloat = 10.5
    private static let idleGlowStrength: CGFloat = 0.5
    /// Marker glow: a touch stronger than the bar.
    private static let markerGlowRadius: CGFloat = 10
    private static let markerGlowStrength: CGFloat = 0.7

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

// MARK: - PillView

/// A small rounded, layer-backed badge — the "in use" badge beside the "Extra usage" heading (#146,
/// #224 exhausted red) and the blocking-reset badge on a limit row (#158, the exhausted red). The
/// corner radius is a fraction of the height (`cornerFraction`) — a softly rounded rect rather than a
/// full pill (#224) — and the fill CGColor is re-resolved in `updateLayer()` because CGColor is not
/// appearance-dynamic (the standard layer-backed dark/light trap).
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


    /// Whether ⌥ Option is currently held (ADR-0020's modifier-poll timer feeds this live while the
    /// dropdown is open). It reveals the on-demand data age ("2m ago") in the "Claude Code" header;
    /// it does **not** gate the service-status rows, which show only when a component is
    /// non-operational (`rebuild()`'s `showStatusRows`) — two green lines are never worth the space.
    var optionHeld = false {
        didSet {
            guard isViewLoaded, optionHeld != oldValue else { return }
            rebuild()
        }
    }

    /// Bar presentation style (#224), governing every bar in the popup. Pushed into each `PopupBarView`
    /// during `rebuild()` → `addBar`. Child bars are built fresh on each rebuild, so a change here must
    /// rebuild (not just redraw) to reach them — mirrors `optionHeld`. Default `.pacing`.
    var barStyle: BarStyle = .pacing {
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

    private enum Metrics {
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
        // The service status rows (issue #31, #89) show **only when there is a real problem** —
        // `worstProblem != nil`, i.e. at least one monitored component is non-operational. All-
        // operational lines add nothing worth the space, so a healthy status is never shown. When a
        // problem is present we show **only the problematic components** by default; holding ⌥ Option
        // reveals **all** monitored components (the healthy ones for context: `API`, `Code`,
        // `WEB/Desktop`, `Cowork` when enabled).
        let status = layout.serviceStatus
        let showStatusRows = status?.worstProblem != nil
        let showAge = optionHeld || layout.lastUpdateAge >= Self.staleAgeThreshold
        let ageString = showAge ? Self.ageText(layout.lastUpdateAge) : ""
        // Header layout (#233): the "Claude" brand title with the "Nm ago" age beside it on the left;
        // the awaiting-input indicator (hand + count) pinned flush right. When there's no awaiting count,
        // fall back to the plain brand-left / age-right split line.
        let sectionHeader: NSView
        if let awaiting = layout.awaitingInput {
            // "Claude  <age>" together on the left. On the right: the summary badge when ⌥ is up;
            // nothing when ⌥ is held (the per-project breakdown below supersedes it — but the age
            // stays put next to "Claude", it does not move to where the badge was). (#233)
            let brand = NSTextField(labelWithString: Self.claudeCodeSectionTitle)
            brand.font = Self.menuItemFont
            brand.textColor = Self.claudeBrandColor
            let age = NSTextField(labelWithString: ageString)
            age.font = .systemFont(ofSize: Metrics.textSize)
            age.textColor = Self.dimmedLabelColor
            let leading = NSStackView(views: [brand, age])
            leading.orientation = .horizontal
            leading.alignment = .firstBaseline
            leading.spacing = 8
            let right: NSView = optionHeld ? NSView() : makeAwaitingBadge(awaiting)
            sectionHeader = addSplitRow(leadingView: leading, rightView: right)
        } else {
            sectionHeader = addSplitLine(
                left: Self.claudeCodeSectionTitle, right: ageString,
                leftFont: Self.menuItemFont, rightFont: .systemFont(ofSize: Metrics.textSize),
                leftColor: Self.claudeBrandColor, rightColor: Self.dimmedLabelColor)
        }
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
            // Default: only the non-operational components. ⌥ Option: every monitored component.
            let components = status.checks.flatMap(\.components)
                .filter { optionHeld || $0.status.isProblem }
            for component in components {
                lastRow = addServiceStatusRow(label: Self.displayName(component), status: component.status)
            }
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
        for (index, row) in layout.rows.enumerated() {
            addTitleStatusLine(title: row.title, status: Self.statusText(row, isBaseLimit: index <= 1))
            // The idle 5-hour row (#100) has **no** second line at all — no "0%", no reset — so it reads
            // as a compact "5-hour  ready to start" (or "waiting for limit reset" when blocked, #158) +
            // solid bar. Every other row shows the detail; its reset goes red when it is *the* blocking
            // reset (the "last stand" pick from `layout.blockingReset`).
            if !row.sessionIdle {
                addDetailLine(
                    used: Self.usedText(row), reset: Self.resetText(row),
                    resetIsBlocking: Self.isBlockingRow(index, in: layout))
            }
            // No inter-section gap after the **last** bar — but only when there is no credits section
            // below. If the "Extra usage" block follows, this bar is *not* the last thing in the popup,
            // so it needs the normal inter-section gap; the credits block then owns the tight-to-separator
            // bottom instead.
            let isLastLimitRow = index == layout.rows.count - 1
            // The far-behind blue zone is restricted to the base 5h/7d rows. `PopupLayout.rows`
            // always emits them first (index 0 = 5h, 1 = 7d); everything appended after is a
            // per-model / per-service row and stays green on the calm side.
            addBar(row, isLast: isLastLimitRow && layout.credits == nil, isBaseLimit: index <= 1)
        }

        // The "Extra usage" (money-credits) section (#145), rendered below the limit windows when
        // credits are active for this snapshot. Two shapes, keyed by whether a cap is set — see
        // `addCreditsSection`. Absent (`layout.credits == nil`) → nothing is drawn.
        if let credits = layout.credits {
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
    ///   €10.77 / €15.00 ........... 5d on Friday
    ///   ```
    ///   plus a pacing bar (same `PopupBarView`, coloured by `credits.bar` via `aheadColor`).
    /// - **Unlimited** (`credits.bar == nil`): a single bare line, no bar, no reset —
    ///   ```
    ///   Extra usage ............... €10.77 spent
    ///   ```
    ///
    /// The heading "Extra usage" is styled like the limit-window titles (plain `labelColor`, not the
    /// brand-coloured "Claude" header): the section reads from its numbers and bar, not a heavy heading.
    private func addCreditsSection(_ credits: CreditsRow, resetIsBlocking creditsResetIsBlocking: Bool = false) {
        guard let bar = credits.bar, let limit = credits.limit else {
            // Unlimited: "Extra usage … €X.XX spent". No bar, no reset line — no cap to pace.
            addTitleStatusLine(title: Self.extraUsageTitle, status: Self.creditsSpentOnlyText(credits.spent))
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
            badge: credits.inUse ? makeInUsePill() : nil)
        addDetailLine(
            used: Self.creditsAmountText(spent: credits.spent, limit: limit),
            reset: credits.resetLine ?? "resetting…",
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
        // count order. Label colour; only the hand carries the bucket colour (per maintainer).
        if count >= 2 || showCountForOne {
            let countLabel = NSTextField(labelWithString: "\(count)")
            countLabel.font = .systemFont(ofSize: size)
            countLabel.textColor = ColorStore.shared.color(.label)
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

    /// The **"in use"** pill shown next to the "Extra usage" heading while paid credits are actually
    /// covering an exhausted plan limit (`CreditsRow.inUse`). A small rounded, layer-backed capsule in
    /// the exhausted **red** (`PopupBarView.gapRed`, #224 — was accent blue) with white text, so it reads
    /// as a warning that a limit is spent onto paid credit. Sizing comes from the text + insets.
    private func makeInUsePill() -> NSView {
        Self.makePill(text: Self.inUseBadgeText, fill: { PopupBarView.gapRed })
    }

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

    /// Localisation seam for the credits "active" badge text.
    static let inUseBadgeText = "active"

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
               blocked: row.sessionBlocked, isLast: isLast, isBaseLimit: isBaseLimit)
    }

    /// Add a pacing bar from raw geometry — shared by the token limit rows and the "Extra usage"
    /// credits section (#145), which has no ``LimitRow``. `subdivisions == 0` draws no tick ruler
    /// (the credits bar paces the whole calendar month, with no window boundaries to mark); `idle`
    /// draws the solid-blue knobless 5h track (#100). When `bar` is `nil` the view draws nothing —
    /// but callers only reach here with a real bar (idle uses the flag, not the layout).
    private func addBar(bar: BarLayout?, subdivisions: Int, idle: Bool, blocked: Bool = false,
                        isLast: Bool, isBaseLimit: Bool = false) {
        let view = PopupBarView()
        view.bar = bar
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
    private func addServiceStatusRow(label: String, status: ServiceStatus) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)

        // Leading half: the colour dot (#130) as a glowing layer-backed subview (#188 — re-resolves on a
        // theme flip, unlike a baked image) + the component's display label (e.g. "API"). No status word
        // here — it is the trailing half, so every status word right-aligns into one column.
        let dot = GlowDotView()
        let dotStatus = status
        dot.fill = { Self.dotColor(dotStatus) }
        dot.glowRadius = Self.dotGlowRadius
        dot.glowStrength = Self.dotGlowStrength
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.toolTip = status == .operational ? "operational" : "issue"
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Metrics.statusDotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Metrics.statusDotDiameter),
        ])
        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = font
        nameLabel.textColor = ColorStore.shared.color(.label)
        let leadingLabel = NSStackView(views: [dot, nameLabel])
        leadingLabel.orientation = .horizontal
        leadingLabel.alignment = .centerY
        leadingLabel.spacing = Metrics.statusDotGap
        // Dot flush-left with the rest of the widget's text (no extra leading inset), so the status
        // rows align on the same left edge as "5-hour"/"7-day" and the per-project rows (#233).

        // Trailing half: the status word, pinned flush-right. Operational → plain dimmed text (no link);
        // otherwise → underlined link colour, opened on click by StatusLineLabel over the word's range.
        let word = Self.word(status)
        let isLink = status != .operational
        let wordAttributed = NSAttributedString(string: word, attributes: isLink
            ? [.font: font, .foregroundColor: ColorStore.shared.color(.link), .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: Self.dimmedLabelColor])
        let wordLabel = StatusLineLabel(labelWithAttributedString: wordAttributed)
        if isLink {
            wordLabel.linkRange = NSRange(location: 0, length: (word as NSString).length)
            wordLabel.linkURL = StatusHealth.pageURL
        }

        return addSplitRow(leadingView: leadingLabel, rightView: wordLabel)
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

    /// The per-limit detail line's **left**-aligned half: `"20%"` — the bare utilisation percentage.
    static func usedText(_ row: LimitRow) -> String { percent(row.utilization) }

    /// The per-limit detail line's **right**-aligned half: the unified reset line
    /// (`ResetClock.resetLine`) — `"20h at 03:00"` for a near reset, `"5d on Friday"` /
    /// `"7d next Monday"` for a far one, `"15d"` for a distant one — or `"resetting…"` when the model
    /// carries no line (reset is now/past). One shape for every limit, credits included (#167).
    static func resetText(_ row: LimitRow) -> String {
        row.resetLine ?? "resetting…"
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

    /// The detail line's **left** half when a cap is set: `"€10.77 / €15.00"` — spent over limit, both
    /// formatted from their exact ``Money`` integers (never a rounded `Double`).
    static func creditsAmountText(spent: Money, limit: Money) -> String {
        "\(moneyText(spent)) / \(moneyText(limit))"
    }

    /// The **unlimited** line's right half: `"€10.77 spent"` — the spent amount with a trailing word,
    /// no cap and no reset (there is nothing to pace against).
    static func creditsSpentOnlyText(_ spent: Money) -> String {
        "\(moneyText(spent)) spent"
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
