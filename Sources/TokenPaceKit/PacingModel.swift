import Foundation

// MARK: - LimitWindow

/// A sliding usage window whose elapsed fraction drives pacing.
///
/// Durations match the Anthropic usage API windows ported from `statusline.sh`
/// (`fiveHour` = 18 000 s, `sevenDay` = 604 800 s). The per-model sub-windows
/// `seven_day_opus` and `seven_day_sonnet` share the seven-day duration, so they
/// reuse `.sevenDay`.
public enum LimitWindow: Sendable, Equatable, Hashable {
    case fiveHour
    case sevenDay

    /// A stable identifier for this window, used to key per-bar UI state that must survive a view
    /// being torn down and rebuilt (the colour-transition registry — see ``TweenKey``). Deliberately
    /// spelled out rather than derived from the case name, so a future rename cannot silently change
    /// the key and orphan an in-flight animation.
    public var id: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }

    /// Window length in whole seconds — the denominator for elapsed-time pacing.
    /// Matches the `window_seconds` argument of `calc_time_pct` in `statusline.sh`.
    public var durationSeconds: Int {
        switch self {
        case .fiveHour: return 18_000
        case .sevenDay: return 604_800
        }
    }

    /// Number of equal sub-intervals the popup bar's tick ruler splits this window into:
    /// 5 hour-boundaries for `.fiveHour`, 7 day-boundaries for `.sevenDay`. The bar draws
    /// `subdivisions - 1` interior ticks at `k / subdivisions` (issue #38). The day-boundary
    /// ticks are anchored to `resets_at` (the window is `[resets_at - 7d … resets_at]`), so
    /// they sit at even `k/7` fractions — not at calendar midnight.
    public var subdivisions: Int {
        switch self {
        case .fiveHour: return 5
        case .sevenDay: return 7
        }
    }

    /// The green→blue (`.farBehind`) crossover width, as a **fixed span of real time** rather than a
    /// fraction of the window: the surplus (`time − usage`) must exceed this much of the window to read
    /// blue. **60 min for the 5-hour window, 24 h for the 7-day window** — see
    /// ``PacingModel/behindThreshold(windowDurationSeconds:)``, which divides this by
    /// ``durationSeconds`` to get the fraction the pacing math compares against.
    public var blueBehindWidthSeconds: Int {
        switch self {
        case .fiveHour: return 3_600      // 60 min
        case .sevenDay: return 86_400     // 24 h
        }
    }
}

// MARK: - PacingState

/// Whether usage is running ahead of or at/under the linear time pace.
///
/// Maps downstream (in `StatusItemView`, issue #10) to bar-gap colors — not here.
/// - ``ahead``: usage exceeds elapsed time (`usagePct > timePct`). Rendered red.
/// - ``onPaceOrBehind``: usage is at or below elapsed time (`timePct >= usagePct`).
///   Rendered green. **The exact-equality tie (`usage == time`) lands here**, matching
///   the `u_blocks <= t_blocks` branch in `statusline.sh`'s `build_progress_bar`.
public enum PacingState: Sendable, Equatable {
    /// Usage exceeds elapsed time — burning budget faster than the linear norm (bad).
    case ahead
    /// Usage is at or below elapsed time — on pace or under the norm (good).
    /// Covers the exact-equality case.
    case onPaceOrBehind
}

// MARK: - LimitIndicator

/// Whether a limit's usage window is **exhausted** — the one distinction the UI still draws from the
/// integer usage percent (the popup's "limit reached" wording).
///
/// Originally a three-tier port of `get_limit_indicator` from `statusline.sh`, but the middle
/// `.warning` band (a `⚠` glyph for "> 90 % used before 90 % of the window elapsed") was dropped: the
/// dynamic pacing colour (green→yellow→orange→red, ADR-0044) now carries the "how far ahead" signal on
/// its own, and TokenPace has outgrown statusline parity. What remains is a two-state exhausted flag.
public enum LimitIndicator: Sendable, Equatable {
    /// Usage limit is exhausted (`utilization` truncated to 100). The popup reads "limit reached".
    case critical
    /// Not exhausted — normal state (pacing is conveyed by the bar colour, not a glyph).
    case neutral
}

// MARK: - BarLayout

/// Continuous, pixel-drawable layout of one pacing bar. All fractions are in **[0, 1]**.
///
/// The view renders three contiguous zones left→right:
/// 1. **used**: `[0, usageFraction)` — gray (`dark_gray` 236 in statusline)
/// 2. **gap**: between usage and time edges — green if `pacing == .onPaceOrBehind`,
///    red if `.ahead` (`bright_green` 71 / `bright_red` 167)
/// 3. **future**: `[max(usage, time), 1]` — blue (`dark_blue` 23)
///
/// A thin indicator tick sits at `timeFraction` (the elapsed-time edge).
///
/// **Design note:** fractions are continuous (not quantised into blocks). Block
/// quantisation is a terminal-rendering artefact; see `PacingModel.blockIndex(fraction:cells:)`
/// for the optional popup-only derivative and ADR-0005 for the rationale.
public struct BarLayout: Sendable, Equatable {
    /// Right edge of the gray "used" zone: `utilization / 100`, clamped to [0, 1].
    public let usageFraction: Double
    /// Right edge of the pacing gap and position of the time-indicator tick:
    /// elapsed window fraction, clamped to [0, 1].
    public let timeFraction: Double
    /// Color/semantic meaning of the gap between the usage and time edges.
    public let pacing: PacingState
    /// Absolute seconds until this limit's window resets (`resetsAt - now`), for the 20-minute
    /// orange override (``PacingModel/pacingOrangeOverrideSeconds``) that ``timeFraction`` alone
    /// cannot express — 20 min is 6.7 % of the 5h window but 0.2 % of the 7d window. May be ≤ 0
    /// (reset now/past) or the full window length; only the `≤ 1200 s` case changes the colour.
    public let remainingSeconds: TimeInterval
    /// The window's full length in seconds (18 000 for 5h, 604 800 for 7d). Carried so the
    /// **start**-of-window override for the blue (`farBehind`) zone can be expressed as
    /// `elapsed = windowDurationSeconds − remainingSeconds ≤ 1200` — the symmetric counterpart of
    /// the *end*-of-window orange override, which needs only `remainingSeconds`. See
    /// ``PacingModel/pacingBlueStartOverrideSeconds``.
    public let windowDurationSeconds: Int
    /// Whether this bar may render the blue (`farBehind`) zone at all. `false` forces the behind side
    /// to plain green at any surplus — the same early exit the retired `FarBehindInterval.off` used to
    /// provide, now driven by data rather than by a user setting.
    ///
    /// Set `false` for every bar whose blue would be a **lie about the week**: the 5-hour bar (and the
    /// 7-day-paced per-model bars) when the weekly window has no headroom left. Blue reads as "there is
    /// room to push"; that advice must not appear while the 7-day quota is spent or running ahead of
    /// pace — see ``PacingModel/weeklyHasHeadroom(in:now:)``. The 7-day bar itself is always `true`
    /// (it never gates on itself), and the inert idle placeholders are `false` (no pacing at all).
    ///
    /// Mirrored onto the layout so ``severity`` and the AppKit `behindColor`/`isFarBehind` — which read
    /// it off this struct — cannot disagree about whether blue is on the table.
    public let blueAllowed: Bool

    /// Memberwise init, written out so ``blueAllowed`` can default to `true` — the synthesized one
    /// cannot give a default to a `let` without an initial value. Callers that build a bar for a real
    /// window pass the gate explicitly; the inert placeholders pass `false`.
    public init(
        usageFraction: Double,
        timeFraction: Double,
        pacing: PacingState,
        remainingSeconds: TimeInterval,
        windowDurationSeconds: Int,
        blueAllowed: Bool = true
    ) {
        self.usageFraction = usageFraction
        self.timeFraction = timeFraction
        self.pacing = pacing
        self.remainingSeconds = remainingSeconds
        self.windowDurationSeconds = windowDurationSeconds
        self.blueAllowed = blueAllowed
    }

    /// Left edge of the gap zone = `min(usageFraction, timeFraction)`.
    public var gapStart: Double { min(usageFraction, timeFraction) }
    /// Right edge of the gap zone = `max(usageFraction, timeFraction)`.
    public var gapEnd: Double   { max(usageFraction, timeFraction) }

    /// The signed lead `r = (u − t) / (1 − t)` both marker-less scales are built on: how far ahead
    /// of (positive) or behind (negative) pace the spending is, measured in units of the time left
    /// before the reset.
    ///
    /// `nil` means "saturated regardless of the ratio" — the two cases where the ratio is either
    /// undefined or answered before it is asked:
    ///
    /// - **`u >= 1` (exhausted)** — a full bar at any `t`. Deliberate: a shrinking red bar reads as
    ///   "the problem is easing" while work is still blocked. Time-to-reset is carried by the
    ///   countdown and the pause glyph.
    /// - **`t = 1`** (reset due/past) — would divide by zero. No time is left to press against, so
    ///   the bar is full for any `u`. The exhausted check runs first, so the `u == t == 1` tie is
    ///   caught there.
    ///
    /// Keeping both guards here means the ordering that makes them safe is a property of one
    /// function rather than a comment repeated in every caller.
    private var signedLead: Double? {
        if usageFraction >= 1 { return nil }
        let remaining = 1 - timeFraction
        guard remaining > 0 else { return nil }   // reset due: no time left to press against
        return (usageFraction - timeFraction) / remaining
    }

    /// The **Pressure** ribbon's length — the **ahead half of ``gaugeOffset``**, and nothing else
    /// (#307, rescaled by ADR-0101).
    ///
    ///     r      = (u − t) / (1 − t)          // signed lead, in units of the time remaining
    ///     length = clamp(r, 0, 1)             // i.e. max(0, gaugeOffset)
    ///
    /// The ribbon's zero sits **at `t`**: every state at or behind pace is zero, and the renderers
    /// floor that to the minimum pill. Above pace the ribbon grows to `u` — **signed, never
    /// absolute**.
    ///
    /// **Width alone encodes severity.** The expression is the identity on `r`, and the colour
    /// thresholds are themselves conditions on `r` (the orange one is `(u − t) < 0.16 · (1 − t)`,
    /// i.e. `r < 0.16` — see ``PacingModel/aheadThreshold(timeFraction:)``), so the severity bands
    /// are **fixed positions on the bar, identical at any point in the window**:
    ///
    /// | colour | width |
    /// |---|---|
    /// | blue (far behind) | `0` |
    /// | green (on pace or behind) | `0` |
    /// | yellow (mild lead) | `0 – 0.16` |
    /// | orange (ahead) | `0.16 – 1` |
    /// | red (exhausted) | `1` |
    ///
    /// The yellow→orange boundary is therefore **`aheadThreshold` itself**, uncomputed: the drawn
    /// length *is* the number the model compares. Nothing sits between orange's top and red — the
    /// scale reaches `1` continuously as `u → 1`, rather than stopping short and jumping.
    ///
    /// **Why signed rather than `|u − t|`.** An absolute value cannot tell "ahead" from "behind":
    /// it bottoms out at `u == t` and then climbs back. Trace an early burst followed by silence
    /// (`u` frozen at 40 %) — `|u − t|/(1 − t)` gives `25 % → 0 % → 50 % → 100 %`, ending on a full
    /// bar for the calmest state of the session. This form gives `25 % → 0 % → 0 % → 0 %`: the
    /// pressure decays to nothing and stays there, which is what actually happened.
    ///
    /// **Zero means "at or behind pace".** Just over half the reachable state space lands on `0`
    /// and renders as the minimum pill. That is the deliberate trade: on the calm side the action
    /// is carried by the colour (green "do nothing" vs blue "you can push"), and gradation *within*
    /// "do nothing" maps to no different action. The style that *does* draw the calm side is
    /// ``BarStyle/gauge``, which spends its left half on exactly that quantity.
    ///
    /// Only the marker-less **Pressure** presentation uses this; **Progress** (`BarStyle.progress`)
    /// keeps drawing `gapStart..gapEnd` on the window scale, where its time marker is meaningful.
    /// A marker is impossible here — on this track it would sit at zero forever.
    public var pressureLength: Double { max(0, gaugeOffset) }

    /// The **Gauge** ribbon's signed offset from the bar's **centre** (#326, ADR-0079).
    ///
    ///     r      = (u − t) / (1 − t)          // the signed lead, in units of the time remaining
    ///     offset = clamp(r, −1, +1)
    ///
    /// Zero is the middle. The ribbon runs from the centre to `centre + offset · (width/2)`:
    /// **right** when spending is ahead of pace, **left** when it is behind.
    ///
    /// **Both halves measure the same quantity, symmetrically.** Until ADR-0101 the ahead half was
    /// divided by a coefficient `k = 1.25` while the behind half took `r` raw. That asymmetry was
    /// inherited from a Pressure scale whose zero sat left of `t`; once that shift went, the
    /// coefficient stopped balancing anything and only compressed — it *narrowed* the yellow band
    /// rather than widening it, and left the top 20 % of the ahead half unreachable by any state
    /// short of exhaustion (`r < 1` while `u < 1`), so the bar could only enter it by jumping.
    ///
    /// **`offset = −1` means the surplus equals all of the time left**: you could not spend it even
    /// if you tried. At `t = 90 %, u = 70 %` the surplus (20 pp) is twice the time left (10 pp), so
    /// the left half is full. Algebraically the left half saturates whenever `u ≤ 2t − 1` —
    /// impossible before `t = 50 %`, then increasingly common. Late in the window most surpluses
    /// genuinely are larger than the time left to spend them.
    ///
    /// **`u == t` is exactly `0`**, and so is ``pressureLength`` — the two scales agree on the tie
    /// and on the whole ahead half, because Pressure *is* `max(0, offset)`. The renderers floor a
    /// degenerate ribbon to a centred pill so it reads as "on pace", not as an empty track.
    ///
    /// Edge cases live in ``signedLead`` — `u >= 1` is `+1` at any `t`, and a due reset (`t = 1`)
    /// is `+1` for any `u`.
    ///
    /// Used directly by ``BarStyle/gauge`` and, through `max(0, …)`, by ``BarStyle/pressure``. It is
    /// **render-only** geometry and carries no colour of its own — the same `(u, t)` yields the same
    /// ``severity`` in every style.
    public var gaugeOffset: Double {
        guard let r = signedLead else { return 1 }
        return min(1, max(-1, r))
    }

    /// The bar's pacing **severity** — a three-way grading of the rendered gap colour, computed
    /// AppKit-free from the raw fractions. This is the single Kit-side source that both the
    /// "calm" muting (#105) and the reset-countdown selection (#103, ADR-0028/0029) read.
    ///
    /// Mirrors the colour grading in `PopupBarView.aheadColor`/`behindColor` (which live in the AppKit
    /// layer and cannot be imported here). The **formulas** are shared via
    /// ``PacingModel/aheadThreshold(timeFraction:)`` and ``PacingModel/behindThreshold(timeFraction:)``
    /// so the two never drift; only the comparison and the two overrides are restated here:
    /// - `.farBehind` — **blue** (`.onPaceOrBehind`, behind by `>` the fixed behind-threshold, and
    ///   past the 20-min start override): deep behind pace / big surplus, calmer than green.
    /// - `.calm` — **green** (`usage <= time` but behind by `≤` the behind-threshold, or within the
    ///   first 20 min) or **yellow** (ahead by less than the ahead-threshold): not yet worth flagging.
    /// - `.ahead` — **orange**: ahead by `≥` the dynamic threshold, or the window resets in
    ///   `≤ 20 min` (``PacingModel/pacingOrangeOverrideSeconds``), but not yet exhausted (`usage < 1`).
    /// - `.exhausted` — **red**: `usageFraction >= 1` (limit hit, service blocked).
    ///
    /// The **ahead** threshold is dynamic (`0.16 · (1 − timeFraction)` — 16 pts of slack early,
    /// shrinking to 0 at the end); a lead exactly at it is orange (strict `<`). The **behind** threshold
    /// is instead a *fixed span of real time* — 60 min (5h) / 24 h (7d) as a fraction of the window
    /// (``PacingModel/behindThreshold(windowDurationSeconds:)``); a surplus exactly at it is green
    /// (strict `>`, the louder of the two calm tones). The **start** override keeps the first 20 minutes green so
    /// blue never flickers at window start (symmetric to the end-of-window orange override).
    public var severity: PacingSeverity {
        if pacing == .onPaceOrBehind {
            // Blue is off the table for this bar — the weekly window has no headroom, or the bar is an
            // inert placeholder. The behind side stays plain green at any surplus.
            if !blueAllowed { return .calm }                                            // green (blue gated)
            // 20-min start-of-window override: always plain green early on (blue must not flicker at
            // start). elapsed < 0 under clock skew (remaining > duration) also folds to green here.
            let elapsed = Double(windowDurationSeconds) - remainingSeconds
            if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return .calm }   // green
            return (timeFraction - usageFraction) > PacingModel.behindThreshold(windowDurationSeconds: windowDurationSeconds)
                ? .farBehind : .calm                              // blue : green
        }
        if usageFraction >= 1 { return .exhausted }                // red (limit hit)
        if remainingSeconds <= PacingModel.pacingOrangeOverrideSeconds { return .ahead }  // orange (≤ 20 min)
        return (usageFraction - timeFraction) < PacingModel.aheadThreshold(timeFraction: timeFraction)
            ? .calm : .ahead                                       // yellow : orange
    }

    /// Whether this bar is "calm" — its rendered gap colour is **blue, green, or yellow**, i.e. pacing
    /// is not yet worth flagging. Derived from ``severity`` so the thresholds live in one place; both
    /// `.farBehind` (blue, deep behind) and `.calm` (green/yellow) count as calm — blue is *calmer*
    /// than green, never noisier. The menu bar uses this to mute colours (#105) and to drop the
    /// reset-countdown label when both bars are calm (#103, ADR-0028/0029). Note: the reset-countdown
    /// *noisy* test keys off `.ahead`/`.exhausted` directly (not `!isCalm`), so `.farBehind` never
    /// is ever flagged: `CalmBarHiding` hides a blue bar exactly as it hides a green one.
    public var isCalm: Bool { severity == .calm || severity == .farBehind }
}

// MARK: - PacingSeverity

/// Four-way pacing grade of a bar, mirroring the menu-bar/popup colour tiers. AppKit-free so the
/// pure model layer can decide reset-countdown behaviour (#103) without importing the view palette.
///
/// The calm order (calmest → loudest): **blue** (`farBehind`) → **green/yellow** (`calm`) →
/// **orange** (`ahead`) → **red** (`exhausted`). `farBehind` and `calm` are both "not worth
/// flagging" (see ``BarLayout/isCalm``); `farBehind` is only *calmer* than green, never noisier.
public enum PacingSeverity: Sendable, Equatable {
    /// Blue — deep behind pace / big surplus: usage is below the elapsed time by `≥` the dynamic
    /// ``PacingModel/behindThreshold(timeFraction:)`` (and past the 20-min start override). Calmer
    /// than green; never flagged, never "noisy". Restricted to the base 5h/7d bars in the render
    /// layer (per-model and credits rows stay green).
    case farBehind
    /// Green (on pace / mildly behind, below the dynamic threshold) or yellow (mildly ahead, below
    /// the dynamic threshold) — not worth flagging.
    case calm
    /// Orange — ahead by `≥` the dynamic threshold (or `≤ 20 min` to reset), not yet exhausted (`usage < 1`).
    case ahead
    /// Red — the limit is exhausted (`usage >= 1`); the service is blocked until this window resets.
    case exhausted
}

// MARK: - PacingModel

/// Pure pacing arithmetic ported from the Claude Code statusline (`statusline.sh`).
///
/// All entry points are **stateless and deterministic**: every method takes an
/// explicit `now: Date` so tests need no clock mocking. The type is isolated from
/// network, Keychain, and AppKit — it receives already-parsed API values and returns
/// plain Swift types.
///
/// ## Unit mapping (intentional asymmetry)
/// - `barLayout` keeps `utilization` as a **continuous** fraction [0, 1] for
///   pixel-accurate rendering.
/// - `limitIndicator` and `elapsedFraction`-derived time use **integer percent**
///   comparison, matching statusline's integer arithmetic for point-to-point parity.
///   Do not "fix" these into a single unit — the asymmetry is load-bearing.
///
/// ## Relationship to `statusline.sh`
/// | bash function | Swift entry point |
/// |---|---|
/// | `calc_time_pct` | `elapsedFraction(resetsAt:now:window:)` |
/// | `get_limit_indicator` | `limitIndicator(utilization:timePercent:)` |
/// | `build_progress_bar` zones | `barLayout(utilization:resetsAt:now:window:)` |
/// | `build_progress_bar` block math | `blockIndex(fraction:cells:)` (popup-only) |
public enum PacingModel {

    // MARK: elapsedFraction

    /// Fraction of the window already elapsed, in [0, 1].
    ///
    /// **Port of `calc_time_pct`** — but returns a continuous `Double` instead of an
    /// integer percent, because the menu bar renders pixel-accurately. The difference
    /// from bash's floor division is < 1 % and does not affect indicator thresholds
    /// (those are computed from integer percents separately).
    ///
    /// Boundary rules, ported 1:1 from `statusline.sh` lines 266–287:
    /// - `resetsAt ≤ now` (reset is now or in the past) → `1.0`
    /// - remaining ≥ window duration (clock skew / future reset) → `0.0`
    /// - otherwise: `elapsed / durationSeconds`, clamped to [0, 1]
    ///
    /// The "empty reset" branch from bash (`parse_reset_epoch` returning empty) is not
    /// applicable here: `resetsAt` is a non-optional `Date` — parsing of the raw API
    /// string (microseconds + `+00:00` suffix) is handled upstream (issue #7).
    public static func elapsedFraction(resetsAt: Date, now: Date, window: LimitWindow) -> Double {
        let remaining = resetsAt.timeIntervalSince(now) // seconds (Double)
        if remaining <= 0 { return 1.0 }
        let duration = Double(window.durationSeconds)
        if remaining >= duration { return 0.0 }
        return (duration - remaining) / duration
    }

    // MARK: limitIndicator

    /// Whether a limit's usage window is **exhausted** (`.critical`) or not (`.neutral`).
    ///
    /// The usage percent is truncated to an integer before the `== 100` test (`${x%.*}` in the
    /// original bash), so **precision contract:** `99.9999` truncates to `99` and is NOT `.critical`.
    /// Do not add an epsilon tolerance. The former `.warning` band (`> 90 %` before `90 %` of the
    /// window elapsed) was removed with the statusline parity it came from — the pacing colour now
    /// carries that signal (ADR-0044).
    ///
    /// - Parameter utilization: API `utilization` field, a percent in [0, 100] (e.g. `13.0`).
    ///   Must be finite and ≥ 0.
    public static func limitIndicator(utilization: Double) -> LimitIndicator {
        Int(max(0, utilization)) == 100 ? .critical : .neutral   // truncation toward zero == floor for x ≥ 0
    }

    // MARK: ahead-of-pace threshold

    /// Seconds-until-reset at or below which the ahead-of-pace gap is forced to orange (`.ahead`),
    /// regardless of the dynamic threshold: the window is about to reset, so any lead is worth
    /// flagging. 20 minutes. Kept as **absolute seconds** (not a time fraction) because 20 min is
    /// 6.7 % of the 5h window but only 0.2 % of the 7d window — it cannot come from `timeFraction`.
    public static let pacingOrangeOverrideSeconds: TimeInterval = 1200

    /// Seconds-since-window-**start** at or below which the on-pace/behind gap is forced to plain green
    /// (never blue `.farBehind`), regardless of the behind-threshold: at the very start of a window
    /// almost any usage reads as a big surplus, so blue would flicker on immediately. 20 minutes.
    /// The symmetric counterpart of ``pacingOrangeOverrideSeconds`` (which guards the *end*): elapsed
    /// since start is `windowDurationSeconds − remainingSeconds`, so this one needs the window length.
    public static let pacingBlueStartOverrideSeconds: TimeInterval = 1200

    /// The yellow→orange boundary for the ahead-of-pace gap, as a function of how far the window
    /// has elapsed: `0.16 · (1 − timeFraction)`, clamped to `[0, 0.16]`.
    ///
    /// 16 pts of slack at the start of a window (`t = 0`), 8 at the half-way point, 4 at 75 %, 0 at
    /// the end. Rationale: a modest lead is harmless early (plenty of time to coast back onto pace)
    /// but the same lead late in a window is not, because the window resets before you can catch up.
    ///
    /// A lead below this stays yellow (`.calm`); at or above it is orange (`.ahead`). Shared by
    /// ``BarLayout/severity`` (Kit) and `PopupBarView.aheadColor` (AppKit) so the colour and the
    /// severity never drift. The comparison side uses a strict `<` (a lead exactly at the threshold
    /// is orange).
    ///
    /// - Parameter timeFraction: Fraction of the window elapsed, in `[0, 1]` (already clamped by
    ///   ``elapsedFraction(resetsAt:now:window:)``; the extra clamp here is defence in depth).
    public static func aheadThreshold(timeFraction: Double) -> Double {
        min(0.16, max(0, 0.16 * (1 - timeFraction)))
    }

    // MARK: stand-by (how long to pause for green)

    /// How long to **stop spending** for an ahead-of-pace window to come back to **green**, in seconds.
    /// `nil` when there is no such wait to offer.
    ///
    /// The bar is orange because usage has outrun the clock. Usage only ever grows, but the elapsed
    /// fraction grows on its own — so pausing lets `timeFraction` catch up to a frozen `usageFraction`.
    /// Green is the `usage <= time` side (``PacingState/onPaceOrBehind``), so the wait is exactly the
    /// lead converted back into window time:
    ///
    ///     standBy = windowDurationSeconds · (usageFraction − timeFraction)
    ///
    /// **No threshold coefficient appears here, deliberately.** ``aheadThreshold(timeFraction:)``
    /// (`0.16 · (1 − t)`) is the *yellow→orange* boundary — it lives entirely inside the ahead side,
    /// where `PopupBarView.aheadColor` picks between yellow and orange. Green is decided by a different
    /// function (`behindColor`, on the `usage <= time` branch), which never consults it. Solving for
    /// `severity == .calm` instead would land on **yellow** — `.calm` covers both green and yellow —
    /// and would under-report the wait, promising green well before it arrives.
    ///
    /// Returns `nil` when a pause cannot deliver green:
    /// - the bar is not orange (``PacingSeverity/ahead``) — nothing to wait out;
    /// - the window is exhausted (`usage >= 1`, red): only the reset clears it, and `usage` is pinned
    ///   at the ceiling so the clock can never catch up;
    /// - the lead has already gone (`standBy <= 0`) — defence against an inconsistent layout;
    /// - green would land inside the window's last ``pacingOrangeOverrideSeconds`` (20 min), where
    ///   ``BarLayout/severity`` forces orange regardless of the lead. The check uses the remaining time
    ///   **at that future moment** (`remainingSeconds − standBy`), not the present one, because the
    ///   countdown runs down during the wait too.
    ///
    /// Pure arithmetic on the layout the caller is already drawing — no clock, so no `now` parameter.
    public static func standBySecondsForGreen(_ bar: BarLayout) -> TimeInterval? {
        guard bar.severity == .ahead else { return nil }   // green/yellow/blue/red: nothing to wait out
        guard bar.usageFraction < 1 else { return nil }    // exhausted: only the reset helps
        let lead = bar.usageFraction - bar.timeFraction
        guard lead > 0 else { return nil }
        let standBy = Double(bar.windowDurationSeconds) * lead
        // The 20-minute end-of-window override would still paint it orange on arrival.
        guard bar.remainingSeconds - standBy > pacingOrangeOverrideSeconds else { return nil }
        return standBy
    }

    /// The shortest stand-by worth putting in front of the user: below this it is noise. 20 minutes.
    ///
    /// On the seven-day window a wait under 20 min carries no decision — it elapses while the user is
    /// still reading the popup, and the bar greens on its own without anyone pausing for it.
    public static let standByFloorSeconds: TimeInterval = 1200

    /// ``standBySecondsForGreen(_:)`` filtered by whether the wait earns a line in the popup — the
    /// display policy kept out of the view so the threshold is testable on its own.
    ///
    /// Only the ``standByFloorSeconds`` noise floor is applied here.
    ///
    /// **"Don't show it when the reset is about as soon as the wait" needs no separate rule.** The
    /// intent — never print a stand-by that duplicates the reset line above it — is already enforced,
    /// and more strictly, by the end-of-window check inside ``standBySecondsForGreen(_:)``: that one
    /// requires green to land more than ``pacingOrangeOverrideSeconds`` (20 min) before the reset,
    /// because otherwise the bar would still be forced orange on arrival. A 10-minute proximity rule
    /// sits *inside* that 20-minute exclusion, so it could never reject anything the stronger check had
    /// let through — it would be dead code. A wait that runs past the reset is refused by the same
    /// check, for the same reason.
    public static func displayableStandBySecondsForGreen(_ bar: BarLayout) -> TimeInterval? {
        guard let standBy = standBySecondsForGreen(bar) else { return nil }
        guard standBy >= standByFloorSeconds else { return nil }
        return standBy
    }

    /// The fixed scale applied to the base green→blue width (1 h for the 5-hour window, 1 d for the
    /// 7-day one), giving the shipped **2 h / 5 h = 0.40** and **2 d / 7 d ≈ 0.2857** crossovers.
    ///
    /// This was the user-facing `FarBehindInterval` (×1 / ×2 / ×3 / off), retired in favour of the
    /// single shipped width: ×2 was already the default and the value the usage journal recorded at,
    /// ×1 had been rejected as the default when the option was introduced, and ×3 put the 5-hour
    /// threshold at 0.60 — a surplus that window can barely reach (`surplus ≤ timeFraction`), i.e. a
    /// dead zone. "Whether blue applies at all" now lives in ``BarLayout/blueAllowed``, not here.
    public static let farBehindWidthMultiplier = 2

    /// The green→blue (`.farBehind`) boundary for the on-pace/behind gap, as a **fixed span of real
    /// time** rather than a fraction of the window (unlike ``aheadThreshold(timeFraction:)``, which is
    /// dynamic). Returned as the fraction the pacing math compares against:
    /// `LimitWindow.blueBehindWidthSeconds × farBehindWidthMultiplier / windowDurationSeconds` —
    /// **2 h / 5 h = 0.40** (5h) and **2 d / 7 d ≈ 0.2857** (7d).
    ///
    /// A surplus (`timeFraction − usageFraction`) at or below this stays green (`.calm`); a surplus
    /// strictly above it is blue (`.farBehind`). Being behind by more than two hours (5h) / two days
    /// (7d) means you have real, fixed headroom to push, independent of how far the window has elapsed.
    /// Shared by ``BarLayout/severity`` (Kit) and `PopupBarView.behindColor` (AppKit) so colour and
    /// severity never drift.
    ///
    /// This answers only **how wide** the blue zone is, never **whether** it applies — that is
    /// ``BarLayout/blueAllowed``, checked before this is ever called. So this never returns `+∞`.
    ///
    /// The comparison side uses a strict `>` (a surplus exactly at the threshold is green — the louder
    /// of the two calm tones). A separate 20-min *start* override (``pacingBlueStartOverrideSeconds``)
    /// keeps the first 20 minutes green regardless of this.
    ///
    /// - Parameter windowDurationSeconds: The window length (``LimitWindow/durationSeconds``: 18 000 for
    ///   5h, 604 800 for 7d), carried on ``BarLayout``. A non-positive value (inert placeholder bars)
    ///   returns `0` — any surplus reads as the calmer green, matching those bars' forced-calm intent.
    public static func behindThreshold(windowDurationSeconds: Int) -> Double {
        guard windowDurationSeconds > 0 else { return 0 }
        let width = blueBehindWidthSeconds(forWindowDurationSeconds: windowDurationSeconds)
            * farBehindWidthMultiplier
        return Double(width) / Double(windowDurationSeconds)
    }

    /// The fixed green→blue crossover width in seconds for a window of the given length — 60 min for the
    /// 5-hour window, 24 h for the 7-day window (``LimitWindow/blueBehindWidthSeconds``). Resolved by
    /// duration so ``BarLayout`` (which carries only `windowDurationSeconds`, not the `LimitWindow`) can
    /// compute the threshold. An unrecognised duration falls back to the 5-hour width proportionally
    /// (`0.20 · duration`) — only reachable from synthetic/placeholder layouts, never the real windows.
    static func blueBehindWidthSeconds(forWindowDurationSeconds duration: Int) -> Int {
        switch duration {
        case LimitWindow.fiveHour.durationSeconds: return LimitWindow.fiveHour.blueBehindWidthSeconds
        case LimitWindow.sevenDay.durationSeconds: return LimitWindow.sevenDay.blueBehindWidthSeconds
        default:                                   return Int(0.20 * Double(duration))
        }
    }

    // MARK: barLayout

    /// Full bar layout for one limit window: usage zone, pacing gap, and time marker.
    ///
    /// Combines `elapsedFraction` with the continuous usage fraction and decides the
    /// gap colour (`PacingState`). The indicator tick sits at `timeFraction`.
    ///
    /// **Intentional unit split:**
    /// - `usageFraction` in `BarLayout` is continuous (no truncation) — pixel rendering.
    /// - `pacing` uses a `>=` comparison on the raw fractions, matching the
    ///   `u_blocks <= t_blocks` dispatch in `statusline.sh` (the equality tie → green).
    ///
    /// - Parameters:
    ///   - utilization: API `utilization`, percent in [0, 100].
    ///   - resetsAt: Parsed `resets_at` date from the API response.
    ///   - now: Current instant (inject for deterministic tests; do **not** call `Date()` here).
    ///   - window: The rolling window this limit belongs to.
    ///   - blueAllowed: Whether this bar may render the blue (`farBehind`) zone, stored onto
    ///     ``BarLayout/blueAllowed``. Defaults to `true` so synthetic/preview callers keep the shipped
    ///     look; the real callers pass ``weeklyHasHeadroom(in:now:)`` for the 5-hour and per-model bars,
    ///     `true` for the 7-day bar (it never gates on itself).
    public static func barLayout(
        utilization: Double,
        resetsAt: Date,
        now: Date,
        window: LimitWindow,
        blueAllowed: Bool = true
    ) -> BarLayout {
        let usageFraction = min(1, max(0, utilization / 100))
        let remaining     = resetsAt.timeIntervalSince(now)   // seconds until reset (may be ≤ 0)
        let timeFraction  = elapsedFraction(resetsAt: resetsAt, now: now, window: window)
        let pacing: PacingState = timeFraction >= usageFraction ? .onPaceOrBehind : .ahead
        return BarLayout(usageFraction: usageFraction, timeFraction: timeFraction,
                         pacing: pacing, remainingSeconds: remaining,
                         windowDurationSeconds: window.durationSeconds,
                         blueAllowed: blueAllowed)
    }

    // MARK: weeklyHasHeadroom

    /// Whether the **7-day** window still has room to spend — the gate that lets a 5-hour (or
    /// 7-day-paced per-model) bar render the blue `farBehind` zone.
    ///
    /// Blue says *there is room to push*. Computed per-window, that advice becomes a lie whenever the
    /// week itself is spent or running ahead of pace: a freshly reset 5-hour window turns blue 20 min
    /// in and urges a push the weekly quota cannot fund. The worst shape is a blocked week — the 5-hour
    /// bar empties out and starts advertising headroom while no work is possible at all.
    ///
    /// So blue on the short window requires the week to be **itself** calm:
    /// `pacing == .onPaceOrBehind && usageFraction < 1` — i.e. the 7-day bucket is blue or green.
    /// A yellow/orange/red week closes the gate and the 5-hour bar degrades to plain green (not
    /// yellow: its own pace really is calm; only the *advice* is withdrawn).
    ///
    /// **Closed by default.** Returns `false` when the 7-day reset is missing or unparseable, because
    /// the bar builders fall back to `resetsAt = now`, which yields `timeFraction == 1.0` — a
    /// maximally-"behind" week that would falsely *open* the gate. Absent a trustworthy weekly clock,
    /// the advice is withheld rather than guessed. (``UsageSnapshot/hasBrokenActiveReset`` is the wrong
    /// predicate here: it ignores a zero-usage window and an empty date, which are exactly the cases
    /// that must still close the gate.)
    ///
    /// Derived through ``barLayout(utilization:resetsAt:now:window:blueAllowed:)`` rather than by
    /// re-deriving the arithmetic, so the gate cannot disagree with the 7-day row the user is looking
    /// at. Not recursive: only `pacing`/`usageFraction` are read, and neither depends on `blueAllowed`.
    public static func weeklyHasHeadroom(in snapshot: UsageSnapshot, now: Date) -> Bool {
        guard let resetsAt = ResetClock.parse(snapshot.sevenDay.resetsAt) else { return false }
        let weekly = barLayout(utilization: snapshot.sevenDay.utilization,
                               resetsAt: resetsAt, now: now, window: .sevenDay)
        return weekly.pacing == .onPaceOrBehind && weekly.usageFraction < 1
    }

    // MARK: blockIndex (popup-only derivative)

    /// Quantises a fraction [0, 1] into a block index for an `n`-cell rendering,
    /// using the statusline's round-half-up rule: `(pct × n + 50) / 100`.
    ///
    /// **Reserved for popup block-marker rendering (issue #11).** The menu-bar bar is
    /// pixel-accurate and does NOT call this. Keeping it here ports the complete block
    /// arithmetic from `statusline.sh`'s `build_progress_bar` (lines 101–121) and
    /// satisfies the bash-parity acceptance criterion for issue #6.
    ///
    /// - Parameters:
    ///   - fraction: A value in [0, 1]; clamped before computation.
    ///   - cells: Total number of cells (e.g. 30 for the 5h bar, 28 for 7d in statusline).
    /// - Returns: Block index in [0, cells].
    public static func blockIndex(fraction: Double, cells: Int) -> Int {
        let pct = min(100, max(0, fraction * 100))
        // Equivalent to bash integer `(pct * cells + 50) / 100` — round-half-up.
        return Int((pct * Double(cells) + 50) / 100)
    }
}
