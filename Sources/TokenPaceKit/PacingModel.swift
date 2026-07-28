import Foundation

// MARK: - LimitWindow

/// A sliding usage window whose elapsed fraction drives pacing.
///
/// Durations match the Anthropic usage API windows ported from `statusline.sh`
/// (`fiveHour` = 18 000 s, `sevenDay` = 604 800 s). The per-model sub-windows
/// `seven_day_opus` and `seven_day_sonnet` share the seven-day duration, so they
/// reuse `.sevenDay`.
public enum LimitWindow: Sendable, Equatable {
    case fiveHour
    case sevenDay

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

    /// Left edge of the gap zone = `min(usageFraction, timeFraction)`.
    public var gapStart: Double { min(usageFraction, timeFraction) }
    /// Right edge of the gap zone = `max(usageFraction, timeFraction)`.
    public var gapEnd: Double   { max(usageFraction, timeFraction) }

    /// The bar's pacing **severity** — a three-way grading of the rendered gap colour, computed
    /// AppKit-free from the raw fractions. This is the single Kit-side source that both the
    /// "calm" muting (#105) and the reset-countdown selection (#103, ADR-0028/0029) read.
    ///
    /// Mirrors the colour grading in `PopupBarView.aheadColor` (which lives in the AppKit layer and
    /// cannot be imported here). The **formula** is shared via ``PacingModel/aheadThreshold(timeFraction:)``
    /// so the two never drift; only the comparison and the 20-minute override are restated here:
    /// - `.calm` — **green** (`usage <= time`, i.e. `.onPaceOrBehind`) or **yellow** (ahead by less
    ///   than the dynamic threshold): not yet worth flagging.
    /// - `.ahead` — **orange**: ahead by `≥` the dynamic threshold, or the window resets in
    ///   `≤ 20 min` (``PacingModel/pacingOrangeOverrideSeconds``), but not yet exhausted (`usage < 1`).
    /// - `.exhausted` — **red**: `usageFraction >= 1` (limit hit, service blocked).
    ///
    /// The dynamic threshold is `0.16 · (1 − timeFraction)`: a lead that reads calm early in a window
    /// (16 pts of slack) becomes noisy as the window drains (4 pts at 75 %, 0 at the end), because
    /// there is less time left to catch up. The comparison is strict (`<`, no epsilon): a lead
    /// exactly at the threshold is orange, not yellow.
    public var severity: PacingSeverity {
        if pacing == .onPaceOrBehind { return .calm }              // green
        if usageFraction >= 1 { return .exhausted }                // red (limit hit)
        if remainingSeconds <= PacingModel.pacingOrangeOverrideSeconds { return .ahead }  // orange (≤ 20 min)
        return (usageFraction - timeFraction) < PacingModel.aheadThreshold(timeFraction: timeFraction)
            ? .calm : .ahead                                       // yellow : orange
    }

    /// Whether this bar is "calm" — its rendered gap colour is **green or yellow**, i.e. pacing is
    /// not yet worth flagging. Derived from ``severity`` so the thresholds live in one place. The
    /// menu bar uses this to mute colours (#105) and to drop the reset-countdown label when both
    /// bars are calm (#103, ADR-0028/0029).
    public var isCalm: Bool { severity == .calm }
}

// MARK: - PacingSeverity

/// Three-way pacing grade of a bar, mirroring the menu-bar/popup colour tiers. AppKit-free so the
/// pure model layer can decide reset-countdown behaviour (#103) without importing the view palette.
public enum PacingSeverity: Sendable, Equatable {
    /// Green (on pace / behind) or yellow (mildly ahead, below the dynamic threshold) — not worth flagging.
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
    public static func barLayout(
        utilization: Double,
        resetsAt: Date,
        now: Date,
        window: LimitWindow
    ) -> BarLayout {
        let usageFraction = min(1, max(0, utilization / 100))
        let remaining     = resetsAt.timeIntervalSince(now)   // seconds until reset (may be ≤ 0)
        let timeFraction  = elapsedFraction(resetsAt: resetsAt, now: now, window: window)
        let pacing: PacingState = timeFraction >= usageFraction ? .onPaceOrBehind : .ahead
        return BarLayout(usageFraction: usageFraction, timeFraction: timeFraction,
                         pacing: pacing, remainingSeconds: remaining)
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
