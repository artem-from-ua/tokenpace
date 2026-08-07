import AppKit
import TokenPaceKit

/// Drives the widget's smooth transitions — the colour of the pacing bars and service dots on both
/// surfaces, and the awaiting-input hand's slide in and out of the menu bar.
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
    /// compositing a layer. Across a 0.8 s transition that is ~24 frames.
    ///
    /// That is comfortable for a *colour* fade, which has no moving edge to stitch. Motion does have
    /// one (ADR-0073: the awaiting hand slides ~18 pt), so the figure was re-checked rather than
    /// inherited: ~24 frames over ~18 pt is ~0.75 pt per frame, and smoothstep puts the fastest
    /// phase in the middle where stepping is least legible. Doubling the rate would double the
    /// number of full snapshots for a decoration that comes and goes dozens of times a day — the
    /// opposite of the energy policy ADR-0070 already narrowed once. Raise this if a live check ever
    /// shows banding or stepping; it is one constant.
    private static let framesPerSecond: Double = 30

    /// Every in-flight colour transition, keyed by element identity.
    private var tweens = ColorTweenSet()

    /// Every in-flight scalar transition — today only the awaiting hand's presence (ADR-0073). A
    /// second registry rather than a widened first one: `ColorTweenSet` speaks `RGBA`, and a
    /// presence has no colour.
    private var scalars = ScalarTweenSet()

    /// The urgency the awaiting hand was last drawn with.
    ///
    /// A hand sliding *out* has no urgency to read: the count is already gone from the layout, so
    /// `layout?.awaitingInput?.urgency` reports `.neutral` and a red hand would turn grey halfway
    /// down. The draw site notes the urgency while the count is present and reads this back once it
    /// is not. Bookkeeping that belongs to the animation, like ``frameTime`` — and kept off the view
    /// for the same reason the tweens are (ADR-0070: views have no identity across frames).
    private(set) var lastAwaitingUrgency: AwaitingUrgency = .neutral

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

    /// Whether the system asks UI to avoid animating movement (System Settings → Accessibility →
    /// Display → Reduce motion). Read live rather than cached at launch, so flipping the switch
    /// takes effect on the next frame without a relaunch — the property is cheap, and the widget
    /// resolves it a handful of times per redraw at most.
    ///
    /// Scope is **motion only**: a slide becomes an instant appearance. Colour fades keep running,
    /// because the setting is about movement — Apple's own wording is "UI should avoid large
    /// animations, especially those that simulate the third dimension" — and a cross-fade has
    /// nothing moving in it. Reduce Motion is not a request for a static menu bar; the pacing
    /// colours would still change, just abruptly, which is the very flicker ADR-0070 removed.
    var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The duration a motion tween should use right now: the shipped 0.8 s, or 0 when the system
    /// asks for reduced motion — which makes ``ScalarTween`` record an already-finished transition,
    /// so the glyph simply appears and disappears and no frame timer is ever started.
    private var motionDuration: TimeInterval {
        prefersReducedMotion ? 0 : ScalarTween.defaultDuration
    }

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        self.frameTime = now()
        // Turning Reduce Motion **on** mid-slide must not leave the hand parked halfway: land every
        // in-flight motion at once. (Turning it off needs nothing — the next change simply animates.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.prefersReducedMotion else { return }
                    self.scalars.finishAll()
                    self.onFrame?()
                }
            }
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

    /// The presence factor for `key` this frame — 0 fully hidden, 1 fully in place (ADR-0073).
    ///
    /// **Call this on every frame in which the element's slot exists, including the frames where the
    /// element itself is absent** (`target: 0`). That is the invariant the whole feature rests on,
    /// and it buys two things:
    ///
    /// - an element that disappears from the data still has a live key, so it can animate *out* —
    ///   the draw site is the only thing that knows it was there a frame ago;
    /// - the key keeps being touched, so `pruneStale` never evicts it while its slot is on screen.
    ///   An evicted key would take the "first sight" branch on its return and snap into place — the
    ///   same class of bug as the 5 s → 45 s stale threshold (ADR-0070).
    ///
    /// Once the value has settled the tween is finished, no frames are requested, and the widget is
    /// idle again — so the unconditional call costs nothing when nothing is moving.
    func resolve(_ key: ScalarTweenKey, target: Double) -> Double {
        let value = scalars.update(key, target: target, at: frameTime, duration: motionDuration)
        scheduleFramesIfNeeded()
        return value
    }

    /// Record the urgency the awaiting hand is being drawn with — see ``lastAwaitingUrgency``. Call
    /// only while the count is present; the departing hand reads the stored value back.
    func noteAwaitingUrgency(_ urgency: AwaitingUrgency) {
        lastAwaitingUrgency = urgency
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
        scalars.pruneStale(at: frameTime)
        if !isAnimating { stopTimer() }
    }

    /// Whether either registry still needs frames. The timer is shared, so it lives while *either*
    /// a colour is fading or something is sliding, and dies only when both have settled.
    private var isAnimating: Bool {
        tweens.isAnimating(at: frameTime) || scalars.isAnimating(at: frameTime)
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
        scalars.finishAll()
        stopTimer()
    }

    /// Drop all animation state — a harder reset than ``finishAll()``: the next draw of each element
    /// adopts its colour outright rather than holding the previous one.
    func reset() {
        tweens.removeAll()
        scalars.removeAll()
        // The new world's hand must appear at its own presence, not slide in from the old one's.
        lastAwaitingUrgency = .neutral
        stopTimer()
    }

    // MARK: - Timer

    /// Start the frame timer if a transition is running and it is not already going.
    private func scheduleFramesIfNeeded() {
        guard timer == nil, isAnimating else { return }
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
