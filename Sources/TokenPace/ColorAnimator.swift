import AppKit
import TokenPaceKit

/// Drives the widget's smooth transitions — the colour of the pacing bars and service dots on both
/// surfaces, and the awaiting-input hand's slide in and out of the menu bar.
///
/// The pacing palette is a set of **step functions**: the moment `usageFraction` crosses a threshold
/// the gap colour jumps green→yellow→orange→red (or green↔blue). When usage sits near a boundary,
/// consecutive polls can land on either side of it and the bar *blinks*. This class turns each such
/// jump into a short eased fade.
///
/// The maths lives in `TokenPaceKit` (``ColorTweenSet``, ``AppearanceScopedTweens``), AppKit-free and
/// unit-tested; this type is the thin AppKit half (`NSColor` ↔ ``RGBA`` conversion, the run-loop
/// timer). State is held **here**, not on the views — `PopupViewController.rebuild()` discards and
/// recreates every `PopupBarView` on each update, so a view has no identity across frames;
/// animations are keyed by ``TweenKey``.
///
/// The widget's standing rule is that it repaints only when the data changes, never on a timer
/// (energy efficiency). This is the one deliberate exception, scoped tightly: the timer exists
/// **only while a transition is in flight** and tears itself down on the first frame where nothing
/// is animating (ADR-0070). A watchdog enforces that: a timer still running long after any real
/// transition would have ended is stopped, and transitions pause (ADR-0135).
@MainActor
final class ColorAnimator {

    /// 30, not 60: every menu-bar frame is a full `snapshotImage()`, markedly more expensive than
    /// compositing a layer. Comfortable for a *colour* fade (no moving edge to stitch); motion does
    /// have one (ADR-0073, ~18 pt slide), and ~24 frames over that distance keeps stepping
    /// imperceptible with smoothstep easing. Raise this if a live check ever shows banding.
    private static let framesPerSecond: Double = 30

    /// The longest a transition runs is 0.8 s, and a retarget restarts it, so only data flipping
    /// several times a second could keep a healthy timer alive this long — polls are a minute apart.
    private static let watchdogLimit: TimeInterval = 5

    /// The first pause after a trip, doubled on each further trip up to ``maxPause``. A cause that
    /// keeps recurring then costs one 5 s burst per hour and one log line per hour.
    private static let basePause: TimeInterval = 60
    private static let maxPause: TimeInterval = 3600

    /// How long after a pause ends without a new trip the doubling starts over. Measured from the
    /// pause's end, not the trip, so a 1 h pause cannot reset its own count.
    private static let tripMemory: TimeInterval = 3600

    /// Every in-flight colour transition, one set per drawing appearance.
    private var tweens = AppearanceScopedTweens()

    /// Every in-flight scalar transition — today only the awaiting hand's presence (ADR-0073). A
    /// separate registry: `ColorTweenSet` speaks `RGBA`, and a presence has no colour. Not scoped by
    /// appearance — a presence is the same number in every appearance.
    private var scalars = ScalarTweenSet()

    /// A hand sliding *out* has no urgency to read: the count is already gone from the layout, so
    /// the draw site notes the urgency while the count is present and reads this back once it isn't.
    private(set) var lastAwaitingUrgency: AwaitingUrgency = .neutral

    /// Non-nil exactly while something is animating.
    private var timer: Timer?
    private var timerStartedAt: Date?

    /// While set and in the future, every `resolve` returns its target and no timer starts.
    private var pausedUntil: Date?
    private var consecutiveTrips = 0
    private var appearanceChangesThisEpisode = 0

    /// Pinned for the whole frame so every element sampled during one draw pass agrees on "now" —
    /// otherwise bars drawn later would interpolate a few microseconds further along than neighbours.
    private(set) var frameTime = Date()

    /// Wired by `AppDelegate` to its re-render entry point, so an animation frame travels the same
    /// path as any other change.
    var onFrame: (() -> Void)?

    /// Called once per watchdog trip, after the timer is stopped; `AppDelegate` logs it.
    var onWatchdogTrip: ((WatchdogTrip) -> Void)?

    /// The clock, injectable for testing/stubs. Defaults to the wall clock.
    private let now: () -> Date

    /// Read live rather than cached at launch, so flipping the switch takes effect on the next frame.
    /// Scope is **motion only** — color fades keep running since Reduce Motion is about movement, not
    /// a request for a static menu bar.
    var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The shipped 0.8 s, or 0 under reduced motion — which makes ``ScalarTween`` record an
    /// already-finished transition, so the glyph simply appears/disappears with no frame timer.
    private var motionDuration: TimeInterval {
        prefersReducedMotion ? 0 : ScalarTween.defaultDuration
    }

    private var isPaused: Bool {
        guard let pausedUntil else { return false }
        return now() < pausedUntil
    }

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        self.frameTime = now()
        // Turning Reduce Motion **on** mid-slide must not leave the hand parked halfway.
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

    /// Call this at the draw site with the fully-resolved target — i.e. **after** `bright(...)` /
    /// `accent(...)` and the calm-mode muting decision, so the "coloured → calm neutral" switch fades
    /// too. Passing a target that differs from the last one starts (or redirects) a transition;
    /// passing the same one just samples the curve.
    ///
    /// The tween is looked up in the set of the **current drawing appearance**, so it must be called
    /// inside the draw: a status-item snapshot for another display's menu bar runs under that bar's
    /// appearance and must not retarget this display's tweens.
    func resolve(_ key: TweenKey, target: NSColor) -> NSColor {
        guard !isPaused else { return target }
        // The target must be resolved in the *current* drawing appearance before it can be reduced to
        // numbers — callers invoke this inside the draw, not ahead of it (ADR-0059).
        guard let rgba = target.tweenRGBA else { return target }
        let appearance = NSAppearance.currentDrawing().name.rawValue
        let blended = tweens.update(key, appearance: appearance, target: rgba, at: frameTime)
        scheduleFramesIfNeeded()
        return blended.nsColor
    }

    /// The presence factor for `key` this frame — 0 fully hidden, 1 fully in place (ADR-0073).
    ///
    /// **Call this on every frame in which the element's slot exists, including frames where the
    /// element itself is absent** (`target: 0`) — an element that disappears from the data still
    /// needs a live key to animate *out*, and an evicted key would snap into place on its return
    /// instead (the same class of bug as the 5 s → 45 s stale threshold, ADR-0070).
    func resolve(_ key: ScalarTweenKey, target: Double) -> Double {
        guard !isPaused else { return target }
        let value = scalars.update(key, target: target, at: frameTime, duration: motionDuration)
        scheduleFramesIfNeeded()
        return value
    }

    /// Call only while the count is present; the departing hand reads the stored value back.
    func noteAwaitingUrgency(_ urgency: AwaitingUrgency) {
        lastAwaitingUrgency = urgency
    }

    /// Counted into the next watchdog report, so a trip says whether appearance flips drove it.
    func noteAppearanceChange() {
        appearanceChangesThisEpisode += 1
    }

    // MARK: - Frame lifecycle

    /// Pin "now", expire elements that have gone off screen, and drop the timer if everything has
    /// settled. Call once before a render pass. Stale entries are expired by **age**, not a per-pass
    /// liveness set — the two surfaces draw in separate passes, so a set-based sweep would let one
    /// evict the other's keys.
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

    /// Used where a blend would be meaningless: dev colour tuner (wants the exact colour
    /// immediately), sleep/screen lock (nothing on screen to see the fade), data-source switch (old
    /// and new worlds unrelated).
    func finishAll() {
        tweens.finishAll()
        scalars.finishAll()
        stopTimer()
    }

    /// A real appearance change (system theme, or the main menu bar's own). Each element adopts its
    /// colour on its next draw: a kept set would otherwise fade from a colour recorded before the
    /// flip if the theme flips back within the 45 s stale window. Presence is left alone.
    func dropColorScopes() {
        tweens.removeAll()
    }

    /// A harder reset than ``finishAll()``: the next draw of each element adopts its colour outright.
    func reset() {
        tweens.removeAll()
        scalars.removeAll()
        // The new world's hand must appear at its own presence, not slide in from the old one's.
        lastAwaitingUrgency = .neutral
        stopTimer()
    }

    // MARK: - Timer

    private func scheduleFramesIfNeeded() {
        guard timer == nil, isAnimating else { return }
        // `.common` run-loop mode is mandatory: the popup is an `NSMenuItem.view` inside an `NSMenu`,
        // which runs a modal tracking run loop while open. A timer in `.default` would be starved
        // exactly when the dropdown is visible.
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.tripWatchdogIfRunaway() else { return }
                self.onFrame?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerStartedAt = now()
        tweens.resetDiagnostics()
        appearanceChangesThisEpisode = 0
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerStartedAt = nil
    }

    /// Checked on the timer's own tick: the render path returns early before the first poll, so a
    /// check there would never run in that state.
    private func tripWatchdogIfRunaway() -> Bool {
        guard let timerStartedAt else { return false }
        let t = now()
        let ranFor = t.timeIntervalSince(timerStartedAt)
        guard ranFor > Self.watchdogLimit else { return false }

        if let previousEnd = pausedUntil, t.timeIntervalSince(previousEnd) > Self.tripMemory {
            consecutiveTrips = 0
        }
        consecutiveTrips += 1
        let pause = min(Self.basePause * pow(2, Double(consecutiveTrips - 1)), Self.maxPause)
        pausedUntil = t.addingTimeInterval(pause)

        let trip = WatchdogTrip(
            number: consecutiveTrips, ranFor: ranFor, retargets: tweens.retargetCount,
            lastRetargetedKey: tweens.lastRetargetedKey.map { String(describing: $0) } ?? "none",
            appearances: tweens.appearances, appearanceChanges: appearanceChangesThisEpisode,
            pause: pause)
        tweens.finishAll()
        scalars.finishAll()
        stopTimer()
        onWatchdogTrip?(trip)
        return true
    }

    /// What one watchdog trip saw — enough to tell which element kept retargeting and whether
    /// appearance flips were behind it.
    struct WatchdogTrip {
        let number: Int
        let ranFor: TimeInterval
        let retargets: Int
        let lastRetargetedKey: String
        let appearances: [String]
        let appearanceChanges: Int
        let pause: TimeInterval
    }
}

// MARK: - NSColor ↔ RGBA

extension NSColor {

    /// `nil` if it cannot be represented in sRGB (pattern colours, exotic spaces) — callers then skip
    /// animating. Converting through sRGB resolves a dynamic semantic colour in the current drawing
    /// appearance (`.systemGreen` becomes the concrete green this theme shows), which is why the
    /// animator keeps one set of tweens per appearance.
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
