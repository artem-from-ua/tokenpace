import AppKit
import TokenPaceKit

/// Drives the smooth colour transitions of the pacing bars and service dots on both surfaces.
///
/// The pacing palette is a set of **step functions**: the moment `usageFraction` crosses a threshold
/// the gap colour jumps green→yellow→orange→red (or green↔blue). When usage sits near a boundary,
/// consecutive polls can land on either side of it and the bar *blinks*. This class turns each such
/// jump into a short eased fade, so a crossing reads as a transition rather than a glitch.
///
/// ## Shape
/// - The maths lives in `TokenPaceKit` (``ColorTweenSet``) — AppKit-free, so it is unit-tested (the
///   only test target depends on the Kit alone). This type is the thin AppKit half: `NSColor` ↔
///   ``RGBA`` conversion, and the run-loop timer.
/// - State is held **here**, not on the views. `PopupViewController.rebuild()` discards and recreates
///   every `PopupBarView` on each update, so a view has no identity across frames; animations are
///   keyed by ``TweenKey`` (what the element *is*) and outlive the teardown.
///
/// ## Redraw discipline
/// The widget's standing rule is that it repaints only when the data changes, never on a timer
/// (`StatusItemView`, architecture.md: energy efficiency). This is the one deliberate exception, and
/// it is scoped as tightly as possible: the timer exists **only while a transition is in flight** and
/// tears itself down on the first frame where nothing is animating. An idle app runs no loop — same
/// as before. See ADR-0070.
@MainActor
final class ColorAnimator {

    /// Frames per second while a transition runs.
    ///
    /// 30, not 60: every menu-bar frame is a full `snapshotImage()` (lock focus → draw the whole
    /// widget → unlock → hand the button a new `NSImage`), which is markedly more expensive than
    /// compositing a layer. Across a 450 ms transition that is ~14 frames — plenty for a *colour*
    /// fade, which has no moving edge whose stepping the eye could catch. Raise this if a live check
    /// ever shows banding.
    private static let framesPerSecond: Double = 30

    /// Every in-flight transition, keyed by element identity.
    private var tweens = ColorTweenSet()

    /// The frame timer — non-nil exactly while something is animating.
    private var timer: Timer?

    /// The instant the current frame renders at. Pinned for the whole frame so every element
    /// sampled during one draw pass agrees on "now" — otherwise bars drawn later in the pass would
    /// interpolate a few microseconds further along than their neighbours.
    private(set) var frameTime = Date()

    /// Invoked when a frame is due. Wired by `AppDelegate` to its re-render entry point, so an
    /// animation frame travels the same path as any other change (menu-bar snapshot + popup rebuild).
    var onFrame: (() -> Void)?

    /// The clock, injectable for testing/stubs. Defaults to the wall clock.
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        self.frameTime = now()
    }

    // MARK: - Drawing entry point

    /// The colour to draw for `key` this frame, given the colour the current *state* calls for.
    ///
    /// Call this at the draw site with the fully-resolved target — i.e. **after** `bright(...)` /
    /// `accent(...)` and after the calm-mode muting decision. Interpolating the final tone (rather
    /// than an earlier stage) means the "coloured → calm neutral" switch fades too, which is one of
    /// the most jarring jumps, and it leaves the ADR-0059 alpha/desaturation rules untouched.
    ///
    /// Passing a target that differs from the last one starts (or redirects) a transition and asks
    /// for frames; passing the same one just samples the curve.
    func resolve(_ key: TweenKey, target: NSColor) -> NSColor {
        // The target must be resolved in the *current* drawing appearance before it can be reduced to
        // numbers — which is why callers invoke this inside the draw, not ahead of it (ADR-0059: the
        // menu-bar image is drawn eagerly inside `performAsCurrentDrawingAppearance`).
        guard let rgba = target.tweenRGBA else { return target }
        let blended = tweens.update(key, target: rgba, at: frameTime)
        scheduleFramesIfNeeded()
        return blended.nsColor
    }

    // MARK: - Frame lifecycle

    /// Open a frame: pin "now", expire elements that have gone off screen, and drop the timer if
    /// everything has settled. Call once before a render pass.
    ///
    /// Pinning the instant matters: every element sampled during one pass must agree on "now", or
    /// bars drawn later would sit a few microseconds further along the curve than their neighbours.
    ///
    /// Stale entries are expired by **age**, not by a per-pass liveness set — the two surfaces draw
    /// in separate passes and the popup also redraws on its own while an `NSMenu` tracks, so a
    /// set-based sweep would let one surface evict the other's keys (see `ColorTweenSet.pruneStale`).
    func beginFrame() {
        frameTime = now()
        tweens.pruneStale(at: frameTime)
        if !tweens.isAnimating(at: frameTime) { stopTimer() }
    }

    // MARK: - Snapping (cases where interpolating would be wrong)

    /// Jump every transition to its destination and stop animating.
    ///
    /// Used where a blend would be meaningless rather than merely unnecessary:
    /// - **appearance flip** — the two endpoints were resolved in *different* themes, so a colour
    ///   between them belongs to neither;
    /// - **dev colour tuner** — the point of the tuner is to show the exact colour immediately;
    /// - **sleep / screen lock** — nothing is on screen to see the fade;
    /// - **data-source switch** (stub change) — the old and new worlds are unrelated.
    func finishAll() {
        tweens.finishAll()
        stopTimer()
    }

    /// Drop all animation state — a harder reset than ``finishAll()``: the next draw of each element
    /// adopts its colour outright rather than holding the previous one.
    func reset() {
        tweens.removeAll()
        stopTimer()
    }

    // MARK: - Timer

    /// Start the frame timer if a transition is running and it is not already going.
    private func scheduleFramesIfNeeded() {
        guard timer == nil, tweens.isAnimating(at: frameTime) else { return }
        // `.common` run-loop mode is mandatory: the popup is an `NSMenuItem.view` inside an `NSMenu`,
        // which runs a modal tracking run loop while open. A timer in `.default` would be starved
        // exactly when the dropdown is visible — the surface where the fade is most obvious.
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFrame?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - NSColor ↔ RGBA

extension NSColor {

    /// This colour's channels for interpolation, or `nil` if it cannot be represented in sRGB
    /// (pattern colours, exotic spaces) — callers then skip animating and draw it as-is.
    ///
    /// Converting through sRGB is what makes a *resolved* colour out of a dynamic semantic one: the
    /// conversion happens in the current drawing appearance, so `.systemGreen` becomes the concrete
    /// green this theme actually shows. That is also why an appearance flip snaps rather than blends
    /// (see ``ColorAnimator/finishAll()``) — the numbers on either side describe different themes.
    var tweenRGBA: RGBA? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return RGBA(red: c.redComponent, green: c.greenComponent,
                    blue: c.blueComponent, alpha: c.alphaComponent)
    }
}

extension RGBA {
    /// The drawable colour for these channels, in sRGB.
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
