import Foundation

// MARK: - ScalarTween

/// One in-flight transition of a **plain number** — the motion counterpart of ``ColorTween``.
///
/// Deliberately a sibling type rather than a generalisation of ``ColorTween``. Genericising over a
/// lerpable value would mean rewriting that type's doc comments — which are the in-code record of
/// ADR-0070's colour decision — for the sake of one new call site, and it would make ``TweenKey``
/// ambiguous: its contract is "the identity of one animated *colour*", and a presence factor has no
/// colour. Two small mirrored types read better than one abstract one.
///
/// Like its sibling it is a **value type with no timer of its own**: something else (the AppKit
/// `ColorAnimator`) drives frames and asks for ``value(at:)`` with the current instant, which keeps
/// the time-dependent behaviour testable with explicit `Date`s instead of a real clock.
///
/// The one shipped use is the awaiting-input hand's *presence* — 0 fully hidden below the widget's
/// bottom edge, 1 fully in place (#283, ADR-0073).
public struct ScalarTween: Sendable, Equatable {

    /// The value the transition started from — where it visually *was*, not necessarily a settled
    /// state (see ``retargeted(to:at:duration:)``).
    public let from: Double
    /// The value being transitioned to. Also the value held forever once the tween finishes.
    public let to: Double
    public let startedAt: Date
    public let duration: TimeInterval

    /// When this element was last drawn. Refreshed on every ``ScalarTweenSet/update(_:target:at:duration:)``
    /// and read by ``ScalarTweenSet/pruneStale(at:staleAfter:)``. Bookkeeping, not animation.
    public var touchedAt: Date

    /// Motion borrows the colour transition's length **on purpose**: a single settings toggle can
    /// change a colour and a presence at once (calm mode while the hand is mid-slide), and two
    /// different durations would let one land visibly before the other. One number, one place.
    public static let defaultDuration: TimeInterval = ColorTween.defaultDuration

    public init(from: Double, to: Double, startedAt: Date,
                duration: TimeInterval = ScalarTween.defaultDuration, touchedAt: Date? = nil) {
        self.from = from
        self.to = to
        self.startedAt = startedAt
        self.duration = duration
        self.touchedAt = touchedAt ?? startedAt
    }

    /// Linear time progress in `[0, 1]` — **not** eased. A non-positive `duration` reports `1`
    /// (instantly finished) rather than dividing by zero.
    ///
    /// Carries the same end epsilon as ``ColorTween/progress(at:)``, for the same reason and not as a
    /// copied precaution: a round-trip through `Date` does not preserve a fractional interval
    /// exactly, so sampling at `startedAt + 0.8` yields `0.7999999523162842` and the quotient lands
    /// just under 1. Left unhandled the tween stays forever "almost done" — here that means the hand
    /// resting a fraction of a point below its position with the frame timer never tearing down.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(startedAt)
        let raw = elapsed / duration
        return raw >= 1 - Self.endEpsilon ? 1 : max(0, raw)
    }

    /// Slack allowed when deciding a transition has reached its end — see ``progress(at:)``. Two
    /// orders of magnitude above the ~6·10⁻⁸ error measured there, and far below one frame at any
    /// plausible rate.
    private static let endEpsilon: Double = 1e-6

    /// Whether the transition has run its course at `now` (progress reached 1).
    public func isFinished(at now: Date) -> Bool { progress(at: now) >= 1 }

    /// The value at `now` — ``from`` and ``to`` blended by the **eased** progress. Shares
    /// ``TweenCurve/smoothstep(_:)`` with the colour tween, so motion and colour ease identically.
    public func value(at now: Date) -> Double {
        let t = TweenCurve.smoothstep(progress(at: now))
        return from + (to - from) * t
    }

    /// Aim this tween at a new value, starting from wherever it visually **is right now**.
    ///
    /// This is what makes a reversal read correctly. A hand caught halfway out when a session starts
    /// waiting again must turn around from where it is; restarting from the original `from` would
    /// snap it back below the edge first, and queueing behind the running tween would lag the data.
    public func retargeted(to newTarget: Double, at now: Date,
                           duration: TimeInterval = ScalarTween.defaultDuration) -> ScalarTween {
        ScalarTween(from: value(at: now), to: newTarget, startedAt: now, duration: duration)
    }
}

// MARK: - ScalarTweenKey

/// The stable identity of one animated scalar.
///
/// A **separate** key space from ``TweenKey`` rather than a new case on it: `ColorTweenSet.update`
/// takes and returns ``RGBA``, so a colourless key in that enum would be expressible but meaningless.
///
/// Surface-parameterised for symmetry with ``TweenKey`` even though only ``TweenSurface/menuBar`` is
/// used today — the popup shows the awaiting count as text, not as a sliding glyph.
public enum ScalarTweenKey: Hashable, Sendable {
    /// The awaiting-input hand's presence: 0 hidden below the bottom edge, 1 in place (#283).
    case awaitingIcon(surface: TweenSurface)
}

// MARK: - ScalarTweenSet

/// The registry of every in-flight scalar transition, keyed by ``ScalarTweenKey``.
///
/// Mirrors ``ColorTweenSet`` branch for branch, so the two behave identically where it matters —
/// notably the "first sight adopts instantly" rule, which is what keeps a hand already present at
/// launch from sliding in (ADR-0073).
public struct ScalarTweenSet: Sendable, Equatable {

    /// The live transitions. A key is absent until its element has been resolved at least once.
    private var tweens: [ScalarTweenKey: ScalarTween] = [:]

    public init() {}

    /// Whether anything still needs new frames. ORed with the colour registry's answer to drive the
    /// shared frame timer's lifetime.
    public func isAnimating(at now: Date) -> Bool {
        tweens.values.contains { !$0.isFinished(at: now) }
    }

    /// Whether `key` currently has a transition on record (finished or not).
    public func contains(_ key: ScalarTweenKey) -> Bool { tweens[key] != nil }

    /// Point `key` at `target` and return the value to draw **this frame**.
    ///
    /// Three cases, matching ``ColorTweenSet/update(_:target:at:duration:)``:
    /// - **First sight of this key** — adopt `target` outright, recorded with `duration: 0` so it
    ///   reads as already finished and asks for no frames. For the hand this is the launch case: a
    ///   session already waiting when the app starts is a *current state*, not a change, so the
    ///   glyph is simply there. (With a non-zero duration this "transition to itself" would spin the
    ///   timer up to animate nothing.)
    /// - **Target unchanged** — keep the existing tween running and sample it. The common path:
    ///   every frame re-asserts the same target, and this is also what keeps a settled key alive
    ///   against ``pruneStale(at:staleAfter:)``.
    /// - **Target changed** — retarget from the current interpolated value.
    @discardableResult
    public mutating func update(_ key: ScalarTweenKey, target: Double, at now: Date,
                                duration: TimeInterval = ScalarTween.defaultDuration) -> Double {
        guard let existing = tweens[key] else {
            tweens[key] = ScalarTween(from: target, to: target, startedAt: now, duration: 0)
            return target
        }
        if existing.to == target {
            tweens[key]?.touchedAt = now      // still on screen — keep it out of the stale sweep
            return existing.value(at: now)
        }
        let retargeted = existing.retargeted(to: target, at: now, duration: duration)
        tweens[key] = retargeted
        return retargeted.value(at: now)
    }

    /// The current value for `key` without touching its target, or `nil` if it has none yet.
    public func value(_ key: ScalarTweenKey, at now: Date) -> Double? {
        tweens[key]?.value(at: now)
    }

    /// Snap every transition to its destination — used where interpolating would be wrong rather
    /// than merely unnecessary: sleep, screen lock, an appearance flip (nothing is on screen to see
    /// the slide finish), or the dev colour tuner.
    public mutating func finishAll() {
        for (key, tween) in tweens {
            tweens[key] = ScalarTween(from: tween.to, to: tween.to, startedAt: tween.startedAt,
                                      duration: 0, touchedAt: tween.touchedAt)
        }
    }

    /// Forget entries untouched for longer than `staleAfter`.
    ///
    /// The default matches ``ColorTweenSet/pruneStale(at:staleAfter:)`` and must for the same
    /// reason: it has to exceed the app's slowest redraw cadence (the 30 s age timer), or a
    /// still-present element would be evicted and its next change would hit the "first sight"
    /// branch and snap instead of animating.
    public mutating func pruneStale(at now: Date, staleAfter: TimeInterval = 45) {
        tweens = tweens.filter { now.timeIntervalSince($0.value.touchedAt) <= staleAfter }
    }

    /// Drop everything — used when the data source changes wholesale (a stub switch), where carrying
    /// a presence across would slide the new world's glyph in from the old world's state.
    public mutating func removeAll() { tweens.removeAll() }
}
