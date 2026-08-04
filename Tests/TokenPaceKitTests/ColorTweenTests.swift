import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private let red = RGBA(red: 1, green: 0, blue: 0, alpha: 1)
private let blue = RGBA(red: 0, green: 0, blue: 1, alpha: 1)
private let green = RGBA(red: 0, green: 1, blue: 0, alpha: 1)

/// Channel-wise approximate equality — interpolation is floating-point, so exact `==` is only safe
/// at the endpoints (which the curve pins exactly).
private func approx(_ a: RGBA, _ b: RGBA, tolerance: Double = 1e-9) -> Bool {
    abs(a.red - b.red) < tolerance && abs(a.green - b.green) < tolerance
        && abs(a.blue - b.blue) < tolerance && abs(a.alpha - b.alpha) < tolerance
}

// MARK: - TweenCurve

@Suite("TweenCurve.smoothstep")
struct TweenCurveTests {

    /// The endpoints are exact: a transition must actually reach its target, not stop at 0.999.
    @Test func pinsEndpoints() {
        #expect(TweenCurve.smoothstep(0) == 0)
        #expect(TweenCurve.smoothstep(1) == 1)
    }

    /// Symmetric about the midpoint — the ease-in and ease-out halves mirror each other, so the
    /// transition looks the same played forwards or backwards (green→red and red→green take the
    /// same visual shape).
    @Test func isSymmetricAboutMidpoint() {
        #expect(TweenCurve.smoothstep(0.5) == 0.5)
        for t in stride(from: 0.0, through: 0.5, by: 0.05) {
            let lhs = TweenCurve.smoothstep(t)
            let rhs = 1 - TweenCurve.smoothstep(1 - t)
            #expect(abs(lhs - rhs) < 1e-12)
        }
    }

    /// Monotonically increasing — the colour never backtracks mid-transition.
    @Test func isMonotonic() {
        var previous = -1.0
        for step in 0...100 {
            let value = TweenCurve.smoothstep(Double(step) / 100)
            #expect(value >= previous)
            previous = value
        }
    }

    /// Eased, not linear: the first and last tenths move less than a linear ramp would, which is
    /// exactly what removes the visible "start" and "stop" edges.
    @Test func easesAtBothEnds() {
        #expect(TweenCurve.smoothstep(0.1) < 0.1)
        #expect(TweenCurve.smoothstep(0.9) > 0.9)
    }

    /// Out-of-range input clamps instead of extrapolating into nonsense colours.
    @Test func clampsOutOfRange() {
        #expect(TweenCurve.smoothstep(-5) == 0)
        #expect(TweenCurve.smoothstep(5) == 1)
    }
}

// MARK: - RGBA

@Suite("RGBA.blended")
struct RGBABlendTests {

    /// `t` at the ends returns the endpoints untouched.
    @Test func endpointsAreExact() {
        #expect(red.blended(to: blue, t: 0) == red)
        #expect(red.blended(to: blue, t: 1) == blue)
    }

    /// Every channel blends, alpha included — the calm-mode neutral differs from the pacing hues in
    /// opacity as well as colour (`bright()` pins a fixed alpha), so ignoring alpha would make that
    /// particular transition pop rather than fade.
    @Test func blendsAllFourChannels() {
        let opaque = RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        let mid = opaque.blended(to: clear, t: 0.5)
        #expect(approx(mid, RGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)))
    }
}

// MARK: - ColorTween

@Suite("ColorTween")
struct ColorTweenTests {

    /// Progress is linear in time (the easing is applied separately, in `value(at:)`).
    @Test func progressTracksElapsedTime() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 1)
        #expect(tween.progress(at: t0) == 0)
        #expect(tween.progress(at: t0.addingTimeInterval(0.25)) == 0.25)
        #expect(tween.progress(at: t0.addingTimeInterval(1)) == 1)
    }

    /// Progress clamps rather than running past 1 — a frame that lands late (the run loop was busy,
    /// the machine woke from sleep) must render the target, not an over-extrapolated colour.
    @Test func progressClampsPastTheEnd() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 1)
        #expect(tween.progress(at: t0.addingTimeInterval(99)) == 1)
        #expect(tween.value(at: t0.addingTimeInterval(99)) == blue)
    }

    /// A zero duration is finished on arrival — this is the shape `finishAll()` leaves behind, and
    /// it must not divide by zero.
    @Test func zeroDurationIsImmediatelyFinished() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 0)
        #expect(tween.progress(at: t0) == 1)
        #expect(tween.isFinished(at: t0))
        #expect(tween.value(at: t0) == blue)
    }

    /// The rendered value is eased, so at the halfway *time* the colour is at the halfway *blend*
    /// (smoothstep's midpoint is 0.5) — but at a quarter of the time it is well short of a quarter
    /// of the blend, which is the ease-in.
    @Test func valueIsEased() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 1)
        #expect(approx(tween.value(at: t0.addingTimeInterval(0.5)),
                       RGBA(red: 0.5, green: 0, blue: 0.5, alpha: 1)))
        #expect(tween.value(at: t0.addingTimeInterval(0.25)).blue < 0.25)
    }

    /// `isFinished` flips exactly at the duration boundary.
    @Test func finishesAtDuration() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 0.45)
        #expect(!tween.isFinished(at: t0.addingTimeInterval(0.44)))
        #expect(tween.isFinished(at: t0.addingTimeInterval(0.45)))
    }

    /// Retargeting mid-flight starts from the colour currently on screen — no backwards snap to the
    /// original origin. This is the anti-flicker property: when usage hovers on a threshold and the
    /// state flips repeatedly, each new target bends the ramp from where the eye last saw it.
    @Test func retargetStartsFromCurrentValue() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 1)
        let midpoint = tween.value(at: t0.addingTimeInterval(0.5))

        let retargeted = tween.retargeted(to: green, at: t0.addingTimeInterval(0.5))
        #expect(approx(retargeted.from, midpoint))
        #expect(retargeted.to == green)
        // Continuity: the instant of the switch renders the same colour as the frame before it.
        #expect(approx(retargeted.value(at: t0.addingTimeInterval(0.5)), midpoint))
    }

    /// Retargeting restarts the clock, so the new leg gets a full-length transition rather than
    /// inheriting the remainder of the old one.
    @Test func retargetRestartsTheClock() {
        let tween = ColorTween(from: red, to: blue, startedAt: t0, duration: 1)
        let at = t0.addingTimeInterval(0.5)
        let retargeted = tween.retargeted(to: green, at: at)
        #expect(retargeted.startedAt == at)
        #expect(retargeted.progress(at: at) == 0)
        #expect(retargeted.isFinished(at: at.addingTimeInterval(1)))
    }
}

// MARK: - ColorTweenSet

@Suite("ColorTweenSet")
struct ColorTweenSetTests {

    private let barKey = TweenKey.bar(surface: .menuBar, row: "5h", part: .fill)
    private let otherKey = TweenKey.bar(surface: .menuBar, row: "7d", part: .fill)

    /// The first time a key is seen it adopts its colour outright — a bar that has just appeared
    /// must not fade in from some unrelated previous tone.
    @Test func firstUpdateAdoptsTargetWithoutAnimating() {
        var set = ColorTweenSet()
        let shown = set.update(barKey, target: red, at: t0)
        #expect(shown == red)
        #expect(!set.isAnimating(at: t0))
    }

    /// A changed target animates: the frame at the switch still shows the old colour, and the
    /// colour has arrived by the end of the duration.
    @Test func changedTargetAnimatesToIt() {
        var set = ColorTweenSet()
        set.update(barKey, target: red, at: t0)

        let atSwitch = set.update(barKey, target: blue, at: t0)
        #expect(atSwitch == red)                 // eased start — no instant jump
        #expect(set.isAnimating(at: t0))

        let midway = set.value(barKey, at: t0.addingTimeInterval(0.225))
        #expect(midway != red && midway != blue)  // genuinely in between

        let atEnd = set.value(barKey, at: t0.addingTimeInterval(ColorTween.defaultDuration))
        #expect(atEnd == blue)
        #expect(!set.isAnimating(at: t0.addingTimeInterval(ColorTween.defaultDuration)))
    }

    /// Re-asserting the same target every frame (what the draw path does) must not restart the
    /// transition — otherwise it would never finish, inching forward forever.
    @Test func repeatedSameTargetDoesNotRestart() {
        var set = ColorTweenSet()
        set.update(barKey, target: red, at: t0)
        set.update(barKey, target: blue, at: t0)

        let quarter = t0.addingTimeInterval(0.1125)
        _ = set.update(barKey, target: blue, at: quarter)   // same target, mid-flight
        let atEnd = set.update(barKey, target: blue, at: t0.addingTimeInterval(ColorTween.defaultDuration))
        #expect(atEnd == blue)
    }

    /// Keys are independent: animating one bar leaves the other alone.
    @Test func keysAreIndependent() {
        var set = ColorTweenSet()
        set.update(barKey, target: red, at: t0)
        set.update(otherKey, target: green, at: t0)
        set.update(barKey, target: blue, at: t0)

        #expect(set.value(otherKey, at: t0.addingTimeInterval(0.2)) == green)
    }

    /// The same row on the two surfaces is two separate animations — the popup may be closed while
    /// the menu bar animates.
    @Test func surfacesHaveSeparateKeySpaces() {
        var set = ColorTweenSet()
        let menu = TweenKey.bar(surface: .menuBar, row: "5h", part: .fill)
        let popup = TweenKey.bar(surface: .popup, row: "5h", part: .fill)
        set.update(menu, target: red, at: t0)
        set.update(popup, target: green, at: t0)
        #expect(set.value(menu, at: t0) == red)
        #expect(set.value(popup, at: t0) == green)
    }

    /// `finishAll` snaps to the destination and stops the loop — used on an appearance flip, where
    /// blending endpoints resolved in two different themes would produce a colour belonging to
    /// neither.
    @Test func finishAllSnapsToTarget() {
        var set = ColorTweenSet()
        set.update(barKey, target: red, at: t0)
        set.update(barKey, target: blue, at: t0)
        #expect(set.isAnimating(at: t0))

        set.finishAll()
        #expect(!set.isAnimating(at: t0))
        #expect(set.value(barKey, at: t0) == blue)
    }

    /// Elements still being drawn are kept alive by the touch on every update, while one that has
    /// gone quiet expires — so a returning bar appears at its own colour rather than fading from a
    /// stale one.
    @Test func pruneStaleDropsOnlyUntouchedKeys() {
        var set = ColorTweenSet()
        set.update(barKey, target: red, at: t0)
        set.update(otherKey, target: green, at: t0)

        // 10 s later only `barKey` is still drawn; `otherKey` has been off screen the whole time.
        let later = t0.addingTimeInterval(10)
        set.update(barKey, target: red, at: later)
        set.pruneStale(at: later, staleAfter: 5)

        #expect(set.contains(barKey))
        #expect(!set.contains(otherKey))
    }

    /// A key drawn on every frame is never swept, however long it holds one colour — the touch is
    /// what keeps it, not any animation being in flight.
    @Test func steadyKeySurvivesIndefinitely() {
        var set = ColorTweenSet()
        var when = t0
        for _ in 0..<20 {
            when = when.addingTimeInterval(3)
            set.update(barKey, target: red, at: when)
            set.pruneStale(at: when, staleAfter: 5)
        }
        #expect(set.contains(barKey))
    }

    /// A swept-then-returning key re-adopts its colour instantly (it is "first sight" again).
    @Test func returningKeyDoesNotFadeFromStaleColour() {
        var set = ColorTweenSet()
        set.update(barKey, target: red, at: t0)

        let later = t0.addingTimeInterval(10)
        set.pruneStale(at: later, staleAfter: 5)
        #expect(!set.contains(barKey))

        let shown = set.update(barKey, target: green, at: later)
        #expect(shown == green)
        #expect(!set.isAnimating(at: later))
    }

    /// An empty registry never asks for frames — the timer must not run when nothing is animating.
    @Test func emptySetIsNotAnimating() {
        let set = ColorTweenSet()
        #expect(!set.isAnimating(at: t0))
    }
}
