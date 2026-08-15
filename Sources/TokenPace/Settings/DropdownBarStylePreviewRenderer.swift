import AppKit
import TokenPaceKit

// MARK: - DropdownBarStylePreviewRenderer

/// Draws the specimen each ``BarStyle`` tile shows in the **dropdown**'s Style row — with the real
/// `PopupBarView`, at runtime, exactly as ``BarStylePreviewRenderer`` does for the menu bar (#374).
///
/// The two renderers are deliberately separate rather than one parameterised by surface. What they
/// share is the *principle* — render, never ship a screenshot (ADR-0093, ADR-0097) — while almost every
/// concrete decision differs, and ADR-0097 recorded those differences as intentional so that a later
/// reader does not "unify" them back into a bug:
///
/// - **Appearance.** The menu-bar specimen bakes under `.vibrantDark` *always*, because the menu bar is
///   dark under a light theme too and its tile's plate is black in both. This surface has no such
///   property: the dropdown is a Control-Center-style card that flips with the system, so the specimen
///   bakes under whatever appearance is current and the tile's plate is the card's own colour.
/// - **Geometry.** `StatusItemView` has a fixed 34 pt width; `PopupBarView` stretches to the popup card
///   (252 pt) and has no intrinsic width at all, so the tile has to *choose* one — see ``barWidth``.
/// - **The ruler.** The popup bar has an under-bar ruler the menu bar has no equivalent of, gated on a
///   held ⌥. It is left off here; see ``barViews(for:)``.
@MainActor
enum DropdownBarStylePreviewRenderer {

    /// How wide the bar is drawn in the tile.
    ///
    /// The bar is drawn **at this width directly**, at 1:1 in both axes: the track keeps its 6 pt, the
    /// marker its 7×14 and the zero tick its exact size, which is what ADR-0093 §3 requires of a preview
    /// and what any scaling would blur.
    ///
    /// Shortening the bar does *not* misplace the marks, which is the thing to check before accepting
    /// a length. `scaleX` insets the 0..1 scale by `minStripWidth/2` — a constant 1.75 pt, derived from
    /// the bar's height rather than its length — at each end. Computed across the two widths, that inset
    /// costs 5.6 % of a 56 pt bar against 1.4 % of the live 252 pt one, and the largest resulting shift
    /// in any mark's position is about **2 % of the bar's width**. Visible only if measured; the shapes
    /// and their order are identical.
    ///
    /// Windowing onto the leading slice of a live-width render was tried first and is much worse: on
    /// this specimen frame both the marker and the coloured strip sit past the first quarter of the bar,
    /// so the tile showed a bare grey track with neither — measured, not guessed.
    static let barWidth: CGFloat = 56

    /// The specimen frame — the **same** `climbing` first-poll values the menu-bar tiles bake
    /// (`BarStylePreviewRenderer.Specimen`), deliberately.
    ///
    /// Two surfaces explaining the same three styles with two different datasets would invite the reader
    /// to attribute a difference in the pictures to the surface when it came from the numbers. Sharing
    /// the frame means any difference on screen is a rendering difference, which is the only kind worth
    /// showing here.
    private enum Specimen {
        /// 5-hour window: a fifth spent with 2 of its 5 hours left — behind pace, so this bar is calm.
        static let fiveHourUtilization = 20.0
        static let fiveHourRemaining: TimeInterval = 2 * 3600
        /// 7-day window: over half spent with 5 of its 7 days left — ahead of pace, so this one is not.
        static let sevenDayUtilization = 55.0
        static let sevenDayRemaining: TimeInterval = 5 * 24 * 3600
    }

    // MARK: Layout

    /// The tile's two bars: the 5-hour window above, the 7-day below — the order the live dropdown
    /// stacks them in, so the pair reads as a miniature of that surface rather than as two samples.
    ///
    /// Both go through `PacingModel.barLayout` rather than being written out as `BarLayout` literals:
    /// the pacing state and the blue gate are *computed* from the numbers, and hand-writing their
    /// results is how a specimen drifts from what the app would actually draw. `now` is a constant, so
    /// the frame is deterministic.
    private static func barViews(for style: BarStyle) -> [PopupBarView] {
        // Any fixed instant works — only the differences below are read.
        let now = Date(timeIntervalSinceReferenceDate: 0)

        let fiveHour = PopupBarView(frame: .zero)
        // `blueAllowed: false` is what the app computes for this frame, not a nudge toward a colour:
        // `PacingModel.weeklyHasHeadroom` shuts the gate whenever the weekly window is ahead of pace,
        // and this specimen's is (55 % spent against 28.6 % elapsed). Passing it explicitly also removes
        // a real fragility — the 5-hour surplus (0.40) sits exactly on the 5-hour `behindThreshold`
        // (3600/18000 = 0.40), where a strict `>` is decided by floating-point noise. See the same note
        // in `BarStylePreviewRenderer.specimenLayout()`.
        fiveHour.bar = PacingModel.barLayout(
            utilization: Specimen.fiveHourUtilization,
            resetsAt: now.addingTimeInterval(Specimen.fiveHourRemaining),
            now: now, window: .fiveHour, blueAllowed: false)
        fiveHour.subdivisions = 5
        fiveHour.isBaseLimit = true
        fiveHour.barStyle = style

        let sevenDay = PopupBarView(frame: .zero)
        sevenDay.bar = PacingModel.barLayout(
            utilization: Specimen.sevenDayUtilization,
            resetsAt: now.addingTimeInterval(Specimen.sevenDayRemaining),
            now: now, window: .sevenDay)
        sevenDay.subdivisions = 7
        sevenDay.isBaseLimit = true
        sevenDay.barStyle = style

        // `optionHeld` is left at its `false` default on both, and that is the whole decision about the
        // ruler: ⌥ must not reach a specimen. In the live dropdown the modifier reveals the explanatory
        // teeth and the `0` caption *while held*, so a tile baked with them on advertises a state the
        // row is not in — and, measured, that caption dominates a tile this size. Nothing identifying is
        // lost: the mark that tells Pressure from Gauge is the zero struck through the track, which
        // `drawZeroTick` draws unconditionally, in every style, held or not.
        //
        // No `colorAnimator` either — a specimen has no previous value to ease away from, so every
        // colour resolves straight to its target.
        return [fiveHour, sevenDay]
    }

    // MARK: Image

    /// The specimen drawn in `style` at the tile's size, ready for `Image(nsImage:)`.
    ///
    /// **The image is transparent apart from the bars**, and what sits behind it is load-bearing rather
    /// than decorative: the track (`PopupBarView.monochromeGrey`) and the marker's border are both
    /// *translucent*, so the plate underneath mixes into them. The tile must therefore be backed by the
    /// same fill the live bars sit on — the popup **card** (`NSColor.cardPlateFillOpaque`), not the menu
    /// plate the card floats on. Measured with both open side by side in the light theme, the wrong
    /// backdrop rendered the tile's track 193 grey against the live bar's 211. On the right plate every
    /// colour matches to within a unit or two of antialiasing:
    ///
    /// | | tile | live |
    /// |---|---|---|
    /// | track, light | 209,210,209 | 209,209,209 |
    /// | strip, light | 101,202,85 | 99,202,86 |
    /// | track, dark | 69,69,69 | 69,69,69 |
    /// | strip, dark | 108,212,95 | 107,212,95 |
    ///
    /// Not cached, for the same reason ``BarStylePreviewRenderer`` is not: three small canvases cost
    /// microseconds, and a cache would have to be invalidated on every colour-role change from the dev
    /// tuner (`ColorStore.onChange`) *and* on every theme flip — buying two staleness bugs in exchange
    /// for nothing measurable. Rendering on demand means a theme change simply redraws.
    static func image(for style: BarStyle, size: NSSize,
                      appearance: NSAppearance? = nil) -> NSImage {
        let image = NSImage(size: size)
        let views = barViews(for: style)

        image.lockFocusFlipped(true)
        // Baked under the **current** appearance, unlike the menu-bar specimen's fixed `.vibrantDark`.
        // The dropdown is a card that flips with the system, so its preview must flip with it too;
        // ADR-0097 records this as the one place the two surfaces deliberately disagree. Drawing happens
        // inside the block so every semantic colour resolves against the appearance in force, rather
        // than against whatever is current when the image is later composited.
        //
        // `appearance` is a parameter rather than always read from `NSApp` so a caller can bake a
        // specific theme — which is how both themes get rendered in one process for review. Assigning
        // `NSApp.appearance` and re-reading `effectiveAppearance` does *not* work: it does not take
        // effect until the run loop turns, so a loop over both themes silently produced two copies of
        // the same one (measured: both tiles came out with an identical plate).
        (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            // **The two tracks divide the tile into equal thirds.**
            //
            // The unit is the *track* — not the view's frame, and not the marker. `PopupBarView.viewHeight`
            // reserves `tickGap + tickLength` below for a ruler this tile never draws, and the marker
            // straddles the track by `(indicatorHeight − barHeight)/2` on each side; spacing by either
            // leaves the visible pair sitting above centre. Measured on the render, the frame as unit put
            // the lower track 9 pt off the bottom against 12.5 pt of clearance at the top.
            //
            // Each bar's frame is then offset up by that overhang, which is where `render(in:)` places
            // the track relative to the frame it is handed.
            let track = PopupBarView.trackHeight
            let overhang = PopupBarView.markerOverhang
            let spacing = (size.height - track * 2) / 3
            let left = (size.width - barWidth) / 2

            for (index, view) in views.enumerated() {
                let trackTop = spacing * CGFloat(index + 1) + track * CGFloat(index)
                view.render(in: NSRect(x: left, y: trackTop - overhang,
                                       width: barWidth, height: PopupBarView.viewHeight))
            }
        }
        image.unlockFocus()
        // The specimen carries real pacing colour a template mask would strip.
        image.isTemplate = false
        return image
    }
}
