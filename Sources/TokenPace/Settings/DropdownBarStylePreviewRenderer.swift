import AppKit
import TokenPaceKit

// MARK: - DropdownBarStylePreviewRenderer

/// Draws the specimen each ``BarStyle`` tile shows in the **dropdown**'s Style row — with the real
/// `PopupBarView`, at runtime, exactly as ``BarStylePreviewRenderer`` does for the menu bar (#374).
///
/// Deliberately separate from that renderer, not parameterised by surface — ADR-0097 records these
/// differences as intentional:
///
/// - **Appearance.** The menu-bar specimen bakes under `.vibrantDark` *always* (the menu bar is dark
///   under a light theme too). This surface bakes under whatever appearance is current, since the
///   dropdown is a Control-Center-style card that flips with the system.
/// - **Geometry.** `StatusItemView` has a fixed 34 pt width; `PopupBarView` stretches to the popup
///   card and has no intrinsic width, so the tile has to *choose* one — see ``barWidth``.
/// - **The ruler.** The popup bar's under-bar ruler (gated on held ⌥) has no menu-bar equivalent and
///   is left off here.
@MainActor
enum DropdownBarStylePreviewRenderer {

    /// Drawn **at this width directly**, 1:1 in both axes — track, marker and zero tick keep their
    /// exact sizes, per ADR-0093 §3. Shortening the bar shifts marks by at most **~2%** of the bar's
    /// width (`scaleX`'s inset costs 5.6% of a 56 pt bar vs. 1.1% of the live 320 pt one) — visible
    /// only if measured, shapes and their order stay identical.
    static let barWidth: CGFloat = 56

    /// The **same** `climbing` first-poll values the menu-bar tiles bake
    /// (`BarStylePreviewRenderer.Specimen`), so any difference on screen is a rendering difference,
    /// not a difference in the underlying numbers.
    private enum Specimen {
        /// 5-hour window: a fifth spent with 2 of its 5 hours left — behind pace, so this bar is calm.
        static let fiveHourUtilization = 20.0
        static let fiveHourRemaining: TimeInterval = 2 * 3600
        /// 7-day window: over half spent with 5 of its 7 days left — ahead of pace, so this one is not.
        static let sevenDayUtilization = 55.0
        static let sevenDayRemaining: TimeInterval = 5 * 24 * 3600
    }

    // MARK: Layout

    /// 5-hour window above, 7-day below — the order the live dropdown stacks them in. Both go through
    /// `PacingModel.barLayout` rather than hand-written `BarLayout` literals, since the pacing state
    /// and blue gate are *computed* from the numbers.
    private static func barViews(for style: BarStyle) -> [PopupBarView] {
        // Any fixed instant works — only the differences below are read.
        let now = Date(timeIntervalSinceReferenceDate: 0)

        let fiveHour = PopupBarView(frame: .zero)
        // `blueAllowed: false` is what the app computes for this frame: `weeklyHasHeadroom` shuts the
        // gate whenever the weekly window is ahead of pace (55% spent vs 28.6% elapsed here). Passing
        // it explicitly also avoids the 5-hour surplus (0.40) sitting exactly on `behindThreshold`
        // (3600/18000 = 0.40), where a strict `>` is decided by floating-point noise.
        fiveHour.bar = PacingModel.barLayout(
            utilization: Specimen.fiveHourUtilization,
            resetsAt: now.addingTimeInterval(Specimen.fiveHourRemaining),
            now: now, window: .fiveHour, blueAllowed: false)
        fiveHour.subdivisions = 5
        fiveHour.barStyle = style

        let sevenDay = PopupBarView(frame: .zero)
        sevenDay.bar = PacingModel.barLayout(
            utilization: Specimen.sevenDayUtilization,
            resetsAt: now.addingTimeInterval(Specimen.sevenDayRemaining),
            now: now, window: .sevenDay)
        sevenDay.subdivisions = 7
        sevenDay.barStyle = style

        // `optionHeld` stays at its `false` default: ⌥ must not reach a specimen — a tile baked with
        // the ruler's teeth on advertises a state the row is not in, and the caption dominates a tile
        // this size. `drawZeroTick` still draws the Pressure/Balance-distinguishing zero unconditionally.
        //
        // No `colorAnimator` either — a specimen has no previous value to ease away from.
        return [fiveHour, sevenDay]
    }

    // MARK: Image

    /// **`appearance` must be a vibrant one**: the live bars draw inside an `NSMenu`, a vibrant
    /// surface where this palette resolves differently — measured on the track and the pacing green:
    ///
    /// | appearance | track | green |
    /// |---|---|---|
    /// | aqua | 0,0,0 α0.18 | 40,205,65 |
    /// | vibrantLight | 211,211,211 α1.0 | 30,195,55 |
    /// | darkAqua | 255,255,255 α0.17 | 50,215,75 |
    /// | vibrantDark | 51,51,51 α1.0 | 60,225,85 |
    ///
    /// The hues differ outright, and under vibrant the track resolves **opaque**, independent of
    /// whatever plate sits behind it. The image is transparent apart from the bars, so the tile is
    /// backed by the popup **card**'s fill (`NSColor.cardPlateFillOpaque`, 255/30) rather than the
    /// menu plate the card floats on (236/33).
    ///
    /// Not cached: three small canvases cost microseconds, and a cache would need invalidating on
    /// every theme flip for nothing measurable.
    static func image(for style: BarStyle, size: NSSize,
                      appearance: NSAppearance? = nil) -> NSImage {
        let image = NSImage(size: size)
        let views = barViews(for: style)

        image.lockFocusFlipped(true)
        // Through `PopupBarView.withBarAppearance` — the same seam the live `draw(_:)` goes through, so
        // the tile resolves its neutrals in the appearance the dropdown actually draws in. Baking the
        // theme here directly is what let the two drift: the specimen picked the vibrant family while
        // the NSMenu-hosted bar on macOS 27 got the flat one, and the marker ring came out inverted in
        // the dropdown while the tile beside it looked right.
        //
        // Only the light/dark side of `appearance` is used; the seam pins the family. It stays a
        // parameter rather than always reading `NSApp` so a caller can bake a specific theme in one
        // process — assigning `NSApp.appearance` does *not* work, it waits for the run loop to turn.
        PopupBarView.withBarAppearance(matching: appearance ?? NSApp.effectiveAppearance) {
            // **The two tracks divide the tile into equal thirds.** The unit is the *track*, not the
            // view's frame or the marker: `PopupBarView.viewHeight` reserves space below for a ruler
            // this tile never draws, and the marker straddles the track unevenly — spacing by either
            // would leave the pair sitting above centre. Each bar's frame is offset up by the overhang.
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
