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

    /// Whether this is the **idle** 5-hour bar (#100, ADR-0027): a green knobless pill (no pacing
    /// zones, no time-indicator dot) for a 5h window with no active session. The under-bar tick ruler
    /// still draws (`subdivisions`), keeping the row's anatomy in family with the active bars.
    var idle: Bool = false {
        didSet {
            guard idle != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether this idle bar is **blocked** (#158): the 7-day limit is exhausted and paid credits cannot
    /// cover, so the pill is drawn **grey** (`monochromeGrey`) instead of the "ready" green —
    /// "waiting for a limit to reset", not "ready to start". Only meaningful alongside ``idle``.
    var blocked: Bool = false {
        didSet {
            guard blocked != oldValue else { return }
            needsDisplay = true
        }
    }

    // No `weeklyHeadroom` here since #381: the idle "ready" fill is green whatever the week is doing, so
    // the bar no longer needs the weekly verdict alongside its inert layout.

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

    /// Bar presentation style for **this surface** (#224, per-surface since #329) — fed from
    /// `PersistedConfig.dropdownStyle` and pushed in from `PopupViewController.addBar`.
    /// ``BarStyle/progress`` draws the gap + time-indicator marker + gap dividers;
    /// ``BarStyle/pressure`` a left-anchored ribbon; ``BarStyle/balance`` a centre-anchored one. The
    /// last two keep the under-bar tick ruler but have no marker or dividers.
    ///
    /// Independent of `StatusItemView.barStyle` since #329 — the user picks each surface separately,
    /// so the two are expected to differ. What keeps the draw paths honest is that both branch on
    /// `BarStyle.scale`, not on the case.
    var barStyle: BarStyle = .progress {
        didSet {
            guard barStyle != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether ⌥ Option is currently held — the gate on the under-bar ruler (teeth *and* the credits
    /// bar's month captions). Pushed in from `PopupViewController.addBar`, whose own `optionHeld`
    /// rebuilds every bar the moment the modifier changes, so the ruler appears and disappears live
    /// while the dropdown is open.
    ///
    /// The ruler is on-demand rather than permanent because it explains a scale the reader only needs
    /// while interrogating a bar: at rest the coloured strip and its marker carry the reading on their
    /// own, and a permanent row of teeth under every bar is the densest thing in an otherwise quiet
    /// popup. ⌥ already means "show me the detail behind this number" everywhere else in this surface
    /// (verbose reset lines, data age, folded sections), so the ruler joins that tier instead of
    /// carrying a preference of its own.
    var optionHeld: Bool = false {
        didSet {
            guard optionHeld != oldValue else { return }
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

    /// The captions for a **credits** bar's two boundary ticks — the money window's first and last day
    /// (`"Aug 1"`, `"Aug 31"`), precomputed in `CreditsRow.monthBounds`. Non-`nil` **only** on the
    /// Extra-usage bar, where it is also what puts the view into its calendar-month presentation:
    ///
    /// - the bar draws as **Progress** regardless of the user's `BarStyle` (see ``effectiveScale``), and
    /// - the tick ruler is replaced by two captioned boundary teeth instead of window subdivisions.
    ///
    /// Both halves come from the same fact — this bar's window is a calendar month, not a rolling limit
    /// window — so they are driven by one property rather than by two independently-settable flags that
    /// could disagree. `nil` leaves every existing bar exactly as it was.
    var monthBounds: (start: String, end: String)?

    private enum Metrics {
        /// Height of the pacing bar itself (the coloured zones + indicator dot).
        static let barHeight: CGFloat = 6
        /// Corner radius of the track **and** of the coloured strip laid over it (#326). Nudged up from
        /// the shipped 2 on a 6 pt bar; the strip and the idle pill now take this value instead of
        /// rounding as capsules (`min(w,h)/2` = 3), so two shapes stacked in one bar share one corner.
        /// The menu bar keeps its own 1.5 — the two surfaces are tuned separately.
        static let corner: CGFloat = 2.25
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
        /// Width of the **zero tick** — the permanent mark for the zero each marker-less ribbon grows
        /// out of: Balance's centre and Pressure's origin. Documented here, computed at the draw site.
        ///
        /// A **fraction of the zero pill's width** rather than a constant: the tick marks the position
        /// that pill sits at, so it is sized against the pill and follows it if the bar's height ever
        /// moves. At a flat 1.5 pt it read as a thin sliver poking out from behind a wider shape; at the
        /// pill's full 3.5 pt it read as a slab. Five sevenths (2.5 pt on the shipped 6 pt bar) sits
        /// where it looks like the pill continued past the track's edges — clearly the same vertical,
        /// visibly narrower than the shape it belongs to.
        ///
        /// Still well under the time marker's 7 pt, so the mark that identifies Pressure/Balance cannot be
        /// confused with the one that identifies Progress — and the rest of the argument (neutral,
        /// static, hidden under the track) is untouched by the width.
        static let zeroTickPillFraction: CGFloat = 5.0 / 7.0
        /// How many times its own track the zero tick stands — the menu bar's proportion
        /// (`StatusItemView.Metrics`: a 10 pt mark over a 5 pt bar), carried here as a ratio rather than
        /// read from that type, which keeps its metrics private. Change it there and this comment is the
        /// thing to check.
        static let zeroTickHeightRatio: CGFloat = 10.0 / 5.0
        /// Height of the **zero tick**, **scaled** from the menu bar's rather than offset from the bar:
        /// the popup's 6 pt track earns 12 pt by the same ratio its 5 pt track earns 10. Scaling rather
        /// than copying the 2 pt per-side overhang is what keeps the mark looking like *the same mark* on
        /// a taller bar — a fixed overhang would read progressively stubbier as the track grows.
        static let zeroTickHeight: CGFloat = barHeight * zeroTickHeightRatio
        /// How much of the tick ink's own alpha the zero tick keeps — the popup's copy of
        /// `StatusItemView.Metrics.zeroTickAlpha`, for the same reason: scale furniture must settle
        /// behind the one mark on the bar that actually moves.
        static let zeroTickAlpha: CGFloat = 0.55
        /// Total view height: the **marker** and nothing more. The marker is centred on the bar and so
        /// overhangs it by `(indicatorHeight − barHeight)/2` on each side; that is the whole reserve.
        ///
        /// The tick ruler is deliberately **not** reserved for (#388). It used to add `tickGap +
        /// tickLength` on top of the marker, which bought 7 pt of empty strip under every bar — and
        /// two of the three styles draw no ruler at all (ADR-0098), so on those the strip was pure
        /// air. Because a bar sits at the end of each limit block, that air read as extra space
        /// *between blocks*: the gap under "Claude" measured its honest `sectionSpacing`, while the
        /// gap between blocks measured `limitSpacing` **plus** the reserve — 10 pt of setting looking
        /// like 25. The ticks now draw into the marker's own bottom overhang, where they are thin
        /// enough (2 pt wide, `tertiaryLabelColor`) to need no clearance of their own.
        static let height: CGFloat = indicatorHeight
    }

    /// The fixed view height (bar + under-bar tick ruler), exposed so `PopupViewController` can pin
    /// the hosted bar's height constraint to the same value the view draws into.
    static var viewHeight: CGFloat { Metrics.height }

    /// The width the live bar is drawn at inside the popup card, exposed so the Settings preview can be
    /// checked against it.
    static var liveWidth: CGFloat { PopupViewController.Metrics.contentWidth }

    /// The height of the **track** — the bar proper, without the marker's overhang or the ruler's
    /// reserved strip. This is the shape a reader sees as "the bar", so it is the unit to lay a stack of
    /// bars out by.
    static var trackHeight: CGFloat { Metrics.barHeight }

    /// How far the time marker stands proud of the track on each side, which is also the distance from
    /// the frame ``render(in:)`` is handed to the track it draws inside it.
    ///
    /// Exposed together with ``trackHeight`` for callers that position bars by their track rather than
    /// by their frame — the Settings preview tile, where no ruler is drawn and `viewHeight`'s reserved
    /// strip would otherwise push the pair off centre. Both restate `Metrics`, which is private, so they
    /// track it instead of being copied at the call site.
    static var markerOverhang: CGFloat {
        max(0, (Metrics.indicatorHeight - Metrics.barHeight) / 2)
    }

    /// How far the tick ruler reaches **below** the track — its gap plus a tooth.
    ///
    /// ``viewHeight`` deliberately excludes this (#388): the live popup shows the teeth only under ⌥,
    /// and reserving the strip permanently read as padding under every bar. A caller that draws a bar
    /// *with* its ruler — the Legend page — has to add the depth back, or the canvas clips the teeth
    /// part-way down and the specimen misreports their size.
    static var rulerDepth: CGFloat { Metrics.tickGap + Metrics.tickLength }

    /// The blank the teeth hang across before they begin.
    ///
    /// Exposed alongside ``rulerDepth`` because a caller placing something *under* the ruler needs the
    /// two apart: the depth says where the teeth end, this says how much of it was never ink. The
    /// Legend page's captions subtract it so the clear space under the lowest mark matches the space
    /// over the highest one.
    static var tickGap: CGFloat { Metrics.tickGap }

    // MARK: - Effective presentation

    /// The scale this bar is actually **drawn** on — the user's `BarStyle` choice, except on the
    /// credits bar, which is always the **window** scale (i.e. Progress).
    ///
    /// Extra usage is the one bar whose window is a calendar month. Money spends in bursts once a plan
    /// limit is exhausted, so a pace-relative ribbon says little about it, whereas "how much of the cap,
    /// how far into the month" is exactly the pair of positions the window scale marks. Its two
    /// captioned boundary ticks (``monthBounds``) name that window on the bar itself, which is what
    /// keeps a Progress bar sitting in a Pressure/Balance column from reading as a bug: it is visibly a
    /// *different ruler*, not the same one behaving oddly.
    ///
    /// Every render branch reads this rather than `barStyle.scale` — a mixed pair would draw a
    /// ribbon on one scale and its marker on another.
    private var effectiveScale: BarScale {
        monthBounds != nil ? .window : barStyle.scale
    }

    /// Whether this bar draws the time-indicator marker, derived from ``effectiveScale`` exactly as
    /// `BarStyle.showsTimeMarker` derives it from the style's scale: the marker has a position
    /// **only** on the window scale.
    private var effectiveShowsTimeMarker: Bool { effectiveScale == .window }

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
        static var gapGreen: NSColor { ColorRole.green.defaultColor }
        static var gapRed: NSColor { ColorRole.red.defaultColor }
        static var gapYellow: NSColor { ColorRole.yellow.defaultColor }
        static var gapOrange: NSColor { ColorRole.orange.defaultColor }
        /// The **far-behind** pacing gap (deep behind pace / big surplus) on the base 5h/7d bars —
        /// `.systemBlue` via the shared `blue` role, the same one the idle fill and the maintenance dot
        /// use. Chosen by `behindColor` when the surplus clears the behind-threshold and the weekly
        /// gate is open; otherwise green.
        static var gapBlue: NSColor { ColorRole.blue.defaultColor }

        /// Indicator-dot ring: a soft separation between the dot and the bar beneath it. `separatorColor`
        /// — the unified `indicatorRing` role, the same semantic hairline the menu-bar ring uses.
        static var indicatorStroke: NSColor { ColorRole.indicatorRing.defaultColor }

        /// Tick-ruler marks below the bar: `tertiaryLabelColor` (the `.tick` role) — a muted neutral that
        /// flips light/dark and reads weaker than the indicator dot.
        static var tick: NSColor { ColorRole.tick.defaultColor }

        /// The **zero tick** struck through the bar — the same `centreTick` role the menu bar's mark
        /// uses, not the `.tick` ruler tone beside it. Deliberately shared: the two surfaces draw the
        /// *same* piece of scale furniture, so they must move together under the tuner rather than
        /// drifting apart the first time either tone is adjusted.
        ///
        /// Faded to ``Metrics/zeroTickAlpha`` through a **dynamic** `NSColor(name:)` that applies the
        /// alpha *inside* `performAsCurrentDrawingAppearance`, for the same reason ``monochromeGrey``
        /// does its blend there: the role's default is the dynamic `labelColor`, and calling
        /// `withAlphaComponent` on it at the draw site resolves it against whatever appearance happens
        /// to be current — which, in an `NSMenu`-hosted view, is not reliably the one being drawn. That
        /// bakes the dark tone into the light theme and vice-versa. Resolving per appearance is what
        /// makes the mark follow the system's light/dark setting, exactly as the menu bar's does.
        ///
        /// The role is resolved **outside** the provider closure on purpose: `defaultColor` is
        /// `@MainActor`, and the closure is not isolated — inlining the lookup into it does not compile.
        static var zeroTick: NSColor {
            let role = ColorRole.centreTick.defaultColor
            return NSColor(name: nil) { appearance in
                var faded = role
                appearance.performAsCurrentDrawingAppearance {
                    let resolved = role.usingColorSpace(.sRGB) ?? role
                    faded = resolved.withAlphaComponent(
                        resolved.alphaComponent * Metrics.zeroTickAlpha)
                }
                return faded
            }
        }

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

    /// Overrides the track tone for **this** bar, or `nil` to use ``monochromeGrey``.
    ///
    /// Exists for the Legend page (#261) and nothing else. The popup's grey is tuned to be barely
    /// there: it sits on a vibrant card among rows of text, where the track's job is to be the absence
    /// of colour rather than a shape in its own right. On a Settings form the same tone all but
    /// disappears — the plate behind it is flatter and lighter, and the bar is no longer surrounded by
    /// content telling the reader where it is. A legend whose specimen is hard to see fails at the one
    /// thing it exists for.
    ///
    /// A per-instance override rather than a brighter shared constant, because the popup is right for
    /// the popup: raising the shipped grey would repaint every live bar to fix a page none of them are
    /// on.
    var trackTint: NSColor?

    /// The tone this bar's base zones actually draw in.
    private var trackColour: NSColor { trackTint ?? Self.monochromeGrey }

    /// Scales the time marker's halo for **this** bar. `1` is the shipped glow.
    ///
    /// Also for the Legend page, and for the same reason as ``trackTint``: the popup's glow is tuned
    /// against a vibrant card, where a marker has to lift off a busy surface. On a flat Settings form
    /// it blooms instead — the halo reads as part of the mark, and the diagram's callout then points at
    /// something fuzzier than the 7 pt it is naming.
    var markerGlowScale: CGFloat = 1

    /// The marker halo's radius after ``markerGlowScale``.
    private var markerGlow: CGFloat { Self.markerGlowRadius * markerGlowScale }


    /// The exhausted-pacing red (`aheadColor`'s cap rung). Exposed so the popup can paint the **one**
    /// blocking reset time red (#158) in the same tone the bars use for an exhausted limit. Computed (not
    /// a `static let`) for the same appearance-freshness reason as ``monochromeGrey``.
    static var gapRed: NSColor { Palette.gapRed }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.height) }

    override func draw(_ dirtyRect: NSRect) { render(in: bounds) }

    /// Draw the whole bar into `rect`. Shared by ``draw(_:)`` and ``snapshotImage()``.
    ///
    /// Split out of `draw(_:)` for the Settings preview tiles (#374): a specimen baked off `bounds`
    /// could only ever be the size the live view happens to have, and the tile is narrower. Routing
    /// both callers through one draughtsman is what stops the preview from drifting away from the live
    /// bar — the same seam `StatusItemView.render(in:)` provides for the menu-bar tiles (#373).
    func render(in bounds: NSRect) {
        // The bar sits below a top margin equal to the marker's overhang — the marker is centred on
        // the bar, so a marker taller than the bar sticks out by `(height − barHeight)/2` on each side;
        // the margin keeps that top overhang inside the view (the tick ruler fills the strip below).
        let overhang = max(0, (Metrics.indicatorHeight - Metrics.barHeight) / 2)
        let rect = NSRect(
            x: bounds.minX, y: bounds.minY + overhang, width: bounds.width, height: Metrics.barHeight)

        // Idle 5h bar (#100, ADR-0027): no pacing zones, "no active session".
        // Rendered before the pacing path so the (inert, zeroed) `bar` layout is never consulted.
        //
        // Idle is drawn the same way in **both** styles (#325): the bare grey track, plus a zero-length
        // mark at the left edge — the minimum pill any zero-length ribbon draws. Progress adds its
        // identifying time marker on top, parked at `timeFraction` = 0 (the window has just rolled, so
        // no time has elapsed); the marker covers the pill, so the two styles differ only by that mark.
        //
        // Progress used to fill the whole track solid blue, which read as a Pressure bar at *full*
        // pressure — the loudest possible mark for the calmest possible state, and the exact confusion
        // the per-style shapes were meant to prevent. Zero usage is zero on both scales, so zero is what
        // both draw.
        if idle {
            // Blocked idle (#158) → grey (no path to start); otherwise green (ADR-0105).
            // Grey (blocked) is an already-translucent neutral — leave it; only the blue hue is tinted (#188).
            // Animated so idle→active reads as a fade (ADR-0070); the glow follows automatically
            // because it is derived from this same colour.
            // Two-way since #381: grey when blocked (no path to start), **green** whenever ready. It was
            // three-way (#331 follow-up), with blue standing for "ready, and the week has quota to burn"
            // — a second claim layered onto "ready" and carried by the same pill, which needed
            // `PacingModel.weeklyHasHeadroom` threaded through an inert row to stay honest. The claim is
            // dropped rather than moved: idle answers one question. The weekly gate still does its real
            // work on every *active* row's `blueAllowed` (ADR-0081), and the menu bar drops the same
            // distinction in the same release, so the two surfaces cannot disagree about idle.
            let idleTarget = blocked ? trackColour : ColorRole.green.defaultColor
            let idleColor = blocked ? idleTarget : animated(idleTarget, part: .fill)
            // The zero tick goes down BEFORE the track: the track then covers its middle and only the
            // ends stand proud, which is what keeps it from reading as a time marker.
            drawZeroTick(in: rect)
            // The grey track goes down first, exactly as the pacing path does — without it the mark
            // hangs in empty space while every neighbouring row shows a track.
            trackColour.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner).fill()
            // Balance's zero is the centre, so its idle pill sits there (ADR-0078's shape, drawn on this
            // style's own scale) — struck through by the zero tick laid down just above.
            if let idleShape = Self.pillRect(at: effectiveScale == .centred ? 0.5 : 0, in: rect) {
                // Same corner as the track and every other strip (#326) — idle is a zero-length ribbon,
                // so it must not be shaped differently from one.
                let corner = min(Metrics.corner, min(idleShape.width, idleShape.height) / 2)
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
            if effectiveShowsTimeMarker { drawTimeMarker(at: 0, colour: idleColor, in: rect) }
            return
        }

        guard let l = bar else { return }

        // Pacing-gap colour, routed through the transition layer so a threshold crossing fades
        // instead of blinking (ADR-0070).
        let gapColor = animated(gapColorTarget(l), part: .fill)

        // 0. The zero tick, struck through the bar BEFORE the track so the track covers its middle and
        //    only the ends stand proud — the same order the menu bar draws it in, and what stops a
        //    vertical mark from reading as the time marker.
        drawZeroTick(in: rect)

        // 1. Full-length grey track (rounded), drawn first as the base.
        trackColour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner).fill()

        // 2. Coloured strip laid exactly over its span, both ends fully rounded (capsule). Progress uses
        //    the gap `gapStart..gapEnd` on the window scale; Pressure uses a left-anchored ribbon
        //    `0..pressureLength` on the renormalised `[now..reset]` scale (#307). A flush end rounds
        //    identically to the grey bar's own cap, so it reads as one continuous rounded edge.
        //    3. The strip carries the ambient glow.
        // The `color-cycle` stub pins the strip so only the colour moves (`frozenStripFraction`); it
        // overrides the length, so the stub is unaffected by the rescale.
        // Balance (#326, ADR-0079) measures from the bar's CENTRE — the span is `0.5 .. 0.5 + offset/2`
        // taken in whichever order the sign puts them, so the ribbon's direction carries ahead vs
        // behind. The other two scales are unchanged: Progress the window-scale gap, Pressure the
        // left-anchored ribbon.
        let balanceFar = 0.5 + (frozenStripFraction.map { $0 * 2 - 1 } ?? l.balanceOffset) / 2
        let stripFrom: Double
        let stripTo: Double
        switch effectiveScale {
        case .window:
            stripFrom = frozenStripFraction != nil ? 0 : l.gapStart
            stripTo = frozenStripFraction ?? l.gapEnd
        case .remaining:
            stripFrom = 0
            stripTo = frozenStripFraction ?? l.pressureLength
        case .centred:
            stripFrom = min(0.5, balanceFar)
            stripTo = max(0.5, balanceFar)
        }
        // A **zero-length** Pressure ribbon still has to read as "zero", not as an empty track: with no
        // marker the ribbon is this bar's only mark, and `stripRect` returns nil for a degenerate span.
        // `usage == time` is a real recurring state (every 5-hour reset renders 0 % against a freshly
        // rolled `resets_at`), so floor it to the pill — mirroring `StatusItemView`'s
        // `fillZone(floorEmptyToPill:)`, which has always done this in the menu bar. Progress is
        // deliberately excluded: there an empty gap means "dead on pace" and the marker carries the
        // position.
        // Progress pins the strip's start: its left edge is `usage`, so the min-width floor and the
        // flush-to-track snap must not drag it leftwards into the "already spent" zone (#323).
        // The pill floor applies to both marker-less scales: Pressure floors its zero at the left edge,
        // Balance floors its zero at the centre (`stripFrom == 0.5` there, since a degenerate span has
        // both ends on the zero). `pinsStart` stays exclusive to Progress — on the centred scale both
        // edges are data and the floor must grow symmetrically about the zero.
        let ribbon = Self.stripRect(from: stripFrom, to: stripTo, in: rect,
                                    pinsStart: frozenStripFraction == nil && effectiveScale == .window,
                                    anchoredAt: effectiveScale == .centred ? 0.5 : nil)
        // Whether the ribbon degenerated and the pill floor took over — read off the fallback itself
        // rather than re-measured from the resulting width, which would depend on `minStripWidth`
        // rounding and quietly stop matching if that floor ever changes.
        let collapsedToPill = ribbon == nil && effectiveScale != .window
        let span = ribbon
            ?? (effectiveScale == .window ? nil : Self.pillRect(at: stripFrom, in: rect))
        if let stripRect = span {
            // The track's corner, not a capsule's (#326) — two shapes in one bar share one corner.
            let capsule = min(Metrics.corner, min(stripRect.width, stripRect.height) / 2)
            let stripPath = NSBezierPath(roundedRect: stripRect, xRadius: capsule, yRadius: capsule)
            // Knock a transparent gutter out of the grey track under a **yellow** strip (#326), 1.5 pt
            // proud of it on either side, so the panel behind shows through and separates the strip
            // from the track. Yellow is the one pacing colour close enough in luminance to the
            // light-theme track to lose its edge against it; every other state separates on hue or
            // darkness already, so they keep a plain track and the geometry stays put.
            //
            // `.clear` with `.copy` REPLACES the track's pixels rather than blending over them — plain
            // `.sourceOver` of a clear colour is a no-op. Clipped to the track's own rounded path so
            // the cut can never escape the bar.
            if isYellow(gapColor) {
                let gutter = stripRect.insetBy(dx: -Self.yellowGutter, dy: 0)
                // The SAME radius as the strip, so the cut is the strip's own shape, just wider.
                let r = min(capsule, min(gutter.width, gutter.height) / 2)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: Metrics.corner, yRadius: Metrics.corner).addClip()
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setFill()
                NSBezierPath(roundedRect: gutter, xRadius: r, yRadius: r).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            // A Pressure ribbon that collapsed to its zero pill gets the tighter, brighter halo (#381):
            // the quiet side has no width to carry colour there, so the ambient glow — sized for a full
            // ribbon — leaves the mark looking unlit. Quiet states only; a warning's ribbon has length of
            // its own and does not need lifting.
            let isCollapsedQuietPill = effectiveScale == .remaining && l.isCalm && collapsedToPill
            if isCollapsedQuietPill {
                // Widest first, then narrower: each pass composites over the last, so the light stacks up
                // where they overlap and falls off outward. See the radius constants for why three passes
                // rather than one larger `strength`.
                for radius in [Self.pillHaloRadius, Self.pillMidGlowRadius, Self.pillGlowRadius] {
                    withGlow(gapColor, radius: radius, strength: Self.pillGlowStrength) {
                        gapColor.setFill()
                        stripPath.fill()
                    }
                }
            } else {
                withGlow(gapColor, radius: Self.gapGlowRadius, strength: Self.gapGlowStrength) {
                    gapColor.setFill()
                    stripPath.fill()
                }
            }
        }

        drawTicks(in: rect)

        // Simple style (#224): no time marker — the ribbon above already conveys pacing by colour + length.
        if !effectiveShowsTimeMarker { return }

        // 4. Time-indicator marker at `timeFraction`. 5. It carries a stronger ambient glow.
        // Under the `color-cycle` stub the marker parks at the pinned strip's end, so Progress keeps
        // its full anatomy (strip + marker) while still holding the geometry still.
        drawTimeMarker(at: frozenStripFraction ?? l.timeFraction, colour: indicatorColor(l), in: rect)
    }

    // MARK: NSImage snapshot

    /// Render this bar to a non-template `NSImage` `width` points wide, for the Settings preview tiles.
    ///
    /// Width is a parameter rather than read from the view because ``intrinsicContentSize`` deliberately
    /// leaves it `noIntrinsicMetric` — the live bar stretches to the popup card (320 pt), while a tile
    /// specimen is a fraction of that. Height comes from ``Metrics/height``, unscaled: the tile shows the
    /// bar and marker at their real thickness, so what the picture promises is what the dropdown draws.
    ///
    /// Drawn **eagerly** inside the caller's `performAsCurrentDrawingAppearance` block, for the reason
    /// `StatusItemView.snapshotImage()` documents at length: the lazy `NSImage(size:flipped:)` handler
    /// resolves dynamic colours whenever the image is later composited, which on this surface would bake
    /// the wrong theme's neutrals into the tile.
    func snapshotImage(width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: Metrics.height)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        render(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        return image
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
        // A **dynamic** colour, for the same reason `Palette.monochromeGrey` and `Palette.zeroTick` are:
        // `blended(withFraction:of:)` resolves its receiver against whatever appearance is current *at
        // the call site*, and this one is built during layout rather than inside a drawing block. The
        // live popup gets away with it because the view is drawn in its own real appearance; a caller
        // that renders the same view into an image under an explicitly chosen appearance does not.
        //
        // Measured: computed here, the border came out 13,96,26 under **both** themes — the dark tone
        // baked into the light one. Resolved per appearance it is 185,239,190 in dark against 13,96,26
        // in light, which is the pair the live bar shows.
        // Captured before the closure so the dynamic colour does not hold the view alive — it outlives
        // this call, and `trackColour` is a plain lookup with nothing to gain from being deferred.
        let track = trackColour
        let border = NSColor(name: nil) { appearance in
            var blended = track
            appearance.performAsCurrentDrawingAppearance {
                blended = (track.blended(withFraction: 0.4, of: colour)
                    ?? track).withAlphaComponent(0.9)
            }
            return blended
        }
        let innerRect = markerRect.insetBy(dx: bw, dy: bw)
        let inner = NSBezierPath(roundedRect: innerRect,
                                 xRadius: max(0, Metrics.indicatorCorner - bw),
                                 yRadius: max(0, Metrics.indicatorCorner - bw))
        withGlow(colour, radius: markerGlow, strength: Self.markerGlowStrength) {
            border.setFill()
            marker.fill()
            colour.setFill()
            inner.fill()
        }
    }

    // MARK: - Inset scale (min-strip geometry)

    /// The minimum width of the coloured strip — so a near-zero span renders as a rounded "pill"
    /// (a short capsule with fully-rounded ends) rather than a hairline sliver.
    ///
    /// Was a flat ¾ of the bar height; **narrowed by 1 pt** (#326) so the smallest mark reads as a
    /// mark rather than a blob. That makes the pill 2.75 pt on the 5 pt menu-bar track and 3.5 pt on
    /// the 6 pt popup one — no longer a fixed ratio of the height, which is deliberate: the floor
    /// exists to keep a tiny span *visible*, and visibility does not scale with the bar the way its
    /// corner radius does.
    ///
    /// This is the single knob for the whole inset geometry, not just the floor: ``scaleX`` insets the
    /// 0..1 scale by half of it at each end, so every fraction on both surfaces — strips, pills, the
    /// time marker, the tick ruler and Balance's centre tick — shifts with this number, and all of them
    /// stay aligned with each other because they read it from here.
    static func minStripWidth(_ rect: NSRect) -> CGFloat { 0.75 * rect.height - 1 }

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
    static func stripRect(from: Double, to: Double, in rect: NSRect, pinsStart: Bool = false,
                          anchoredAt anchor: Double? = nil) -> NSRect? {
        var sx0 = scaleX(CGFloat(from), in: rect)
        var sx1 = scaleX(CGFloat(to), in: rect)
        guard sx1 > sx0 else { return nil }
        let msw = minStripWidth(rect)
        if sx1 - sx0 < msw {
            if pinsStart {
                // Grow rightwards only — the left edge is `usage` and must not drift under the marker.
                sx1 = sx0 + msw
            } else if anchor != nil {
                // Handled below — the anchored overlap covers the degenerate case too, so there is
                // nothing to widen here: growing about the span's own midpoint first would only move
                // the very edge the overlap then has to put back.
            } else {
                let c = (sx0 + sx1) / 2
                sx0 = c - msw / 2
                sx1 = c + msw / 2
            }
        }
        // Balance (#326): the end that sits ON the zero overlaps it by half the pill's width, in whichever
        // direction the ribbon runs. Without this the strip merely *begins* at `scaleX(0.5)` and its
        // rounded cap curves away from there, while the centre tick is *centred* on the same x — so the
        // colour visibly retreats from the tick by a cap's radius, in mirror image on each side (a
        // right-running ribbon pulls away rightwards, a left-running one leftwards). Overlapping makes
        // the ribbon read as growing OUT OF the zero rather than starting near it, and it subsumes the
        // min-width floor: a degenerate span becomes exactly the centred pill, which is what it was.
        if let anchor {
            let c = scaleX(CGFloat(anchor), in: rect)
            let half = msw / 2
            if sx0 >= c - half { sx0 = c - half }        // ribbon runs right: extend back over the zero
            if sx1 <= c + half { sx1 = c + half }        // ribbon runs left: extend forward over it
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
    /// - **Pressure** and **Balance** carry **no teeth at all** (ADR-0098). Window subdivisions have no
    ///   position on either track — an hour boundary is not at a fixed fraction of the time remaining
    ///   — and the landmark each scale *does* define is its **zero**, which is already drawn
    ///   unconditionally by ``drawZeroTick(in:)`` and captioned `0` under ⌥. A second, unlabelled
    ///   tooth a few points from a labelled zero read as a stray mark rather than as a reading.
    ///
    ///   Pressure's zero is `0` and Balance's is `0.5` (``zeroTickFraction``) — that mark is also what
    ///   tells the two styles apart at a glance, and it is the same one the menu bar draws
    ///   (`StatusItemView.drawZeroTick`); that surface carries only the identifying half, since ⌥
    ///   cannot reach it. Pressure once marked `0.20` here, back when its zero sat left of `t`; since
    ///   ADR-0101 the scale's zero *is* `u == t`, so the two marks would coincide even if it had not
    ///   already been dropped.
    ///
    /// The original objection to a tick under Pressure — a lone vertical tooth is exactly what the
    /// Progress time marker looks like, so the styles would stop being distinguishable — is answered by
    /// **construction** rather than by omission: a fifth the width, in the neutral tick tone, drawn
    /// *under* the track so only its ends show, and never moving.
    ///
    /// - **Credits** (``monthBounds`` set) draws **no teeth at all** — its month ruler is the pair of
    ///   captions alone (``drawBoundaryCaptions(in:)``). Interior subdivisions are wrong there (months
    ///   are 28–31 days, so no equal split lands on a real boundary), and boundary teeth turned out to
    ///   be redundant once the ends were named: the words already sit at the ends they label, so the
    ///   teeth added marks without adding information — and a tooth at `1` sits close enough to a
    ///   late-month time marker to read as clutter beside it.
    ///
    /// Keyed off the bar's presentation alone: `drawTicks` also runs for the **idle** bar, which has no
    /// `BarLayout` to consult.
    private var tickFractions: [CGFloat] {
        // Credits: captions only — the month ruler carries no teeth.
        if monthBounds != nil { return [] }
        switch effectiveScale {
        // Neither marker-less style carries a tooth here: both are marked by their **zero** alone
        // (``zeroTickFraction``), captioned `0` under ⌥. Pressure's old 0.20 "exactly on pace" landmark
        // was dropped by ADR-0098 — a second unlabelled tooth a few points from a labelled zero read as
        // a stray mark — and ADR-0101 moved the scale's zero onto `u == t`, so that landmark is now the
        // zero itself rather than a separate position.
        case .remaining, .centred: return []
        case .window:
            guard subdivisions >= 2 else { return [] }
            return (1 ..< subdivisions).map { CGFloat($0) / CGFloat(subdivisions) }
        }
    }

    /// The scale's **zero** — the position the ribbon grows out of, or `nil` for a style that has none
    /// to show. Balance's is its centre, Pressure's the left end of the renormalised track; **Progress is
    /// deliberately untouched**, since its time marker already carries a position and a second vertical
    /// mark beside it would read as a competing one.
    ///
    /// Drawn **unconditionally**, unlike the rest of the ruler: this mark is what tells the two
    /// marker-less styles apart at a glance — a line through the middle is Balance, a line at the left end
    /// is Pressure — so hiding it behind ⌥ would take away the thing that identifies the style. The
    /// landmarks that merely *explain* the scale stay on demand.
    ///
    /// Credits is excluded with the rest of the ruler: it is pinned to Progress and its scale is a
    /// calendar month, which has no zero a ribbon grows from.
    private var zeroTickFraction: CGFloat? {
        guard monthBounds == nil else { return nil }
        switch effectiveScale {
        case .remaining: return 0
        case .centred:   return 0.5
        case .window:    return nil
        }
    }

    /// Draw the **zero tick**: a line struck through the whole bar at ``zeroTickFraction``, in the
    /// neutral tick tone, drawn *under* the track so only its protruding ends show. The popup's copy of
    /// `StatusItemView.drawZeroTick` — same construction, same proportions, so the mark that identifies
    /// Balance and Pressure looks like itself on both surfaces.
    ///
    /// Called **before** the track on every path (idle and pacing alike), which is what turns a full
    /// stroke into a pair of ends: the track paints over its middle. Drawing it after would put a solid
    /// bar across the ribbon and read as data rather than as furniture. It draws in every state, idle
    /// included — a length needs something to be a length from.
    ///
    /// **Where Pressure's zero actually is:** the drawn centre of the zero-length pill, read back out of
    /// ``pillRect(at:in:)`` rather than restated here, exactly as the menu bar does — a zero-length
    /// ribbon is floored to the min-width pill and snapped flush to the track's left cap, so its centre
    /// sits half a pill-width in from the edge.
    private func drawZeroTick(in rect: NSRect) {
        guard let fraction = zeroTickFraction else { return }
        // Take the whole *rect* of the zero-length pill, not just a centre: at fraction 0 the pill is
        // asymmetric about `scaleX(0)` — `pillRect` snaps its left cap flush to the track's edge — so a
        // tick centred on the scale position sits visibly off the pill it marks. Matching the pill's own
        // span makes the two concentric by construction, whichever way that snap resolves.
        let pill = Self.pillRect(at: fraction, in: rect)
        // Sized against the zero pill, a touch narrower — see `Metrics.zeroTickPillFraction`.
        let w = Self.minStripWidth(rect) * Metrics.zeroTickPillFraction
        let h = Metrics.zeroTickHeight
        // Snap width and left edge to the **half-point** grid, not the whole-point one: the popup draws
        // on 2× displays, where half a point is a whole device pixel, and rounding to whole points would
        // quantise the 2.5 pt width down to 2 — a third of the mark lost to rounding. Snapping both the
        // edge and the width keeps each flank on a device pixel, so neither renders softer than the
        // other (which reads as the tick being off-centre rather than merely blurry).
        let cx = pill?.midX ?? Self.scaleX(fraction, in: rect)
        let snapped = (w * 2).rounded() / 2
        let x = ((cx - snapped / 2) * 2).rounded() / 2
        // Already faded, and faded per-appearance — see `Palette.zeroTick`.
        Palette.zeroTick.setFill()
        NSRect(x: x, y: rect.midY - h / 2, width: snapped, height: h).fill()
    }

    /// Draw the under-bar tick ruler: vertical teeth at each fraction in ``tickFractions``,
    /// pixel-snapped on x, plus the credits bar's boundary captions. No-op when there is nothing to
    /// mark.
    ///
    /// This is the ⌥-on-demand half of the ruler — the marks that *explain* the scale. The half that
    /// *identifies* it is the zero struck through the bar (``drawZeroTick(in:)``), which is always
    /// visible and drawn on a different layer entirely (under the track, not below the bar).
    ///
    /// The captions are drawn **before** the empty-fractions bail-out: the credits ruler is captions
    /// *without* teeth, so gating them on a non-empty tooth list would erase the whole ruler.
    private func drawTicks(in barRect: NSRect) {
        guard optionHeld else { return }                   // the explanatory half is ⌥-on-demand
        // Captions retired (#396): the `0` under the zero tick and the credits bar's `Jan 1` / `Feb 1`
        // month ends. Both spelled out what their own mark already showed — the tick *is* the zero, and
        // a bar whose window is the calendar month has its dates on the reset line right above it. They
        // also sat below the bar, which is where the next section's title begins, so under ⌥ the rows
        // gained a half-line of text each and the popup's rhythm changed with the modifier.
        //
        // The teeth stay: they subdivide the window, which nothing else in the row states.
        for f in tickFractions { drawTick(at: f, in: barRect) }
    }

    /// One tooth of the ruler, below the bar and aligned to the same inset scale as the coloured strip.
    private func drawTick(at fraction: CGFloat, in barRect: NSRect) {
        let top = barRect.maxY + Metrics.tickGap           // flipped: just below the bar
        let bottom = top + Metrics.tickLength
        Palette.tick.setFill()
        // Pixel-snap the tooth's centre so it stays crisp at @1x and @2x. Mapped through the same
        // inset scale as the coloured strip / marker so the ruler stays aligned with them.
        let cx = Self.scaleX(fraction, in: barRect).rounded()
        let rect = NSRect(x: cx - Metrics.tickWidth / 2, y: top, width: Metrics.tickWidth, height: bottom - top)
        // Rounded (capsule) teeth — corner = half the width so the ends read soft, not blocky.
        let corner = Metrics.tickWidth / 2
        NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
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
        let red = ColorRole.red.defaultColor
        let yellow = ColorRole.yellow.defaultColor
        let orange = ColorRole.orange.defaultColor
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
        let green = ColorRole.green.defaultColor
        // Blue is off the table for this bar (weekly gate closed, or an inert/non-token bar) → green.
        // Must stay in lock-step with `isFarBehind`, or the bar reads green under a "far behind pace"
        // status word.
        if !l.blueAllowed { return green }
        let elapsed = Double(l.windowDurationSeconds) - l.remainingSeconds
        if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return green }
        return (l.timeFraction - l.usageFraction) > PacingModel.behindThreshold(windowDurationSeconds: l.windowDurationSeconds)
            ? ColorRole.blue.defaultColor : green
    }

    /// Glow radii (#188 follow-up): a soft coloured halo (ambient) behind the coloured pacing strip, the
    /// time marker, and the service-status dots so they lift off the card.
    /// Bar strip glow: a large, soft, low-intensity halo. The idle strip shares these parameters.
    /// How far the transparent gutter under a yellow strip extends past it on each side (#326).
    /// Tuned live from 0.5 pt (a hairline, it vanished) through 2 pt: 1.5 pt — three physical pixels
    /// on a Retina display — is the settled width. A `labelColor` backing plate was tried at this spot
    /// and rejected: the transparent cut is what was wanted, letting the panel itself separate the
    /// strip from the track.
    private static let yellowGutter: CGFloat = 1.5

    /// Whether this strip is rendering the **yellow** (mild-lead) pacing colour, and so wants the
    /// transparent gutter beneath it.
    ///
    /// Compared against the live `.yellow` role rather than recomputed from `(u, t)`: the colour that
    /// actually reaches the bar has already been through the calm-muting and the animator, and it is
    /// the *rendered* tone whose contrast against the track is the problem. A mid-transition frame
    /// therefore correctly counts as not-yet-yellow. Both sides are converted into one colour space
    /// first — a dynamic catalogue colour and a resolved one never compare equal directly.
    private func isYellow(_ colour: NSColor) -> Bool {
        guard let a = colour.usingColorSpace(.sRGB),
              let b = ColorRole.yellow.defaultColor.usingColorSpace(.sRGB) else { return false }
        let tolerance = 0.02
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    private static let gapGlowRadius: CGFloat = 21
    private static let gapGlowStrength: CGFloat = 0.35

    /// Glow for a **Pressure ribbon that has collapsed to its zero pill** (#381) — stronger and tighter
    /// than the ambient one above.
    ///
    /// Pressure measures against the time left, so every quiet state — the far-behind blue and the
    /// on-pace green alike — draws the same minimum pill: the scale deliberately spends no width on the
    /// side where there is nothing to act on. That leaves the pill with almost no area to carry its
    /// colour, and the ambient 21 pt halo is calibrated for a ribbon many times that size, so on a pill
    /// it reads as a faint smudge rather than as the mark's own light.
    ///
    /// A **tighter** radius with **more** strength is what recovers it: the halo stays inside the bar's
    /// own height instead of bleeding across the card, and the pill reads as a lit dot. Only the quiet
    /// colours get this — orange and red already have ribbon length of their own, and lighting them
    /// further would raise a warning's volume rather than restore a quiet mark's legibility.
    /// The three glow passes for a collapsed Pressure pill, laid down widest-first.
    ///
    /// Three rather than one because `withGlow` sets a **shadow alpha**, and `strength` clamps at 1: once
    /// there, a bigger number buys nothing and the only way left to add light is another pass. Each one
    /// composites over the last, so the halo builds where they overlap — brightest against the pill,
    /// falling off outward, which is how a light source actually behaves.
    ///
    /// The radii are a spread, not three tries at one value: the wide pass fills the bar's height with
    /// colour, the mid pass gives the falloff a body, and the tight pass puts a hot core right at the
    /// pill's edge so the mark reads as lit rather than as a blur with a dot inside it.
    private static let pillGlowRadius: CGFloat = 10
    private static let pillMidGlowRadius: CGFloat = 22
    private static let pillHaloRadius: CGFloat = 40
    /// Full alpha on every pass — see above for why the count, not this number, is the brightness knob.
    private static let pillGlowStrength: CGFloat = 1.0

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

    /// Fill of the Control-Center-style section card (`CardBackdropView`, #188). `controlBackgroundColor`
    /// (light #FFFFFF, dark #1E1E1E) at **partial alpha**, so the `NSMenu` vibrancy material below the card
    /// shows through and lends the plate a subtle tone, while our chosen colour sits on top. (True
    /// wallpaper `.behindWindow` tint is impossible inside an NSMenu — the menu window is system-opaque —
    /// so this translucency over the menu's own material is the closest achievable "vibe".) `cardPlateAlpha`
    /// is the single knob for how much tone bleeds in.
    static var cardPlateFill: NSColor { NSColor.controlBackgroundColor.withAlphaComponent(cardPlateAlpha) }

    /// The card's colour at **full** opacity — what a badge paints its content in so the glyph reads as
    /// cut out of the plaque.
    ///
    /// The same `controlBackgroundColor` the card is built from, so it is dynamic and flips with the
    /// theme on its own (light `#FFFFFF`, dark `#1E1E1E`); a fixed value would have to be maintained for
    /// both appearances and would drift. Deliberately opaque: at `cardPlateAlpha` the menu material
    /// below would bleed through the glyph and mix it with the plaque's own fill, which is exactly the
    /// muddy result the alpha is *wanted* for on the card itself and *not* wanted inside a small mark.
    static var cardPlateFillOpaque: NSColor { .controlBackgroundColor }

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
            ? ColorRole.label.defaultColor
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
        //
        // The glyph carries its own side bearing, so centring its box on the dots' axis still reads a
        // touch left of them; `subscribeGlyphNudge` corrects that by eye (#351). The label keeps its
        // own leading constant, so nudging the icon does not move the text column.
        let dotDiameter = PopupViewController.Metrics.statusDotDiameter
        let gap = PopupViewController.Metrics.statusDotGap
        let glyphNudge = PopupViewController.Metrics.subscribeGlyphNudge
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: dotDiameter / 2 + glyphNudge),
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
/// The badge **draws its own text** rather than hosting an `NSTextField`, so the padding around the
/// text is one `NSTextField` whose cell insets its own drawing rect (#158 follow-up).
///
/// The badge is **a label with padding and a filled background**, so it is built as one — not as a
/// label positioned inside a container, and not as a view that draws the string itself. Both of those
/// were tried here and both put the padding at the mercy of a rounding step: a hosted field rounds its
/// width up to a backing pixel before the centring splits what is left, so the padding drifts with the
/// string, and since the badge is pinned to the row's trailing edge, holding ⌥ swaps a short string for
/// a long one and the text steps sideways. Hand-drawing moves the same remainder elsewhere rather than
/// removing it.
///
/// ``PillCell`` narrows the rect the text is laid out in, which is the AppKit-sanctioned way to pad a
/// cell's content. One text object, laid out once, with the framework resolving the rounding.
final class PillView: NSTextField {
    /// The badge fill. Defaults to the accent blue; callers set it (e.g. the exhausted red). A closure
    /// (not a stored `NSColor`) so a dynamic colour re-resolves per appearance.
    var fill: () -> NSColor = { .controlAccentColor } {
        didSet { needsDisplay = true }
    }

    /// Padding **added on top of the cell's own**, applied by ``PillCell`` through
    /// `drawingRect(forBounds:)` and reported to Auto Layout through `intrinsicContentSize`.
    ///
    /// `NSTextFieldCell` already reserves ~``cellOwnInset`` at each end, so this is not the padding you
    /// see: measured, `hInset = 6` rendered as 10.5 pt of air per side, which is why the badge read as
    /// over-padded. Zero here leaves the cell's own 4.5 pt — the tightest the capsule goes without
    /// clipping — which is the intended snug look.
    static let hInset: CGFloat = 0
    static let vInset: CGFloat = 2

    /// The horizontal padding `NSTextFieldCell` reserves at each end regardless of `drawingRect`.
    /// Measured by rendering the badge at a range of `hInset` values and reading the pixels back: the
    /// rendered padding is consistently `hInset + 4.5` per side. Callers that need the *visible* inset —
    /// the row's column shift — must add this.
    static let cellOwnInset: CGFloat = 4.5

    /// Corner radius as a fraction of the height. `0.5` is a full pill; lower is a softer rounded rect.
    static let cornerFraction: CGFloat = 0.35

    /// The height every badge in the popup shares, whatever it carries.
    ///
    /// Derived from the reset badge — the one with the most text in it — so it is the tallest anatomy and
    /// nothing has to grow past it. ``KnockoutGlyphBadge`` adopts it rather than sizing to its own glyph:
    /// left to themselves the three badges came out 18.0, 17.5–20.5 and 14.0 pt, and the currency one
    /// even changed height with the currency (17.5 for `€` against 20.5 for `¤`), so a row could shift as
    /// the account's billing changed.
    static var sharedHeight: CGFloat {
        if let cached = cachedSharedHeight { return cached }
        let probe = PillView(
            text: "0", font: PopupViewController.pillFont, textColor: .labelColor, fill: { .clear })
        probe.isHeightProbe = true
        let height = probe.intrinsicContentSize.height
        cachedSharedHeight = height
        return height
    }
    private static var cachedSharedHeight: CGFloat?

    /// A badge whose content is an **SF Symbol** rather than a word — the credits marker's resting form.
    ///
    /// The symbol goes in as a text attachment, so it is laid out by the same text system that lays out
    /// a word: one anatomy, one height, no second code path. `NSImage.SymbolConfiguration` ties the
    /// glyph to `font`, and the attachment's `bounds` lifts it onto the font's cap height — the standard
    /// recipe, since SF Symbols are drawn to sit on the text baseline.
    convenience init(symbol: String, font: NSFont, textColor: NSColor, fill: @escaping () -> NSColor) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .bold))
        let attachment = NSTextAttachment()
        attachment.image = image
        if let size = image?.size {
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2,
                                       width: size.width, height: size.height)
        }
        self.init(attributed: NSAttributedString(attachment: attachment),
                  font: font, textColor: textColor, fill: fill)
    }

    convenience init(text: String, font: NSFont, textColor: NSColor, fill: @escaping () -> NSColor) {
        self.init(attributed: NSAttributedString(string: text), font: font, textColor: textColor,
                  fill: fill)
    }

    private convenience init(attributed: NSAttributedString, font: NSFont, textColor: NSColor,
                             fill: @escaping () -> NSColor) {
        self.init(frame: .zero)
        // Swap the cell in FIRST: assigning `cell` replaces the whole backing store, so anything set
        // beforehand (string, font, colour, label behaviour) is dropped on the floor. A field whose
        // string never reached its new cell measures as empty and renders as a bare capsule.
        let cell = PillCell(textCell: "")
        cell.isEditable = false
        cell.isSelectable = false
        cell.isBezeled = false
        cell.drawsBackground = false
        // Centred. Flush-left in the inset rect looks equivalent — the capsule is the text plus two
        // equal insets — and measures identically when the badge sizes itself. It is not: inside the
        // row the badge is stretched by the trailing `edgeInsets` shift, and left alignment then pins
        // the text to the near edge while the extra width all lands on the far side. Measured in the
        // real row layout, that is a 9 px lean; centring holds at 1 px.
        cell.alignment = .center
        cell.font = font
        cell.textColor = textColor
        cell.lineBreakMode = .byClipping
        self.cell = cell
        // The content goes in after the cell swap, and as an attributed string so a symbol attachment
        // survives — `stringValue` would flatten it to the attachment's placeholder character.
        let styled = NSMutableAttributedString(attributedString: attributed)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        styled.addAttributes([.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: styled.length))
        self.attributedStringValue = styled
        self.fill = fill
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Width from the content, height from ``sharedHeight`` — every badge in the popup is the same
    /// height whatever it carries, so a row does not change shape when the badge's content does (the
    /// credits marker swaps a glyph for a word under ⌥, and its glyph changes with the account's
    /// currency).
    ///
    /// Height from the content is measured off `cell.cellSize`, **not** `super.intrinsicContentSize`.
    ///
    /// The field's own intrinsic size already reflects the narrowed `drawingRect`, so adding the insets
    /// to it counts them twice: the capsule comes out too wide and the cell centres its text in a
    /// different rect than the fill is drawn in. Measured, that put the text 22 px from the left edge
    /// against 13 px from the right — a 9 px lean, far worse than the anatomy it replaced.
    override var intrinsicContentSize: NSSize {
        var size = cell?.cellSize ?? super.intrinsicContentSize
        size.width += 2 * Self.hInset
        size.height += 2 * Self.vInset
        if !isHeightProbe { size.height = Self.sharedHeight }
        return size
    }

    /// Set only on the throwaway instance ``sharedHeight`` measures, so asking it for its size does not
    /// recurse back into `sharedHeight`.
    fileprivate var isHeightProbe = false

    /// Fill the capsule, then let the field draw its text inside the inset rect the cell returns.
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height * Self.cornerFraction
        fill().setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        super.draw(dirtyRect)
    }
}

/// Applies ``PillView``'s padding the way AppKit intends: by narrowing the rect the cell lays its text
/// out in, rather than by positioning a separate label inside a container.
///
/// This matters beyond tidiness. Hosting an `NSTextField` inside a plain `NSView` and pinning it with
/// constraints makes the field round its own width up to a backing pixel *first*, after which the
/// leftover — different for every string — is split by the centring inside the field. The padding then
/// drifts with the text, and because the badge is pinned to the row's trailing edge, holding ⌥ swaps a
/// short string for a long one and the text visibly steps sideways. Drawing the string by hand instead
/// trades that for the same problem in a different place. Letting the cell inset its own drawing rect
/// keeps one text object, laid out once, with AppKit resolving the rounding.
final class PillCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: PillView.hInset, dy: PillView.vInset))
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

    /// Invoked when the "turn monitoring back on" row is clicked in the nothing-monitored state
    /// (#341). Same shape as ``onToggleSubscription``: the controller reports the click, the delegate
    /// decides what it opens.
    var onOpenProviderSettings: (() -> Void)?

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

    /// Bar presentation style (#224), governing every bar in the popup — `PersistedConfig.dropdownStyle`,
    /// independent of the menu bar's own choice (#329). Pushed into each `PopupBarView` during
    /// `rebuild()` → `addBar`. Child bars are built fresh on each rebuild, so a change here must
    /// rebuild (not just redraw) to reach them — mirrors `optionHeld`.
    var barStyle: BarStyle = .progress {
        didSet {
            guard isViewLoaded, barStyle != oldValue else { return }
            rebuild()
        }
    }

    /// When the per-model / per-service rows are shown (#211). The gate lives here rather than in
    /// `PopupLayout` because it depends on ``optionHeld``, which changes while the menu is open and
    /// without a re-poll. Like `barStyle`, a change rebuilds.
    var modelLimitsVisibility: PopupSectionVisibility = .whenItNeedsAttention {
        didSet {
            guard isViewLoaded, modelLimitsVisibility != oldValue else { return }
            rebuild()
        }
    }

    /// When the "Extra usage" credits section is shown. Independent of the menu-bar credits icon,
    /// which keeps its own boolean gate in `PersistedConfig.showExtraUsage`.
    var extraUsageVisibility: PopupSectionVisibility = .whenItNeedsAttention {
        didSet {
            guard isViewLoaded, extraUsageVisibility != oldValue else { return }
            rebuild()
        }
    }

    /// The popup's fixed width — **the** number, read by ``Metrics/width`` here and by
    /// `SettingsPreviewWindowController.Metrics.nominalWidth` for the live preview window (#396).
    ///
    /// Both used to carry their own `312` literal, which could drift apart silently: the preview would
    /// simply open at a different width than the popup it previews. Deriving both from this one
    /// constant makes that impossible.
    ///
    /// The inner content column every fixed-width row measures against is ``Metrics/contentWidth`` =
    /// `width − 2·cardInset − 2·hPadding` = 380 − 28 − 32 = **320 pt**. Widened from 312/252 (#396) so
    /// the credits header fits without shortening the pacing phrases, which are shared verbatim with
    /// the token rows.
    ///
    /// Sized against `Extra usage progress … [active] well ahead of pace` — **307 pt** at 13 pt, the
    /// widest line that *must* fit. The **detail** line can exceed it (`spent $5,000.00 of $5,000.00`
    /// plus the longest reset is 321 pt) without setting the width: overflowing is what the fit gate is
    /// for, and it drops the reset by design.
    ///
    /// `nonisolated` because ``Metrics`` is a plain (non-actor-isolated) enum and reads this as a
    /// default value — a bare `static let` on a `@MainActor` view controller cannot cross that line.
    /// Safe: it is an immutable number with no main-thread state behind it.
    nonisolated static let popupWidth: CGFloat = 380

    // `fileprivate`, not `private`: `SubscribeRowView` (#279) is a sibling type in this file and
    // sizes itself from the same metrics, so the two rows cannot drift apart.
    fileprivate enum Metrics {
        /// Popup width — reads ``PopupViewController/popupWidth``, the one place the number lives, so the
        /// Settings live preview (`SettingsPreviewWindowController`) cannot silently drift from it.
        static let width: CGFloat = PopupViewController.popupWidth
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
        /// Bottom **inner** padding — space between the last bar and the card's bottom edge.
        ///
        /// Was 12, trimmed to 8 in #396 when the ⌥ captions came out, then back to 14 in #388: both
        /// earlier numbers were chosen while each bar still carried 7 pt of tick-ruler reserve below it,
        /// so the *rendered* bottom margin was 15–19 pt however the constant read. Removing the reserve
        /// dropped it to a real 8 and the last row sat on the card's edge. 14 restores the old optical
        /// margin and makes it the same value as `limitSpacing`, so the space below the last bar matches
        /// the space between bars.
        static let bottomPadding: CGFloat = 14
        static let rowSpacing: CGFloat = 3
        static let sectionSpacing: CGFloat = 14
        /// Gap **between limit blocks** (after each section's bar) — the same 14 pt the header takes.
        ///
        /// It used to be 10, "a touch tighter than `sectionSpacing` so the limit list reads as a group".
        /// That reasoning measured the wrong thing: every bar view reserved 7 pt under itself for a tick
        /// ruler two of the three styles never draw, so the gap between blocks *rendered* as ~25 pt while
        /// the gap under "Claude" rendered as its honest 14. The list read looser than the header, not
        /// tighter. With the reserve gone (#388) the two are set equal and finally look it.
        static let limitSpacing: CGFloat = 14
        static let textSize: CGFloat = dropdownTextSize
        /// Diameter of the service-status glow dot (#188) and the gap between it and the component name.
        static let statusDotDiameter: CGFloat = 9
        static let statusDotGap: CGFloat = 10
        /// Optical nudge to the right for the status/incident dot, and for the subscribe row's glyph
        /// (#351), measured from where each sat before. Both are aligned by eye against the left edge
        /// of the text in the rows above ("5-hour", "7-day"): a round dot and a glyph with side
        /// bearing each read as sitting slightly left of that column even when their boxes are flush —
        /// and by different amounts, the bell needing twice the dot's correction.
        static let statusDotNudge: CGFloat = 0.5
        static let subscribeGlyphNudge: CGFloat = 1
        /// The inner content column width for fixed-width rows/labels — the popup width minus the card's
        /// outer inset on both sides minus the inner horizontal padding on both sides:
        /// 380 − 2·14 − 2·16 = **320 pt** (#396; was 252 when the popup was 312 wide). Every fixed-width
        /// row, the bars, and the fit gate measure against this, so widening the popup widens all three
        /// together.
        static let contentWidth: CGFloat = width - 2 * cardInset - 2 * hPadding
        /// The smallest readable gap between a split row's two halves. Below it the two columns stop
        /// reading as separate facts, so a pair that cannot keep this much air between them counts as
        /// not fitting (``PopupViewController/detailHalvesFit(left:right:font:)``).
        static let minSplitGap: CGFloat = 12
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
    /// no active session, so the row reads "5-hour  ready to start" with a green pill and no second
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

    /// The weekly window has no reset instant and no history to reconstruct one from (ADR-0107).
    ///
    /// States the fact and nothing more — the app does not know *why* the API has not opened a
    /// weekly window, only that it has not. Matches the menu bar's accessibility description for the
    /// same state, so the two surfaces speak with one phrase.
    static let weeklyResetUnknownTitle = "Weekly reset time unknown"

    /// The second line: what will actually change the state.
    ///
    /// "start a session in Claude Code" rather than "start using Claude", because the weekly window
    /// is opened by token spend through the CLI — a conversation on claude.ai will not create one.
    /// Phrased as the next step rather than an instruction, matching the "Turn it back on in
    /// Settings…" line above it.
    static let weeklyResetUnknownDetail =
        "Claude has not reported a weekly reset yet — start a session in Claude Code and it will appear."

    /// Anthropic's official primary accent colour (`#d97757`, a terracotta orange) — confirmed
    /// against `anthropics/skills`' `brand-guidelines/SKILL.md` on GitHub, the same value the local
    /// Claude Code "claude" theme slot resolves to. Used only for the "Claude Code" section header,
    /// so the popup echoes the CLI's own brand mark rather than a generic label colour.
    private static var claudeBrandColor: NSColor { ColorRole.claudeBrand.defaultColor }

    /// `Metrics.textSize`, bold — the "Claude Code" section header and the two native menu items
    /// below it (via `App.swift`'s `attributedTitle`) all resolve to this exact font, so there is no
    /// visual mismatch to chase.
    private static var menuItemFont: NSFont {
        NSFontManager.shared.convert(.systemFont(ofSize: Metrics.textSize), toHaveTrait: .boldFontMask)
    }

    /// The left half of the "Claude" section header: **"Claude"** in the bold ``menuItemFont``, and —
    /// when a plan label is present (e.g. "Max (5x)", from the Keychain rate-limit tier) — a bold `･`
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
    static var dimmedLabelColor: NSColor { ColorRole.dimmedLabel.defaultColor }

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
        // #341: in the services-only mode the service rows are the popup's **entire** content — the
        // limit sections are gone with the usage poll. The ordinary condition would hide them while
        // everything is green, leaving a popup with nothing in it but a brand title, so this mode
        // shows them unconditionally.
        let servicesAreTheContent = layout.monitoringMode == .servicesOnly
        // `hasRecentRecovery` keeps the section up under ⌥ as well, which is what makes the
        // "No ongoing incidents" row reachable right after a fix lands: the service rows say a
        // component just recovered, so the incident dimension must answer for the same moment rather
        // than go blank (the ⌥ half would otherwise look broken beside a populated non-⌥ half).
        let showStatusRows = status != nil
            && (servicesAreTheContent || status?.worstProblem != nil || hasRecentRecovery
                || (optionHeld && !layout.incidents.isEmpty))
        // The age threshold is 2× the usage poll's floor, which the status cadence never reaches — so
        // in the services-only mode the age would essentially never appear without ⌥, and the one
        // number that mode has to offer would stay hidden. There, show it whenever it exists.
        let showAge = optionHeld || layout.lastUpdateAge >= Self.staleAgeThreshold
            || (servicesAreTheContent && layout.lastUpdateAge > 0)
        // Prefixed with the verb (#388 follow-up): on its own, "just now" beside the plan label
        // read as a fragment — the header tail says *what* happened then, not just when.
        let ageString = showAge ? "updated \(Self.ageText(layout.lastUpdateAge))" : ""
        // Header layout (#233): the "Claude" brand title with the "Nm ago" age beside it on the left —
        // **always**, whether or not an awaiting-input count exists. The age belongs to the brand title,
        // not to the right edge: pushing it flush right (the old no-awaiting fallback) made it jump
        // across the header the moment the awaiting count dropped to zero or the feature was off.
        // The right slot is reserved for the awaiting-input indicator (hand + count) and stays empty
        // otherwise.
        // The brand title — "Claude" plus the plan label ("Max (5x)") when present, both in brand colour.
        // The plan label rides the ⌥ layer too (#396): it names the subscription once, never changes
        // between polls, and answers a question nobody asks twice — so at rest the header is the bare
        // "Claude" mark and ⌥ restores "Claude ･ Max (5x)". `brandTitleLabel` already renders the mark
        // alone for a nil plan, so this is a gate on the argument, not a second code path.
        let brand = Self.brandTitleLabel(plan: optionHeld ? layout.planLabel : nil)
        // The age rides the ⌥ layer with the plan label (#396): at rest the header is the bare "Claude"
        // mark, and ⌥ restores the whole tail — `Claude ･ Max (20x) ･ updated just now`.
        //
        // The two belong together. Both answer questions asked once rather than watched: which plan
        // this is, and how fresh the numbers are. Leaving the age visible while the plan hid split one
        // tail across two layers, so the header changed shape twice on one modifier.
        //
        // The `･` leads the age's own string rather than sitting in the stack's spacing: one text
        // object means one baseline, and the gap either side is the glyph's own side bearing. The
        // stack's spacing is 4 — 8 was tuned for two labels meeting with no punctuation between them,
        // and on top of the dot's bearing it read as a double space.
        let leading = NSStackView(views: [brand])
        if optionHeld {
            let age = NSTextField(labelWithString: Self.separatorPrefix + ageString)
            age.font = .systemFont(ofSize: Metrics.textSize)
            age.textColor = Self.dimmedLabelColor
            leading.addArrangedSubview(age)
        }
        leading.orientation = .horizontal
        leading.alignment = .firstBaseline
        leading.spacing = 4
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
            if optionHeld, layout.incidents.isEmpty {
                // ⌥ asks "what is broken", and here the answer is "nothing" — a different statement
                // from `operational`, which answers "is everything up". Saying it out loud beats
                // dropping the rows: this section is already on screen (something is wrong, or
                // something just recovered), so an empty dimension would read as a glitch rather than
                // as an answer.
                //
                // This is the shape ADR-0071 §4 produces on purpose — an incident whose components
                // have gone green is hidden, because the popup's question is "can I work" and green
                // already answers it. Alternative K there (show it as "recovering") stays rejected;
                // this row reports the *absence*, it does not bring the incident back.
                lastRow = addServiceStatusRow(
                    label: "No ongoing incidents",
                    status: .operational,
                    age: layout.lastUpdateAge > 0 ? layout.lastUpdateAge : nil,
                    // The label already is the statement; `operational` beside it would answer the
                    // service dimension in a row that belongs to the incident one.
                    showsStatusWord: false)
            } else if optionHeld, !layout.incidents.isEmpty {
                // ⌥ switches the **dimension**, not the level of detail (ADR-0071 §2): the service
                // rows are replaced by the incidents behind them. Green service lines are not shown
                // here — under ⌥ the question is "what is broken", and a green row does not answer it.
                for incident in layout.incidents {
                    // Plain `rowSpacing`, the same gap the service rows use. ⌥ swaps one dimension
                    // for the other in place, so a different rhythm here makes the switch jump.
                    //
                    // #279 set this to 8 pt on the theory that a wrapped description carries trailing
                    // line leading a single-line row does not, making equal values render unequal.
                    // Measured, it does not: the system font at 13 pt has `leading == 0` and every
                    // line box is exactly 16 pt, wrapped or not, so the 5 pt was simply extra space
                    // after incidents and before the subscribe row (#351).
                    lastRow = addIncidentRow(incident, now: now)
                }
            } else {
                // Default: only the non-operational components — plus any that went green within the
                // recovery window, so a fix that just landed is visible rather than leaving a blank
                // popup that looks identical to "nothing ever happened".
                let components = status.checks.flatMap(\.components)
                    .filter { $0.status.isProblem || Self.isRecentlyRecovered($0, now: now) }
                // #341: in the services-only mode this section is the popup's entire content, so the
                // question it answers is "is anything wrong", and the answer while nothing is —
                // **one** summary row standing for the lot.
                //
                // The condition is `worstProblem == nil`, not `components.isEmpty`: the filter above
                // also keeps components that went green within the recovery window, so a service that
                // recovered minutes ago would otherwise replace the summary with a lone green row
                // ("Web/Desktop · operational") that reads as though it were the only thing watched.
                // A recent recovery is worth showing when it sits among real rows; it is not worth
                // standing in for the whole section.
                //
                // **Not gated on `optionHeld`.** ⌥ switches the dimension to incidents (the branch
                // above), and when there are none it changes nothing at all — this section keeps
                // answering the same question either way. Expanding the summary into a per-component
                // list under ⌥ would make it a level-of-detail control, which is exactly what
                // ADR-0071 §2 says it is not.
                if servicesAreTheContent, status.worstProblem == nil {
                    lastRow = addServiceStatusRow(
                        label: "All services",
                        status: .operational,
                        age: layout.lastUpdateAge > 0 ? layout.lastUpdateAge : nil)
                } else {
                    for component in components {
                        lastRow = addServiceStatusRow(
                            label: Self.displayName(component),
                            status: component.status,
                            age: component.stateAge(at: now))
                    }
                }
            }
            if let subscribeRow = addSubscribeRowIfNeeded(layout) { lastRow = subscribeRow }
            if let lastRow { stack.setCustomSpacing(Metrics.sectionSpacing, after: lastRow) }
        }

        // #341: nothing is monitored. Same two-line shape as the error block below, but deliberately
        // **not** red and not a ⚠️ — the app is doing exactly what it was told. The second line is a
        // clickable route back into the setting that produced this state, since a popup that explains
        // an empty widget without offering the way out is a dead end.
        if layout.monitoringMode == .nothing {
            addWarningTitle("Monitoring is off",
                            symbolName: "eye.slash",
                            color: Self.dimmedLabelColor)
            let row = SubscribeRowView(
                symbolName: "gearshape", text: "Turn it back on in Settings…", filled: false)
            row.onClick = { [weak self] in self?.onOpenProviderSettings?() }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(Metrics.sectionSpacing, after: row)
        }

        // ADR-0107: no weekly reset and nothing to reconstruct one from. Same two-line shape as the
        // block above and, for the same reason, **not** red and not a ⚠️: nothing has failed — the
        // API answered, it simply has not opened a weekly window yet because no tokens have been
        // spent. The detail line says what will fix it, which is the only action available.
        if layout.weeklyResetUnknown {
            addWarningTitle(Self.weeklyResetUnknownTitle,
                            symbolName: StatusItemView.noDataSymbolName,
                            color: Self.dimmedLabelColor)
            let detail = addWrappingLabel(
                Self.weeklyResetUnknownDetail,
                font: .systemFont(ofSize: Metrics.textSize), secondary: true)
            stack.setCustomSpacing(Metrics.sectionSpacing, after: detail)
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
            isNonCalm: layout.perModelRowsAreNonCalm,
            isAboveZero: layout.perModelRowsAreAboveZero, optionHeld: optionHeld)
        let showCredits = layout.credits != nil && extraUsageVisibility.shows(
            isNonCalm: layout.creditsIsNonCalm,
            isAboveZero: layout.creditsIsAboveZero, optionHeld: optionHeld)
        // Which row ends the visible list — the last one actually drawn, so the "no gap after the last
        // bar" rule follows what's on screen rather than what the model built.
        let lastVisibleRowIndex = showPerModel ? layout.rows.count - 1 : layout.perModelRowsStart - 1

        for (index, row) in layout.rows.enumerated() {
            if index >= layout.perModelRowsStart, !showPerModel { continue }
            addTitleStatusLine(title: row.title, status: Self.statusText(row, isBaseLimit: index <= 1),
                               style: barStyleCaption())
            // The idle 5-hour row (#100) has **no** second line at all — no "0%", no reset — so it reads
            // as a compact "5-hour  ready to start" (or "waiting for limit reset" when blocked, #158) +
            // solid bar. Every other row shows the detail; its reset goes red when it is *the* blocking
            // reset (the "last stand" pick from `layout.blockingReset`).
            if !row.sessionIdle {
                addDetailLine(
                    used: Self.usedText(row, verbose: optionHeld),
                    reset: Self.resetText(row, verbose: optionHeld),
                    resetIsBlocking: Self.isBlockingRow(index, in: layout))
                // The ⌥ stand-by line, on the **7-day row only** (`index == 1`, the ordering
                // fixed just below). Pacing on the 5-hour window is not worth waiting out — it resets
                // at least twice in a working day and fixes itself; a week does not.
                if optionHeld, index == Self.sevenDayRowIndex,
                   let text = Self.standByText(row) {
                    addStandByLine(text)
                }
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
            // Unlimited: no cap, so no bar, no pacing verdict and no reset — but the row keeps the
            // section's shape (#396): a header naming the state, then the amount on its own second
            // line, where every other section puts its numbers. It used to be a single line with the
            // amount standing in for a status, which made the one row without a cap the one row with a
            // different anatomy.
            //
            // No style word: there is no bar here, so there is no scale to name.
            // Without a cap this is the row's **only** line, so it is the only place a red can live:
            // there is no reset badge below it to carry one (no ceiling ⇒ no reset to wait for). That
            // is why `out of credits` shows here and not on the capped row, where the reset badge marks
            // the blocker instead.
            addTitleStatusLine(
                title: Self.extraUsageTitle,
                status: Self.creditsUnlimitedWord,
                stateBadge: creditsUnlimitedStateBadge(credits))
            addDetailLine(used: Self.creditsSpentOnlyText(credits.spent, verbose: optionHeld),
                          reset: nil)
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
            // `monthBounds: true` — this bar is on the window scale regardless of the setting
            // (ADR-0092), so it captions itself `progress` even in a column of Pressure bars. That
            // mismatch is the caption's whole reason for existing.
            style: barStyleCaption(monthBounds: true),
            // The state badge sits in the **trailing** half, qualifying the status word (#396). It used
            // to ride beside the title, where it named the money but sat next to the row's name rather
            // than next to anything about money — and only ever appeared for one of the three states.
            stateBadge: creditsStateBadge(credits, bar: bar))
        // Both halves grow under ⌥ at once — exact cents on the left, the "resets in" lead-in on the
        // right — and the credits amounts are the popup's widest left half to begin with, so this is
        // where `addDetailLine`'s fit gate actually fires: the reset drops and the amounts stay.
        addDetailLine(
            used: Self.creditsAmountText(spent: credits.spent, limit: limit, verbose: optionHeld),
            reset: (optionHeld ? credits.resetLineVerbose : credits.resetLine) ?? "resetting…",
            resetIsBlocking: creditsResetIsBlocking)
        // Credits pace over the whole calendar month, so the bar carries no window subdivisions —
        // instead it gets the month's two captioned ends ("Aug 1" … "Aug 31"), which also pin it to
        // Progress whatever the dropdown's bar style is. `isLast: true` — the credits section is always
        // the popup's final block, so it sits tight above the menu separator.
        addBar(bar: bar, subdivisions: 0, idle: false, isLast: true,
               monthBounds: credits.monthBounds)
    }

    /// The section's first line: title and pacing status, both `labelColor` — the same weight and
    /// colour the dropdown's own "Settings…" text uses. `status` sits flush **right**, lined up with
    /// the detail line and bar below it, instead of trailing right after the title on the left.
    /// Neither half is bold — the section reads from the bar and numbers, not a heavier heading. Both
    /// the window titles (`"5-hour"`/`"7-day"`) and the bare per-model names (`"Opus"`/`"Fable"`) render
    /// whole in `labelColor`.
    /// `style` names the scale **this** bar is drawn on and is shown only while ⌥ is held (#396) — see
    /// ``barStyleCaption(monthBounds:)`` for why it is per-bar rather than one line in the header.
    @discardableResult
    private func addTitleStatusLine(
        title: String, status: String, badge: NSView? = nil, style: String? = nil,
        stateBadge: NSView? = nil
    ) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = font
        titleLabel.textColor = ColorRole.label.defaultColor
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = font
        statusLabel.textColor = ColorRole.label.defaultColor
        // The style caption rides in the same dimmed ink as the detail line's numbers: it is a
        // supporting fact about the row, not a second title.
        var leadingViews: [NSView] = [titleLabel]
        if let style {
            let styleLabel = NSTextField(labelWithString: Self.separatorPrefix + style)
            // Italic, on top of the dimmed ink: the word is *about* the row rather than part of it —
            // a note on how the bar below is drawn, not another fact the row is reporting. Colour alone
            // put it in the same class as "18% used" and "resets in 3h", which are data.
            styleLabel.font = Self.italic(font)
            styleLabel.textColor = Self.dimmedLabelColor
            leadingViews.append(styleLabel)
        }
        if let badge { leadingViews.append(badge) }
        // Plain row — nothing on either side but the two labels. Both halves must be bare for this:
        // an early return that only checked the leading side silently dropped `stateBadge`, which is
        // exactly when the resting credits row loses its currency glyph while the ⌥ row keeps `active`
        // (the style word is what pushed the leading count past one).
        if leadingViews.count == 1, stateBadge == nil {
            return addSplitRow(leftLabel: titleLabel, rightLabel: statusLabel)
        }
        // The leading half is [title • style • badge]; the status stays flush right.
        let leading = NSStackView(views: leadingViews)
        leading.orientation = .horizontal
        leading.alignment = .centerY
        // 4, not 6: the style caption leads with `･`, whose own side bearing already separates it from
        // the title. At 6 the two gaps stacked and read as a double space.
        leading.spacing = 4
        // The badge gets more air than the style word does. `title` and `style` are two words of the
        // same sentence — "which row, on which scale" — and read as a pair at 6 pt; the badge is a
        // separate object about a different thing (the money), and at the same 6 pt the three ran
        // together into one stream. Applied to the view *before* the badge, which is the style label
        // when there is one and the title otherwise.
        if badge != nil, leadingViews.count >= 2 {
            leading.setCustomSpacing(12, after: leadingViews[leadingViews.count - 2])
        }
        // Same reason as the trailing stack below: the split row hands each half more width than its
        // contents need, and an unconstrained pill absorbs the surplus by widening its capsule around
        // a glyph that stays centred. `.fill` sends the surplus to the labels instead.
        leading.distribution = .fill
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        guard let stateBadge else {
            return addSplitRow(leadingView: leading, rightLabel: statusLabel)
        }
        // With a state badge the trailing half is [badge • status], the badge first: it qualifies the
        // word after it ("available … well ahead of pace" reads as one clause), and putting it after
        // would separate the status from the column edge every other row's status aligns to.
        let trailing = NSStackView(views: [stateBadge, statusLabel])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        // Wider than the 6 pt that separates the title from its style word. That pair is two words of
        // one phrase; this is a filled capsule against plain text, and at 6 pt (1.7 spaces at 13 pt)
        // the status read as if it were printed on the badge. 10 pt is ~2.8 spaces — the capsule's own
        // ~4.5 pt of internal padding makes the optical gap larger than the number suggests, so more
        // than this starts to detach the status from the badge it qualifies.
        trailing.spacing = 10
        // `.fill`, not the default: the split row hands this stack more width than its contents need
        // (it distributes with `.equalSpacing`), and under the default distribution the surplus was
        // absorbed by the badge — measured at 44.5 pt against a 19 pt intrinsic size, origin pushed to
        // x = −2. A stretched `PillView` widens its capsule without moving the glyph inside it, so the
        // currency sign rendered as an empty plaque bleeding off its own container while the wider
        // `active` word survived the same stretch. `.fill` plus the badge's own hugging priority sends
        // the surplus to the label instead.
        trailing.distribution = .fill
        trailing.setHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return addSplitRow(leadingView: leading, rightView: trailing)
    }

    /// `font` slanted, via the font **descriptor's** italic trait rather than by naming a face.
    ///
    /// The system font has no independently addressable italic family — asking for one by name gets a
    /// fallback, which on this surface would silently change the metrics of the word beside a row title.
    /// Adding the trait keeps the same family and size and lets the system supply its own slant. Falls
    /// back to the upright font if the descriptor cannot satisfy the trait.
    private static func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// The `･`-and-space prefix that introduces a secondary word inside one visual half — the style
    /// caption after a row title, the age after the "Claude" mark (#396).
    ///
    /// The same halfwidth katakana middle dot (U+FF65) `brandTitleLabel` puts before the plan, so the
    /// popup has **one** separator rather than a different mark per site. Attached to the following
    /// word rather than drawn as its own label: one text object means one baseline, and the gap on
    /// either side is the dot's own side bearing instead of a stack spacing to keep in sync.
    static let separatorPrefix = "･ "

    /// The style word for a bar, or `nil` when it must not be shown.
    ///
    /// Two rules, both of which a single header-level caption would get wrong:
    ///
    /// - **Only under ⌥.** The word explains rather than identifies, and ADR-0098 puts explanation on
    ///   the modifier: the zero tick already identifies the scale at a glance, and repeating one
    ///   global setting on every row would be noise in the resting popup.
    /// - **From the scale actually drawn, not from `barStyle`.** The credits bar is pinned to the
    ///   window scale by its `monthBounds` whatever the user picked (ADR-0092), so reading the setting
    ///   would caption it `balance` while it draws Progress — a caption that lies exactly where it is
    ///   the only thing explaining the odd-looking row.
    ///
    /// `nil` for a row with no bar (unlimited "Extra usage"): there is no scale to name.
    private func barStyleCaption(monthBounds: Bool = false) -> String? {
        guard optionHeld else { return nil }
        return monthBounds ? BarStyle.progress.caption : barStyle.caption
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
        // Pin the symbol to a **whole-point** box. An `NSImageView` holding an SF Symbol reports a
        // fractional intrinsic size — measured on this machine, `hand.raised` comes out 16 pt wide but
        // `clock` 15.5 and `exclamationmark.triangle` 16.5 — and this chip is the right-hand slot of the
        // `.firstBaseline` header row, the top row of the card. Half a point there is inherited by every
        // row below it, so the whole popup appears to shift when the badge comes or goes (⌥ swaps it for
        // an empty view). The labels were never the culprit: `NSTextField` rounds its own metrics to
        // whole points, image views do not.
        //
        // The constraint has to live on the image view, not on the row: `NSStackView` creates its
        // alignment constraints at `NSLayoutPriorityDefaultLow` and documents them as "overridable for
        // individual views using external constraints" (`NSStackView.h`), which is why pinning the row's
        // height had no effect while this does.
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: ceil(size) + 3),
            iconView.heightAnchor.constraint(equalToConstant: ceil(size) + 3),
        ])

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
        name.textColor = ColorRole.label.defaultColor

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = 8
        // Order: neutral → orange → red; only non-empty buckets. Each chip's tooltip states its
        // time-to-deletion bucket.
        let buckets: [(Int, NSColor, String)] = [
            (stat.recent, ColorRole.label.defaultColor, ">15d till deletion"),
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
        case .neutral: return ColorRole.label.defaultColor
        }
    }

    /// The **"in use"** marker shown next to the "Extra usage" heading while paid credits are actually
    /// covering an exhausted plan limit (`CreditsRow.inUse`): a `label`-coloured plaque carrying the
    /// currency glyph, or the word ``inUseWord`` under ⌥ (#254).
    ///
    /// Replaces the solid red `active` pill this badge used to be (#224). Crossing onto paid credit is a
    /// *mode change* worth flagging, but a red fill made it a *severity*: it took the same token as the
    /// blocking-reset badge — the one badge that means "you are stopped" — and it fired at its loudest at
    /// €0.00 spent, leaving nothing louder for the cap. A neutral plaque states the mode without claiming
    /// the row is blocked, and reuses the menu bar's own currency glyph
    /// (``StatusItemView/creditsSymbolName(for:)``) so both surfaces mark this feature with one symbol.
    ///
    /// Under ⌥ the glyph gives way to the word: the plaque is a *mode* marker, and a currency sign only
    /// hints at the mode by association. The hover text has always spelled it out — ⌥ now surfaces that
    /// without waiting for a hover, on the same gate as every other detail in the popup.
    ///
    /// **Same anatomy as the reset badge.** Both are ``PillView``, so they share a height and a
    /// silhouette; the content is painted in ``NSColor/cardPlateFillOpaque`` — the card's own colour with
    /// no alpha — which reads as cut out of the plaque while remaining an ordinary dynamic colour that
    /// flips with the theme. It used to be a literal hole punched through a mask, which needed its own
    /// view class, its own ink-measuring geometry and a rebuild on every appearance change; the three
    /// badges also came out three different heights (18.0 / 17.5–20.5 / 14.0 pt) because each sized
    /// itself to its own content.
    private func makeInUseMarker(currency: String) -> NSView {
        // The word takes the reset badge's own font — same size, same weight — so the two badges read as
        // one component with different contents rather than two similar-looking things. The glyph keeps
        // that size too; `PillView(symbol:)` scales the symbol from the font it is given.
        let font = Self.pillFont
        // Neutral grey fill, label-coloured content (#396).
        //
        // The plaque used to be filled with `labelColor` and knocked its glyph out in the card's own
        // colour. Filled that strongly it read as loud as the blocking-reset badge beside it, putting
        // "money is moving" — a fact — in the same visual class as "you are blocked". The fill is now
        // the bar track's grey, and with it the knockout stops making sense: cutting a hole through a
        // light grey shows the card at nearly the same tone, so the glyph fades instead of reading.
        // Ordinary `label` ink on grey is the same relationship every other row has with the card.
        let badge: PillView = optionHeld
            ? PillView(text: Self.inUseWord, font: font, textColor: ColorRole.label.defaultColor,
                       fill: { ColorRole.barTrack.defaultColor })
            : PillView(symbol: StatusItemView.creditsSymbolName(for: currency), font: font,
                       textColor: ColorRole.label.defaultColor,
                       fill: { ColorRole.barTrack.defaultColor })
        badge.toolTip = Self.inUseHint
        badge.setAccessibilityLabel(Self.inUseAccessibilityLabel)
        Self.pinToIntrinsicSize(badge)
        return badge
    }

    /// The word knocked out of the "in use" marker under ⌥, in place of the currency glyph.
    static let inUseWord = "active"

    /// Hover text for the "in use" marker — the words the old `active` badge used to spell out, stating
    /// explicitly that the spending is happening *right now*.
    static let inUseHint = "Currently spending Extra Usage Credit — your plan limit is exhausted"

    /// VoiceOver label for the "in use" marker.
    static let inUseAccessibilityLabel = "currently spending Extra Usage Credit"

    /// Pin a badge to the size of its own contents, in both axes.
    ///
    /// Every stack this popup puts a badge in distributes with `.equalSpacing`, which stretches its
    /// arranged views. A stretched ``PillView`` grows its **capsule** without moving the text or glyph
    /// inside it, so the badge reads as lopsided — and a one-character badge (a currency sign) reads as
    /// an empty plaque, while a wider one survives by accident.
    private static func pinToIntrinsicSize(_ view: NSView) {
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    /// The **`out of credits`** badge (#396): the money cap is spent, so the paid tier can no longer
    /// cover an exhausted plan limit.
    ///
    /// Red, and mutually exclusive with the `in use` plaque by construction rather than by a check
    /// here: once `spend_limit_reached`, the server sets `enabled: false`, so `CreditsPacing.isSpending`
    /// is false and `credits.inUse` cannot be true at the same time. The two badges can never appear
    /// on one row.
    private func makeOutOfCreditsBadge() -> NSView {
        let pill = Self.makePill(text: Self.outOfCreditsWord, fill: { PopupBarView.gapRed })
        pill.toolTip = Self.outOfCreditsHint
        pill.setAccessibilityLabel(Self.outOfCreditsHint)
        Self.pinToIntrinsicSize(pill)
        return pill
    }

    /// The badge the **capped** "Extra usage" header carries, if any (#396).
    ///
    /// Only one state earns a badge here: `credits.inUse` — money is moving *right now* — drawn as the
    /// `$` plaque (`active` under ⌥). Everything else draws nothing:
    ///
    /// - **Cap spent** (`usageFraction >= 1`): the status word already reads "limit reached", and the
    ///   red belongs on the **reset** badge in the line below (`resetIsBlocking`, #158) — that is what
    ///   the user is waiting for. One filled red per row, on the thing that actually unblocks.
    /// - **Enabled but idle**: no badge, because "available" is not a fact the badge would be adding.
    ///   The section is only built at all when `CreditsPacing.isActive` holds (`PopupLayout.creditsRow`),
    ///   so the row's mere presence already says credits are switched on; the absence of a red badge
    ///   says they are not spent; the absence of the plaque says nothing is overflowing onto them right
    ///   now. A grey `available` capsule restated all three and was the widest badge in the popup,
    ///   setting the window's width for the state where nothing is happening.
    ///
    /// The plaque and a red badge can never both apply: `spend_limit_reached` makes the server set
    /// `enabled: false`, which makes `CreditsPacing.isSpending` — and so `inUse` — false.
    private func creditsStateBadge(_ credits: CreditsRow, bar: BarLayout) -> NSView? {
        // Exhausted with a cap set: the status word already says "limit reached", and the **reset** is
        // what the user is waiting on — so the red lives on the reset badge in the line below
        // (`resetIsBlocking`, #158), not here. A red badge in both lines would spend the popup's one
        // alarming colour twice on one fact; the rule is that a row carries at most one filled red, and
        // it marks the thing that actually unblocks.
        //
        // `nil` rather than a neutral badge: with the cap spent, "available" would be false and the
        // currency plaque claims spending that is not happening.
        if bar.usageFraction >= 1 { return nil }
        if credits.inUse { return makeInUseMarker(currency: credits.spent.currency) }
        return nil
    }

    /// The state badge for the **unlimited** credits row, which has no bar and no reset line (#396).
    ///
    /// Same three states, resolved from the flags rather than from a bar fraction — without a cap there
    /// is nothing for a fraction to be `1` of, yet the credits can still be spent out (the server sets
    /// `spend_limit_reached` and disables them). This row is the only line the section draws, so unlike
    /// the capped row it *does* carry the red itself: there is no reset badge beneath it to mark the
    /// blocker.
    private func creditsUnlimitedStateBadge(_ credits: CreditsRow) -> NSView? {
        if credits.spendLimitReached { return makeOutOfCreditsBadge() }
        if credits.inUse { return makeInUseMarker(currency: credits.spent.currency) }
        return nil
    }

    /// The status word for a credits row with **no cap** (#396). There is no pace to be on when there
    /// is no ceiling, so the row states the billing configuration instead of a verdict — and states it
    /// in the same slot every other section puts its verdict, rather than moving the amount up there.
    static let creditsUnlimitedWord = "no limit set"

    /// The word on the exhausted-credits badge.
    static let outOfCreditsWord = "out of credits"

    /// Hover text for `out of credits` — the paid tier is spent, so an exhausted plan limit now
    /// actually blocks work until it resets.
    static let outOfCreditsHint =
        "Extra Usage Credit is spent — an exhausted plan limit now blocks work until it resets"

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
    ///
    /// ``PillView`` is a label whose cell pads its own text — see that type for why the padding lives
    /// there rather than in constraints or in hand-drawing.
    private static func makePill(text: String, fill: @escaping () -> NSColor) -> NSView {
        PillView(text: text, font: pillFont, textColor: ColorRole.pillText.defaultColor, fill: fill)
    }

    /// The type face every badge uses — the blocking reset, the credits currency glyph and the ⌥ word
    /// alike. One constant rather than one per call site: the badges appear in the same popup, and a
    /// half-point difference between them reads as a mistake rather than a distinction.
    static let pillFont: NSFont = .systemFont(ofSize: Metrics.textSize - 2, weight: .medium)

    @discardableResult
    private func addLabel(_ text: String, font: NSFont, secondary: Bool = false, color: NSColor? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color ?? (secondary ? Self.dimmedLabelColor : ColorRole.label.defaultColor)
        stack.addArrangedSubview(label)
        return label
    }

    /// The per-limit detail line: `used` percent flush left, `reset` countdown flush **right** against
    /// the content width — the percent leads the line (under the "% used" reading) while the reset time
    /// lines up with the bar's right edge below it.
    ///
    /// When the two halves cannot both fit the content column, the **reset is dropped** and the left
    /// half renders alone (``detailHalvesFit(left:right:font:)``). The row is an `NSStackView` with
    /// `.equalSpacing`, so the alternative is not wrapping but Auto Layout compressing one label into an
    /// ellipsis — and a truncated `resets in 5d on Fri…` is worse than no reset at all. It is dropped
    /// rather than blanked: an empty label would still claim its slot.
    ///
    /// This bites mainly under ⌥ on the credits line, where both halves grow at once and the amounts are
    /// the popup's widest. A **blocking** reset (#158) is exempt — it is the one fact that says when work
    /// becomes possible again, so it keeps its badge whatever the width.
    ///
    @discardableResult
    /// `reset` is `nil` for a row that has none to show — the unlimited credits line (#396), whose left
    /// half is the whole line. That takes the same path as a right half dropped by the fit gate below,
    /// so both shapes render identically rather than through two layouts.
    private func addDetailLine(used: String, reset: String?, resetIsBlocking: Bool = false) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)
        let usedLabel = NSTextField(labelWithString: used)
        usedLabel.font = font
        usedLabel.textColor = Self.dimmedLabelColor
        guard let reset else {
            usedLabel.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(usedLabel)
            return usedLabel
        }
        // When this reset is the one blocking work (#158), show it as a red **badge** so the eye lands on
        // the single reset that will actually unblock — every other reset stays the plain dimmed label,
        // even if its own limit is also exhausted.
        if resetIsBlocking {
            return addSplitRow(leadingView: usedLabel, rightView: makeResetBadge(text: reset))
        }
        guard Self.detailHalvesFit(left: used, right: reset, font: font) else {
            usedLabel.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(usedLabel)
            return usedLabel
        }
        let resetLabel = NSTextField(labelWithString: reset)
        resetLabel.font = font
        resetLabel.textColor = Self.dimmedLabelColor
        return addSplitRow(leftLabel: usedLabel, rightLabel: resetLabel)
    }

    /// The 7-day row's **stand-by** line: how long to pause for the bar to come back to green,
    /// e.g. `"stand by 3h for green"` — a third line under the detail line, flush **right** so it
    /// stacks with the reset above it and the bar's right edge below.
    ///
    /// Right-aligned by pinning the label's own trailing edge, not via ``addSplitRow``: that one
    /// distributes with `.equalSpacing`, which for a single arranged view leaves it flush *left*.
    ///
    /// Deliberately **not colour-coded.** The pacing colour is the model's verdict (`severity`), and
    /// tinting this line orange/green would put a second, competing verdict on the same row — the
    /// recurring "raise the weight of the input" mistake the bar rules warn about. It stays
    /// ``dimmedLabelColor``, the same ink as the detail line it hangs off.
    @discardableResult
    private func addStandByLine(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Metrics.textSize)
        label.textColor = Self.dimmedLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        stack.addArrangedSubview(label)
        return label
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
    ///
    /// A ``PillView`` trailing half is nudged **out** by ``badgeColumnOvershoot`` so the badge's *text*
    /// lands in roughly the same column as every other row's reset.
    ///
    /// The row pins whatever it is given flush right. For a plain label that puts the last glyph on the
    /// column edge, but for a badge it puts the *capsule* there and the text sits ``PillView/hInset``
    /// further left — 6 pt, 13 px measured in a render. The popup routinely shows both anatomies at
    /// once (the blocking row is badged, the others are not), so the badged reset visibly hangs back
    /// from the column the rest line up on.
    ///
    /// `alignmentRectInsets` is the API meant for exactly this, but `NSStackView` lays its arranged
    /// views out by frame and ignores it — measured, the text did not move at all — so the shift is
    /// applied to the row instead.
    ///
    /// The trailing **label** is right-aligned (a `PillView` is left alone — it draws its own padded
    /// capsule). That is what keeps its glyphs still when ⌥ swaps a short reset string for a long one.
    ///
    /// Measured: a text field's resolved width carries a fractional remainder, because it comes from font
    /// metrics rather than whole points (`on pace` reports `intrinsicContentSize.width` 48.5 at 13 pt,
    /// `limit reached` 78.5). With the default leading alignment the string's origin is
    /// `rightEdge − resolvedWidth`, so any rounding of that width displaces every glyph — and since the
    /// remainder differs per string, the two ⌥ states landed the shared `at HH:MM` tail on different
    /// sub-pixel positions: 232.11 against 232.28 on one row, 230.33 against 229.50 on another, close to
    /// two device pixels on the 2× displays this popup draws on. Right-aligning moves the remainder into
    /// the empty space *before* the text, where nothing can see it. Measured after the change: 0.000.
    ///
    /// Rounding the label's width instead is the wrong lever — it does not remove the remainder, it only
    /// makes it constant per string, and per-string is exactly the axis along which ⌥ varies.
    @discardableResult
    private func addSplitRow(leadingView: NSView, rightView: NSView) -> NSView {
        if let label = rightView as? NSTextField, !(rightView is PillView) {
            label.alignment = .right
        }
        let row = NSStackView(views: [leadingView, rightView])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        if rightView is PillView {
            row.edgeInsets = NSEdgeInsets(
                top: 0, left: 0, bottom: 0, right: -Self.badgeColumnOvershoot)
        }
        stack.addArrangedSubview(row)
        return row
    }

    /// The badge is **not** shifted past the content column: its capsule ends where every other row's
    /// text ends.
    ///
    /// An earlier version pushed it out so the badge's *text* would share the column with the plain
    /// resets, letting the capsule overhang. That reads wrong — the filled shape is the widest thing on
    /// the row, so its edge sticking out past the text above it looks like a layout error rather than a
    /// deliberate bleed. Aligning the capsule instead leaves the badge's text slightly inside the
    /// column, which is what padding on a filled shape is supposed to look like. Every 2 pt of shift
    /// moves the capsule 4 px past the column (measured), so the value is zero.
    private static let badgeColumnOvershoot: CGFloat = 0

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
        label.textColor = secondary ? Self.dimmedLabelColor : ColorRole.label.defaultColor
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
    ///
    /// The symbol and colour are parameters because not every block that uses this shape is an error:
    /// "monitoring is off" (#341) is a state the user chose, and painting it red would report their
    /// own setting back to them as a fault. The defaults keep every existing caller unchanged.
    @discardableResult
    private func addWarningTitle(
        _ text: String,
        symbolName: String = "exclamationmark.triangle.fill",
        color: NSColor? = nil
    ) -> NSView {
        let font = NSFont.boldSystemFont(ofSize: Metrics.textSize)
        let color = color ?? ColorRole.red.defaultColor
        let attributed = NSMutableAttributedString()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "warning")?
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
               blocked: row.sessionBlocked,
               isLast: isLast, isBaseLimit: isBaseLimit, tweenRow: row.title)
    }

    /// Add a pacing bar from raw geometry — shared by the token limit rows and the "Extra usage"
    /// credits section (#145), which has no ``LimitRow``. `subdivisions == 0` draws no tick ruler
    /// (a calendar month has no equal window boundaries to mark); `idle` draws the green knobless
    /// 5h track (#100). When `bar` is `nil` the view draws nothing — but callers only reach here with a
    /// real bar (idle uses the flag, not the layout).
    ///
    /// `monthBounds` is the credits section's alone: it captions the bar's two ends with the money
    /// window's first and last day **and** puts the bar into its always-Progress presentation, since
    /// both follow from the same fact — this window is a calendar month.
    private func addBar(bar: BarLayout?, subdivisions: Int, idle: Bool, blocked: Bool = false,
                        isLast: Bool, isBaseLimit: Bool = false, tweenRow: String? = nil,
                        monthBounds: (start: String, end: String)? = nil) {
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
        view.idle = idle   // green knobless pill when the 5h window is idle (#100)
        view.blocked = blocked   // grey instead of green when that idle state is blocked (#158)
        view.isBaseLimit = isBaseLimit   // only base 5h/7d rows render the far-behind blue zone
        view.barStyle = barStyle   // Progress (gap+marker) vs Pressure/Balance (marker-less ribbons) — #224
        view.optionHeld = optionHeld   // the under-bar ruler (teeth + month captions) is ⌥-on-demand
        // Credits only: captions the month's ends and pins the bar to Progress, overriding `barStyle`.
        view.monthBounds = monthBounds
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        // Every bar is the same height, credits included (#396). The credits row used to be taller by a
        // text line to make room for its `Jan 1` / `Feb 1` captions; those are gone, and reserving their
        // box would leave the section standing on a gap no other row has.
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
    ///
    /// `showsStatusWord: false` keeps the dot and the age but drops the word — for a row whose label
    /// is already the whole statement. "No ongoing incidents · operational" reads as an answer to two
    /// different questions at once: the label answers the incident dimension, the word answers the
    /// service one (#341).
    @discardableResult
    private func addServiceStatusRow(
        label: String, status: ServiceStatus, age: TimeInterval? = nil, showsStatusWord: Bool = true
    ) -> NSView {
        let font = NSFont.systemFont(ofSize: Metrics.textSize)

        // Leading half: the colour dot (#130) as a glowing layer-backed subview (#188 — re-resolves on a
        // theme flip, unlike a baked image) + the component's display label (e.g. "API"). No status word
        // here — it is the trailing half, so every status word right-aligns into one column.
        let dot = makeStatusDot(status: status, animatorKey: label)
        dot.toolTip = status == .operational ? "operational" : "issue"
        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = font
        nameLabel.textColor = ColorRole.label.defaultColor
        let leadingLabel = NSStackView(views: [dot, nameLabel])
        leadingLabel.orientation = .horizontal
        leadingLabel.alignment = .centerY
        // The nudge moves the dot alone: it is taken out of the gap that follows, so the name still
        // starts at `statusDotDiameter + statusDotGap` and the text column does not move (#351).
        leadingLabel.spacing = Metrics.statusDotGap - Metrics.statusDotNudge
        leadingLabel.edgeInsets = NSEdgeInsets(
            top: 0, left: Metrics.statusDotNudge, bottom: 0, right: 0)
        // Dot flush-left with the rest of the widget's text (bar the optical nudge above), so the
        // status rows align on the same left edge as "5-hour"/"7-day" and the per-project rows (#233).

        // Trailing half, pinned flush-right: how long the component has been in this state, then the
        // status word. Operational → plain dimmed text (no link); otherwise → underlined link colour,
        // opened on click by StatusLineLabel over the word's range.
        //
        // The word keeps linking to the **general** status page rather than to a specific incident:
        // a component can be degraded by more than one incident at once (measured — two incidents
        // named the same four components), so there is no single right target here. The per-incident
        // link lives on the incident row, where the question "which one" has an answer (ADR-0071 §3).
        let trailing: NSView
        if showsStatusWord {
            trailing = Self.makeLinkWord(
                Self.word(status),
                url: status == .operational ? nil : StatusHealth.pageURL,
                prefix: age.map { Self.durationMinutes(Int($0)) + " · " })
        } else {
            // Age alone, in the same dimmed tone the word's prefix uses, so the column still lines up
            // with the rows that do carry a word.
            let ageLabel = NSTextField(labelWithString: age.map { Self.durationMinutes(Int($0)) } ?? "")
            ageLabel.font = font
            ageLabel.textColor = Self.dimmedLabelColor
            trailing = ageLabel
        }

        return addSplitRow(leadingView: leadingLabel, rightView: trailing)
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
            ? [.font: font, .foregroundColor: ColorRole.link.defaultColor,
               .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: ColorRole.label.defaultColor]))

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
        let built = Self.incidentText(
            name: incident.name, meta: meta, isLinked: incident.shortlink != nil, font: font)
        let text = built.text
        let stageStart = built.stageStart
        // The chip's own line is not one of the description's, so the cap gains it back — otherwise a
        // three-line description would push the chip onto a fourth line and the label would elide it.
        let maxLines = Self.maxIncidentDescriptionLines + (built.chipOnOwnLine ? 1 : 0)

        let label = StatusLineLabel(labelWithAttributedString: text)
        // `labelWithAttributedString` hands back a single-line field, and `usesSingleLineMode`
        // silently overrides `maximumNumberOfLines` — so the description would truncate at one line
        // no matter what the paragraph style said. Clearing it (and giving the cell a wrapping line
        // break) is what actually lets the text wrap.
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.maximumNumberOfLines = maxLines
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
        // Same optical nudge as the service rows, taken out of the following gap so the description
        // column stays put — it is also what `incidentTextWidth` and the right tab stop assume.
        row.spacing = Metrics.statusDotGap - Metrics.statusDotNudge
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.statusDotNudge, bottom: 0, right: 0)
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

    /// The incident row's attributed text: the description, then the `age · stage` chip set flush
    /// right — on the description's last line when it fits there, on a line of its own when it does
    /// not. Returns the chip's stage offset too, which the label needs for its link range.
    ///
    /// Two mechanisms, because one alone gets the wrapped case wrong. A right tab stop only aligns
    /// text that still shares the line the tab sits on; once the chip is pushed past the stop it wraps
    /// to the next line, where the stop is behind the caret and no longer pulls anything — the chip
    /// then sat flush **left** under the description (#351). So the fit is measured up front: when the
    /// chip does not fit after the description's last line, the tab is replaced by a hard newline and
    /// the chip's own paragraph is right-aligned, which needs no tab stop to reach the trailing edge.
    static func incidentText(
        name: String,
        meta: (age: String?, stage: String),
        isLinked: Bool,
        font: NSFont
    ) -> (text: NSMutableAttributedString, stageStart: Int, chipOnOwnLine: Bool) {
        let ageAndSeparator = meta.age.map { "\($0) · " } ?? ""
        let chip = ageAndSeparator + meta.stage
        let separator = chipFitsAfterDescription(name: name, chip: chip, font: font) ? "\t" : "\n"

        let text = NSMutableAttributedString(
            string: name + separator,
            attributes: [.font: font, .foregroundColor: ColorRole.label.defaultColor])
        if !ageAndSeparator.isEmpty {
            text.append(NSAttributedString(
                string: ageAndSeparator, attributes: [.font: font, .foregroundColor: dimmedLabelColor]))
        }
        let stageStart = text.length
        text.append(NSAttributedString(string: meta.stage, attributes: isLinked
            ? [.font: font, .foregroundColor: ColorRole.link.defaultColor,
               .underlineStyle: NSUnderlineStyle.single.rawValue]
            : [.font: font, .foregroundColor: dimmedLabelColor]))

        // A right tab stop at the content's trailing edge pulls everything after the tab flush right;
        // the description wraps ahead of it and the chip settles on whatever line it lands on.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: incidentTextWidth)]
        // Word-wrapping, **not** truncating: a truncating line-break mode in the paragraph style
        // suppresses wrapping outright, so the description collapsed to a single elided line no
        // matter what `maximumNumberOfLines` said (measured: 16 pt tall for an 87-character name).
        // The line cap is enforced by `maximumNumberOfLines`, which still elides the last line.
        paragraph.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

        if separator == "\n" {
            // The chip is on its own line: right-align that paragraph outright. Applied from the
            // newline onwards so the description's paragraph keeps its natural left alignment — a
            // paragraph style covers whole paragraphs, and the newline terminates the first one.
            let chipParagraph = NSMutableParagraphStyle()
            chipParagraph.alignment = .right
            chipParagraph.lineBreakMode = .byWordWrapping
            let newlineIndex = (name as NSString).length
            text.addAttribute(
                .paragraphStyle, value: chipParagraph,
                range: NSRange(location: newlineIndex, length: text.length - newlineIndex))
        }
        return (text, stageStart, separator == "\n")
    }

    /// Whether `chip` still fits on the last line the description wraps onto, at the incident text
    /// width. Laid out with `TextKit` rather than estimated: the description's own wrapping decides
    /// where its last line ends, and only a layout pass knows that.
    ///
    /// The cap on description lines is applied here too — a description that overruns it is elided on
    /// its last line, which leaves no room to share, so the chip goes to its own line.
    private static func chipFitsAfterDescription(name: String, chip: String, font: NSFont) -> Bool {
        let storage = NSTextStorage(string: name, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: incidentTextWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var lineCount = 0
        var lastLineWidth: CGFloat = 0
        var index = 0
        let glyphCount = layoutManager.numberOfGlyphs
        while index < glyphCount {
            var lineRange = NSRange()
            let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &lineRange)
            lineCount += 1
            lastLineWidth = rect.maxX
            index = NSMaxRange(lineRange)
        }
        guard lineCount <= maxIncidentDescriptionLines else { return false }

        // A minimum gap so the chip never butts against the description; the tab stop would otherwise
        // allow them to touch when the last line ends a hair short of the chip's start.
        let gap: CGFloat = 12
        let chipWidth = (chip as NSString).size(withAttributes: [.font: font]).width
        return lastLineWidth + gap + chipWidth <= incidentTextWidth
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
        case .operational:      return ColorRole.green.defaultColor
        case .degraded:         return ColorRole.yellow.defaultColor
        case .partialOutage:    return ColorRole.orange.defaultColor
        case .majorOutage:      return ColorRole.red.defaultColor
        case .underMaintenance: return ColorRole.blue.defaultColor
        case .unknown:          return ColorRole.gray.defaultColor
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

    /// Index of the **7-day** row in `PopupLayout.rows`. The layout always emits the two base windows
    /// first — `0` = 5-hour, `1` = 7-day — with the per-model rows appended after (the same ordering
    /// `isBaseLimit: index <= 1` relies on when gating the far-behind blue).
    static let sevenDayRowIndex = 1

    /// The ⌥ stand-by line: `"stand by 3h for green"` — how long to stop spending for this
    /// window to come back to green. `nil` whenever there is no such advice to give, which is most of
    /// the time (see ``PacingModel/displayableStandBySecondsForGreen(_:)``).
    ///
    /// **The advice is only true while nothing is spent**, which is exactly what "stand by" asks for.
    /// The wording carries that condition; a bare `"3h to green"` would read as a forecast and be wrong
    /// the moment the next request lands.
    ///
    /// The duration goes through ``ResetClock/rounded(duration:)`` — the *same* band table the reset
    /// countdown uses — so this line says `"3h"` in the same minute the line above says `"3h"`, and
    /// the popup never grows a second duration format (ADR-0074).
    static func standByText(_ row: LimitRow) -> String? {
        guard let seconds = PacingModel.displayableStandBySecondsForGreen(row.bar),
              let duration = ResetClock.rounded(duration: seconds) else { return nil }
        return "stand by \(duration) for green"
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
        // Mirror of `behindColor`'s first test — keep the two edited together (see that method).
        if !bar.blueAllowed { return false }
        let elapsed = Double(bar.windowDurationSeconds) - bar.remainingSeconds
        if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return false }
        return (bar.timeFraction - bar.usageFraction) > PacingModel.behindThreshold(windowDurationSeconds: bar.windowDurationSeconds)
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
    /// `"spent €10.77 of €15.00"` under ⌥ — spent out of limit, both formatted from their exact
    /// ``Money`` integers (never a rounded `Double`).
    ///
    /// The precision is an **⌥ detail**, the same gate `usedText`/`resetText` use: at rest the amounts
    /// carry three significant digits so the line stays as narrow as the numbers themselves, and holding
    /// Option reveals every cent of both.
    ///
    /// The ⌥ form also names the verb, and names it **first**: `spent €10.77 of €15.00`, not
    /// `€10.77 of €15.00 spent`. A trailing `spent` binds to the nearest noun phrase — the *cap* — so
    /// the postfixed reading is "€10.77 of the €15.00 that were spent", exactly inverting which number
    /// is the money gone. Leading, the verb can only govern the first amount. The unlimited line
    /// (``creditsSpentOnlyText(_:verbose:)``) leads with `spent` too (#396): it has one number, so
    /// nothing there could mis-bind, but a word that moved from the end of the line to the front the
    /// moment ⌥ went down made the two forms read as different facts rather than one fact at two
    /// precisions.
    ///
    /// The cap is shown even at **zero spend** (`€0 of €15`). Dropping it there would render as a bare
    /// `€0`/`€0 spent`, which is precisely the unlimited line's shape — two different billing
    /// configurations collapsing onto one string. The cap is what distinguishes them.
    ///
    /// At rest the two halves are formatted **differently on purpose**: the spend keeps the ladder
    /// (``compactMoneyText(_:)``), the cap additionally drops a zero fraction
    /// (``CompactMoney/capText(_:)`` → `€15`, not `€15.0`). They are different kinds of number — the
    /// spend moves and its precision carries information, the cap is a constant the user typed into
    /// billing, and every captured limit is whole. Under ⌥ both go exact, so the asymmetry exists only
    /// in the narrow resting form.
    static func creditsAmountText(spent: Money, limit: Money, verbose: Bool = false) -> String {
        guard !verbose else { return "spent \(moneyText(spent)) of \(moneyText(limit))" }
        return "\(compactMoneyText(spent)) of \(CompactMoney.capText(limit))"
    }

    /// Whether a detail line's two halves both fit on one line at `font`, keeping at least
    /// ``Metrics/minSplitGap`` of air between them.
    ///
    /// The row is an `NSStackView` pinned to ``Metrics/contentWidth`` with `.equalSpacing`: when the two
    /// labels are too wide it does **not** wrap, it compresses one of them into an ellipsis. A truncated
    /// `resets in 5d on Fri…` is worse than no reset at all — the amounts are the fact the user opened
    /// the popup for, and the reset is repeated in the menu bar anyway. So the caller drops the right
    /// half instead of letting Auto Layout pick a victim.
    ///
    /// Measured with `NSAttributedString.size()` rather than a stored metric because the strings are
    /// locale- and currency-dependent (`10,77 kr`, `12.00 UAH`) and the font follows the system text
    /// size — no constant could stand in for either.
    ///
    /// Measured widths at 13 pt against the **320 pt** column (#396; the figures below were calibrated
    /// against 268 when the mirrors still disagreed with the real 252 — both are gone):
    /// - `20% used` + `resets in 2h at 02:50` → 198 pt — every token row fits with room to spare.
    /// - `€10.8 of €15` + `5d on Friday` → 162 pt — the resting credits line always fits.
    /// - `spent €10.77 of €15.00` + `resets in 5d on Friday` → 281 pt — **now fits.** At 252 this
    ///   ordinary ⌥ line was dropped; the wider column is what buys it back, which is half the point
    ///   of widening (#396).
    /// - `spent €1,234.56 of €2,000.00` + `resets in 5d on Friday` → 322 pt — still fits at 330.
    /// - `spent $5,000.00 of $5,000.00` + `resets in 20d next Wednesday` → 376 pt — the gate's remaining
    ///   job: a four-figure cap with the longest reset phrase still overflows and drops the reset.
    static func detailHalvesFit(left: String, right: String, font: NSFont) -> Bool {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let leftWidth = (left as NSString).size(withAttributes: attrs).width
        let rightWidth = (right as NSString).size(withAttributes: attrs).width
        return leftWidth + Metrics.minSplitGap + rightWidth <= Metrics.contentWidth
    }

    /// The **unlimited** row's amount line: `"spent €10.8"` — the spent amount with the verb leading,
    /// no cap and no reset (there is nothing to pace against). Since #396 this is the row's own second
    /// line rather than a status standing in the header's right half, so it lines up with
    /// ``creditsAmountText(spent:limit:verbose:)`` on every capped row.
    ///
    /// Same ⌥ precision gate as that one: three significant digits at rest, exact under Option — and
    /// the same leading `spent`, so the word does not jump from the end of the line to the front when
    /// the modifier goes down.
    static func creditsSpentOnlyText(_ spent: Money, verbose: Bool = false) -> String {
        "spent \(verbose ? moneyText(spent) : compactMoneyText(spent))"
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
