import Foundation

// MARK: - RGBA

/// An AppKit-free colour value — four resolved channels in `[0, 1]`.
///
/// The render layer converts an `NSColor` into this (via `usingColorSpace(.sRGB)`) *after* it has
/// been resolved against the drawing appearance, hands it here to be interpolated, and converts the
/// result back. Keeping the interpolation in terms of plain numbers is what lets the whole tween
/// engine live in `TokenPaceKit`, which never imports AppKit — and therefore be unit-tested (the
/// only test target depends on the Kit alone; see `Package.swift`).
///
/// Interpolation is a straight per-channel lerp in whatever space the caller resolved into (sRGB in
/// practice). A perceptual space (LAB/LCH) would give a marginally more even ramp, but the pacing
/// hues are adjacent, saturated system colours and the transition is short — the extra conversion
/// cost and the risk of out-of-gamut intermediates buy nothing visible here.
public struct RGBA: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Per-channel linear blend: `self` at `t == 0`, `other` at `t == 1`. `t` is used as given —
    /// callers pass the **eased** progress, so the easing lives in one place (``TweenCurve``).
    public func blended(to other: RGBA, t: Double) -> RGBA {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return RGBA(red: mix(red, other.red), green: mix(green, other.green),
                    blue: mix(blue, other.blue), alpha: mix(alpha, other.alpha))
    }
}

// MARK: - TweenCurve

/// The easing applied to a tween's linear time progress.
public enum TweenCurve {

    /// Smoothstep — `3t² − 2t³`, clamped to `[0, 1]`.
    ///
    /// Zero derivative at both ends, so a transition neither starts nor stops abruptly: the colour
    /// eases out of the old tone and settles into the new one, with the fastest change in the
    /// middle. That "no visible start, no visible stop" property is the whole point — a linear ramp
    /// of the same duration still reads as two hard edges with a slide between them.
    public static func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }
}

// MARK: - ColorTween

/// One in-flight colour transition: where it started, where it is going, and when it began.
///
/// Deliberately a **value type with no timer of its own** — it does not know about run loops or
/// redraws. Something else (the AppKit `ColorAnimator`) drives frames and asks for ``value(at:)``
/// with the current instant. That keeps the time-dependent behaviour fully testable: a test passes
/// explicit `Date`s instead of waiting on a real clock.
public struct ColorTween: Sendable, Equatable {

    /// The colour the transition started from — the *rendered* colour at the moment it began, not
    /// necessarily a settled state (see ``retargeted(to:at:)``).
    public let from: RGBA
    /// The colour being transitioned to. Also the value held forever once the tween finishes.
    public let to: RGBA
    public let startedAt: Date
    public let duration: TimeInterval

    /// When this element was last drawn. Refreshed on every ``ColorTweenSet/update(_:target:at:)``,
    /// and read by ``ColorTweenSet/pruneStale(at:staleAfter:)`` to expire elements that have gone
    /// off screen. Not part of the animation itself — purely bookkeeping.
    public var touchedAt: Date

    /// The shipped transition length: long enough to read as a deliberate fade rather than a
    /// glitch, short enough that a colour change still feels immediate. Not user-configurable —
    /// there is no Settings option for it by design.
    ///
    /// At shorter lengths the adjacent pacing hues (green→yellow especially) are close enough that
    /// the fade is over before the eye registers it had started — reading as the very snap this
    /// exists to remove. The bar is ambient, glanced at rather than watched, so it can afford a
    /// transition long enough to be unmistakably *a transition*; there is no interaction waiting on
    /// it to finish. Longer lengths feel languid on the high-contrast blue→`calmWhite` mute.
    public static let defaultDuration: TimeInterval = 0.8

    public init(from: RGBA, to: RGBA, startedAt: Date,
                duration: TimeInterval = ColorTween.defaultDuration, touchedAt: Date? = nil) {
        self.from = from
        self.to = to
        self.startedAt = startedAt
        self.duration = duration
        self.touchedAt = touchedAt ?? startedAt
    }

    /// Linear time progress in `[0, 1]` — **not** eased. A non-positive `duration` reports `1`
    /// (instantly finished) rather than dividing by zero.
    ///
    /// Sampling exactly at `startedAt + duration` must report a clean `1`, and plain division does
    /// not guarantee that: a round-trip through `Date` does not preserve a fractional interval
    /// exactly. Measured, `t0.addingTimeInterval(0.8).timeIntervalSince(t0)` returns
    /// `0.7999999523162842` — short by ~6·10⁻⁸ (2⁻²⁴, i.e. single-precision resolution), so the
    /// quotient lands just under 1. A duration of exactly 1.0 happened to hide this; 0.8 does not.
    /// Left unhandled the tween stays forever "almost done": the colour sits a hair off its target
    /// and the frame timer never tears down. Snapping anything within `endEpsilon` of the end to 1
    /// fixes it for any duration and is imperceptible — 10⁻⁶ of a second-long fade.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(startedAt)
        let raw = elapsed / duration
        return raw >= 1 - Self.endEpsilon ? 1 : max(0, raw)
    }

    /// Slack allowed when deciding a transition has reached its end — see ``progress(at:)``. Two
    /// orders of magnitude above the ~6·10⁻⁸ error measured there, and still far below one frame at
    /// any plausible rate, so it can never shorten a fade perceptibly.
    private static let endEpsilon: Double = 1e-6

    /// Whether the transition has run its course at `now` (progress reached 1).
    public func isFinished(at now: Date) -> Bool { progress(at: now) >= 1 }

    /// The rendered colour at `now` — ``from`` and ``to`` blended by the **eased** progress.
    public func value(at now: Date) -> RGBA {
        from.blended(to: to, t: TweenCurve.smoothstep(progress(at: now)))
    }

    /// Aim this tween at a new colour, starting from wherever it visually **is right now**.
    ///
    /// This is what keeps rapid changes smooth. Restarting from the original `from` would snap the
    /// colour backwards to the old tone before setting off again; keeping the old tween and
    /// queueing would lag behind the data. Taking the current interpolated value as the new origin
    /// means the colour simply bends toward the new target from wherever the eye last saw it — the
    /// case that matters when usage hovers on a threshold and the state flips twice in a second.
    public func retargeted(to newTarget: RGBA, at now: Date,
                           duration: TimeInterval = ColorTween.defaultDuration) -> ColorTween {
        ColorTween(from: value(at: now), to: newTarget, startedAt: now, duration: duration)
    }
}

// MARK: - TweenKey

/// Which surface an animated element lives on. The two carry **separate** key spaces: the popup can
/// be closed while the menu bar animates (and vice versa), so a 5-hour bar in one is not the same
/// animation as the 5-hour bar in the other.
public enum TweenSurface: Hashable, Sendable {
    case menuBar
    case popup
}

/// Which coloured part of a bar is being animated. The fill and the time marker share a colour in
/// practice, but they are resolved at different points in the draw and can briefly disagree, so
/// each gets its own tween rather than one racing the other.
public enum BarPart: Hashable, Sendable {
    case fill
    case marker
}

/// The stable identity of one animated colour, surviving the view teardown that happens on every
/// popup rebuild (`PopupViewController.rebuild()` discards and recreates every `PopupBarView`).
/// Animation state is therefore keyed by *what the element is*, never held on the view itself.
///
/// **Rows are keyed by name, not by index.** The popup's per-model rows come and go (the
/// "Show model-specific limits" toggle, a changing set of scoped models in the response), which
/// shifts every index below them. Keyed by position, a disappearing row would hand its in-flight
/// animation to its neighbour — Opus would visibly inherit Sonnet's colour slide. The row title is
/// stable and unique within a surface, so it survives the shuffle.
public enum TweenKey: Hashable, Sendable {
    /// A limit-window bar: the popup passes `LimitRow.title`, the menu bar its `LimitWindow`'s id.
    ///
    /// **`provider` is what keeps two providers' identically-named rows apart.** Claude's week and
    /// Codex's week are both titled `"7-day"`, and both plates are on the popup at once — keyed by
    /// title alone they are one animation, so one provider's colour slide plays out on the other's
    /// bar. Defaulted to `.claude` so the menu bar and the credits-adjacent callers, which have only
    /// ever drawn one provider, read unchanged.
    case bar(surface: TweenSurface, row: String, part: BarPart, provider: ProviderID = .claude)
    /// The "Extra usage" money-credits bar, which has no `LimitRow` and so no title to key on.
    case credits(surface: TweenSurface, part: BarPart)
    /// The service-status dot (menu-bar widget) or one status row's dot (popup, keyed by component).
    case serviceDot(surface: TweenSurface, component: String)
}

// MARK: - ColorTweenSet

/// The registry of every in-flight colour transition, keyed by ``TweenKey``.
///
/// Owned by the app delegate (not by any view), so it outlives the popup's rebuild-from-scratch
/// cycle. A value type: the AppKit wrapper holds one and mutates it in place.
public struct ColorTweenSet: Sendable, Equatable {

    /// The live transitions. A key is absent until its element has been drawn at least once.
    private var tweens: [TweenKey: ColorTween] = [:]

    public init() {}

    /// Whether anything still needs new frames. Drives the frame timer's lifetime: the timer starts
    /// when this turns true and is torn down on the first frame where it is false, so an idle app
    /// runs no animation loop at all.
    public func isAnimating(at now: Date) -> Bool {
        tweens.values.contains { !$0.isFinished(at: now) }
    }

    /// Whether `key` currently has a transition on record (finished or not).
    public func contains(_ key: TweenKey) -> Bool { tweens[key] != nil }

    /// Point `key` at `target` and return the colour to draw **this frame**.
    ///
    /// Three cases, in the order they matter:
    /// - **First sight of this key** — adopt `target` outright. A newly appearing bar must not fade
    ///   in from an arbitrary previous colour (or from black); it simply *is* its colour.
    /// - **Target unchanged** — keep the existing tween running and sample it. This is the common
    ///   path: every frame of an ongoing transition re-asserts the same target.
    /// - **Target changed** — retarget from the current interpolated value (see
    ///   ``ColorTween/retargeted(to:at:duration:)``).
    @discardableResult
    public mutating func update(_ key: TweenKey, target: RGBA, at now: Date,
                                duration: TimeInterval = ColorTween.defaultDuration) -> RGBA {
        guard let existing = tweens[key] else {
            // Duration 0, not the default: a settled record, already finished. With a non-zero
            // duration this "transition from a colour to itself" would still read as in-flight for
            // 450 ms and spin up the frame timer to animate nothing at all.
            tweens[key] = ColorTween(from: target, to: target, startedAt: now, duration: 0)
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

    /// The current colour for `key` without touching its target, or `nil` if it has none yet.
    public func value(_ key: TweenKey, at now: Date) -> RGBA? {
        tweens[key]?.value(at: now)
    }

    /// Snap every transition to its destination — used when interpolating would be wrong rather
    /// than merely unnecessary: an appearance flip (the endpoints were resolved in a *different*
    /// theme, so a blend between them is a colour that belongs to neither), a dev-tuner override
    /// (the whole point is to see the exact colour), or sleep/lock (nothing is on screen to see it).
    public mutating func finishAll() {
        for (key, tween) in tweens {
            tweens[key] = ColorTween(from: tween.to, to: tween.to, startedAt: tween.startedAt,
                                     duration: 0, touchedAt: tween.touchedAt)
        }
    }

    /// Forget entries untouched for longer than `staleAfter` — elements that are no longer drawn (a
    /// hidden calm 7-day bar, a per-model row switched off, bars replaced by the ⚠️ error state).
    /// Without this the registry would grow for the process's lifetime, and a returning element
    /// would fade in from a stale colour instead of simply appearing at its own.
    ///
    /// **Keyed on last-touched time, not on a per-frame liveness set.** The two surfaces draw in
    /// separate passes (the menu-bar image is snapshotted; the popup rebuilds its views) and the
    /// popup also redraws on its own while an `NSMenu` tracks — so "everything drawn in this pass"
    /// is not the same as "everything alive". A set-based prune would let one surface's pass evict
    /// the other's keys. Age is immune to that: anything still on screen is re-touched every time
    /// it draws, and only genuinely absent elements go quiet long enough to expire.
    ///
    /// **The default must exceed the app's slowest redraw cadence.** "Untouched" only stands in for
    /// "absent" if a *present* element is guaranteed to have drawn recently — and the widget
    /// deliberately does not repaint on a tick, so between polls its floor is the 30 s age timer
    /// (`AppDelegate`). A default shorter than that would empty the registry between ticks: a
    /// still-visible bar gets pruned, and the next colour change hits the "first sight of this key"
    /// branch above and adopts its target outright (`duration: 0`) instead of fading. 45 s clears
    /// the 30 s tick with margin and still bounds the registry.
    public mutating func pruneStale(at now: Date, staleAfter: TimeInterval = 45) {
        tweens = tweens.filter { now.timeIntervalSince($0.value.touchedAt) <= staleAfter }
    }

    /// Drop everything. Used when the data source changes wholesale (a stub switch), where carrying
    /// colours across would fade between two unrelated worlds.
    public mutating func removeAll() { tweens.removeAll() }
}
