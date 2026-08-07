import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// The shipped length of both a colour fade and a slide (0.8 s) — spelled out here rather than read
/// from the type, so a test that pins behaviour *at* the duration cannot silently follow a change to
/// the constant.
private let d = 0.8

// MARK: - ScalarTween

@Suite("ScalarTween")
struct ScalarTweenTests {

    /// Motion borrows the colour transition's length on purpose — a toggle that changes a colour and
    /// a presence at once must land both together. This asserts the "one number, one place" claim
    /// rather than trusting the comment.
    @Test func sharesTheColourTweenDuration() {
        #expect(ScalarTween.defaultDuration == ColorTween.defaultDuration)
        #expect(ScalarTween.defaultDuration == d)
    }

    /// Both endpoints are exact. A hand that stops at 0.998 rests a fraction of a point below where
    /// it belongs, and one that starts at 0.002 has already jumped before the eye sees it move.
    @Test func pinsBothEndpointsExactly() {
        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        #expect(tween.value(at: t0) == 0)
        #expect(tween.value(at: t0.addingTimeInterval(d)) == 1)
    }

    /// The regression ADR-0070 records, reproduced **independently** for the scalar type rather than
    /// assumed to be covered by shared code: `t0.addingTimeInterval(0.8).timeIntervalSince(t0)`
    /// returns 0.7999999523162842, so without the end epsilon the quotient never reaches 1 — the
    /// tween stays forever "almost done" and the frame timer never tears down.
    @Test func reachesExactlyOneAtTheDurationDespiteDateRounding() {
        let sampled = t0.addingTimeInterval(d)
        #expect(sampled.timeIntervalSince(t0) < d)          // the defect itself is still present

        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        #expect(tween.progress(at: sampled) == 1)
        #expect(tween.isFinished(at: sampled))
        #expect(tween.value(at: sampled) == 1)
    }

    /// Smoothstep is symmetric, so the halfway instant sits at the halfway value — the slide covers
    /// as much ground easing out as easing in.
    ///
    /// The tolerance is `1e-6`, not machine epsilon, and that is a property of `Date` rather than
    /// slack: `t0.addingTimeInterval(0.4).timeIntervalSince(t0)` returns 0.3999999761581421 (single-
    /// precision resolution), which lands the midpoint at 0.4999999552965164 — off by ~4.5·10⁻⁸.
    /// The same defect the end epsilon exists for; here it is merely measured, not corrected, since
    /// 10⁻⁸ of a slide is far below a pixel.
    @Test func midpointIsHalfway() {
        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        #expect(abs(tween.value(at: t0.addingTimeInterval(d / 2)) - 0.5) < 1e-6)
    }

    /// Eased, not linear: the first and last tenths move less than a linear ramp would. That is what
    /// removes the visible "start" and "stop" edges from the motion.
    @Test func easesAtBothEnds() {
        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        #expect(tween.value(at: t0.addingTimeInterval(d * 0.1)) < 0.1)
        #expect(tween.value(at: t0.addingTimeInterval(d * 0.9)) > 0.9)
    }

    /// Monotonic across the whole run — the glyph never backtracks mid-slide.
    @Test func neverBacktracks() {
        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        var previous = -1.0
        for step in 0...100 {
            let value = tween.value(at: t0.addingTimeInterval(d * Double(step) / 100))
            #expect(value >= previous)
            previous = value
        }
    }

    /// Sampling outside the window clamps instead of extrapolating the glyph off-screen.
    @Test func clampsOutsideItsWindow() {
        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        #expect(tween.value(at: t0.addingTimeInterval(-10)) == 0)
        #expect(tween.value(at: t0.addingTimeInterval(60)) == 1)
    }

    /// A non-positive duration reports finished rather than dividing by zero — the shape the
    /// "first sight of this key" branch relies on to record a settled value.
    @Test func zeroDurationIsInstantlyFinished() {
        let tween = ScalarTween(from: 1, to: 1, startedAt: t0, duration: 0)
        #expect(tween.progress(at: t0) == 1)
        #expect(tween.isFinished(at: t0))
        #expect(tween.value(at: t0) == 1)
    }

    /// `isFinished` flips exactly at the duration, not before it.
    @Test func isFinishedOnlyAtTheEnd() {
        let tween = ScalarTween(from: 0, to: 1, startedAt: t0, duration: d)
        #expect(!tween.isFinished(at: t0))
        #expect(!tween.isFinished(at: t0.addingTimeInterval(d - 0.01)))
        #expect(tween.isFinished(at: t0.addingTimeInterval(d)))
    }

    /// **The key motion test.** A hand caught halfway out when a session starts waiting again must
    /// turn around from where it is. Restarting from the original `from` would snap it below the
    /// edge first — the visual glitch the whole retarget branch exists to prevent.
    @Test func reversalStartsFromWhereItVisuallyIs() {
        let outgoing = ScalarTween(from: 1, to: 0, startedAt: t0, duration: d)
        let mid = t0.addingTimeInterval(d / 2)
        let atReversal = outgoing.value(at: mid)
        #expect(abs(atReversal - 0.5) < 1e-6)   // `Date` resolution, see `midpointIsHalfway`

        let reversed = outgoing.retargeted(to: 1, at: mid, duration: d)
        #expect(reversed.value(at: mid) == atReversal)      // no snap at the moment of reversal
        #expect(reversed.value(at: mid.addingTimeInterval(d)) == 1)
    }

    /// A reversal must not overshoot: an interrupted slide stays inside `[0, 1]` throughout, so the
    /// glyph never rides above its resting position or dips further than fully hidden.
    @Test func reversalStaysInRange() {
        let outgoing = ScalarTween(from: 1, to: 0, startedAt: t0, duration: d)
        let reversed = outgoing.retargeted(to: 1, at: t0.addingTimeInterval(d * 0.4), duration: d)
        for step in 0...100 {
            let value = reversed.value(at: t0.addingTimeInterval(d * 0.4 + d * Double(step) / 100))
            #expect(value >= 0 && value <= 1)
        }
    }
}

// MARK: - ScalarTweenSet

@Suite("ScalarTweenSet")
struct ScalarTweenSetTests {

    private let key = ScalarTweenKey.awaitingIcon(surface: .menuBar)

    /// First sight of a key adopts its target outright and asks for no frames. This is the launch
    /// case: a session already waiting when the app starts is a *current state*, not a change, so
    /// the hand is simply there — no slide-in (ADR-0073).
    @Test func firstSightAdoptsInstantly() {
        var set = ScalarTweenSet()
        #expect(set.update(key, target: 1, at: t0) == 1)
        #expect(!set.isAnimating(at: t0))
    }

    /// The same holds for an absent hand: launching with nothing waiting settles at 0 without
    /// animating a slide-out of something that was never on screen.
    @Test func firstSightAdoptsInstantlyForZeroToo() {
        var set = ScalarTweenSet()
        #expect(set.update(key, target: 0, at: t0) == 0)
        #expect(!set.isAnimating(at: t0))
    }

    /// Once the key exists, a changed target animates — the 0 → 1 transition that happens when a
    /// session starts waiting during ordinary work.
    @Test func changedTargetAnimates() {
        var set = ScalarTweenSet()
        set.update(key, target: 0, at: t0)
        let started = set.update(key, target: 1, at: t0)
        #expect(started == 0)                                // begins where it was
        #expect(set.isAnimating(at: t0))
        #expect(set.value(key, at: t0.addingTimeInterval(d)) == 1)
        #expect(!set.isAnimating(at: t0.addingTimeInterval(d)))
    }

    /// Re-asserting the same target every frame samples the running curve forward instead of
    /// restarting it — otherwise the slide would never finish, resetting on each redraw.
    @Test func unchangedTargetDoesNotRestart() {
        var set = ScalarTweenSet()
        set.update(key, target: 0, at: t0)
        set.update(key, target: 1, at: t0)

        let quarter = set.update(key, target: 1, at: t0.addingTimeInterval(d * 0.25))
        let half = set.update(key, target: 1, at: t0.addingTimeInterval(d * 0.5))
        #expect(half > quarter)
        #expect(set.value(key, at: t0.addingTimeInterval(d)) == 1)
    }

    /// A settled key stays alive as long as it is re-asserted, and expires once it is not. The
    /// threshold has to clear the app's 30 s age timer, so 44 s survives and 46 s does not — the
    /// same defect that made the first calm-mode toggle after a pause snap (ADR-0070).
    @Test func staleSweepKeepsTouchedKeysAndDropsQuietOnes() {
        var set = ScalarTweenSet()
        set.update(key, target: 1, at: t0)

        var kept = set
        kept.update(key, target: 1, at: t0.addingTimeInterval(44))   // re-touched
        kept.pruneStale(at: t0.addingTimeInterval(44))
        #expect(kept.contains(key))

        var dropped = set
        dropped.pruneStale(at: t0.addingTimeInterval(46))
        #expect(!dropped.contains(key))
    }

    /// `finishAll` lands every in-flight slide and stops asking for frames — sleep, screen lock and
    /// an appearance flip, where nothing is on screen to watch it arrive.
    @Test func finishAllLandsEverything() {
        var set = ScalarTweenSet()
        set.update(key, target: 0, at: t0)
        set.update(key, target: 1, at: t0)
        #expect(set.isAnimating(at: t0))

        set.finishAll()
        #expect(!set.isAnimating(at: t0))
        #expect(set.value(key, at: t0) == 1)
    }

    /// `removeAll` is the harder reset (a stub switch): the next update re-enters the first-sight
    /// branch, so the new world's hand appears at its own presence instead of sliding in from the
    /// old world's.
    @Test func removeAllReturnsToFirstSightBehaviour() {
        var set = ScalarTweenSet()
        set.update(key, target: 1, at: t0)
        set.removeAll()
        #expect(!set.contains(key))

        #expect(set.update(key, target: 0, at: t0) == 0)
        #expect(!set.isAnimating(at: t0))
    }

    /// A zero duration makes a *changed* target land instantly and ask for no frames — the shape
    /// Reduce Motion relies on (System Settings → Accessibility → Display). The glyph still appears
    /// and disappears; it simply stops travelling to get there, and no frame timer is ever started.
    @Test func zeroDurationSwitchesWithoutAnimating() {
        var set = ScalarTweenSet()
        set.update(key, target: 0, at: t0)
        #expect(set.update(key, target: 1, at: t0, duration: 0) == 1)
        #expect(!set.isAnimating(at: t0))
    }

    /// An empty registry animates nothing — an idle app runs no frame loop at all.
    @Test func emptySetIsNotAnimating() {
        let set = ScalarTweenSet()
        #expect(!set.isAnimating(at: t0))
        #expect(set.value(key, at: t0) == nil)
    }

    /// The two surfaces are separate key spaces, as with colours: one can animate while the other
    /// sits settled.
    @Test func surfacesAreIndependentKeys() {
        var set = ScalarTweenSet()
        let popup = ScalarTweenKey.awaitingIcon(surface: .popup)
        set.update(key, target: 0, at: t0)
        set.update(key, target: 1, at: t0)

        #expect(!set.contains(popup))
        #expect(set.update(popup, target: 1, at: t0) == 1)   // first sight for the other surface
        #expect(set.value(key, at: t0) == 0)                 // the menu bar's own tween is untouched
    }
}
