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

/// Severity tier derived from usage vs. elapsed-time pacing.
///
/// Direct port of `get_limit_indicator` in `statusline.sh` (lines 74–87):
/// - `critical` when usage integer == 100 (❌)
/// - `warning` when usage integer > 90 **and** time integer ≤ 90 (⚠️)
/// - `neutral` otherwise
///
/// Both values are truncated to integers before comparison, matching bash's
/// `${x%.*}` strip-decimal-suffix behaviour.
public enum LimitIndicator: Sendable, Equatable {
    /// Usage limit is exhausted (`utilization` truncated to 100). Shows ❌.
    case critical
    /// Usage is ahead of pace near the cap — truncated usage > 90 and time ≤ 90. Shows ⚠️.
    case warning
    /// Normal pacing state.
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

    /// Left edge of the gap zone = `min(usageFraction, timeFraction)`.
    public var gapStart: Double { min(usageFraction, timeFraction) }
    /// Right edge of the gap zone = `max(usageFraction, timeFraction)`.
    public var gapEnd: Double   { max(usageFraction, timeFraction) }

    /// Whether this bar is "calm" — its rendered gap colour is **green or yellow**, i.e. pacing is
    /// not yet worth flagging. The menu bar uses this to drop the reset-countdown label when *both*
    /// bars are calm (removing visual noise while everything is fine); the label returns as soon as
    /// either bar turns orange or red (`MenuBarLayout.make`, ADR-0028).
    ///
    /// Mirrors the colour grading in `PopupBarView.aheadColor` (which lives in the AppKit layer and
    /// cannot be imported here), so the thresholds are duplicated deliberately:
    /// - `.onPaceOrBehind` (`usage <= time`) → **green** → calm.
    /// - ahead (`usage > time`): **red** when `usageFraction >= 1` (limit exhausted) → not calm;
    ///   **yellow** when `(usageFraction - timeFraction) < 0.15` → calm; else **orange** → not calm.
    ///
    /// The `< 0.15` boundary is strict (no epsilon), matching the integer-percent contract of
    /// `limitIndicator`: exactly 15 points ahead is orange, not yellow.
    public var isCalm: Bool {
        pacing == .onPaceOrBehind || (usageFraction < 1 && (usageFraction - timeFraction) < 0.15)
    }
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

    /// Severity tier from usage vs. elapsed-time pacing.
    ///
    /// **Port of `get_limit_indicator`** (lines 74–87 of `statusline.sh`). Both inputs
    /// are truncated to integers before comparison, matching bash's `${x%.*}` string-strip
    /// of the decimal suffix:
    /// - `Int(max(0, utilization))  == 100` → `.critical`
    /// - `Int(max(0, utilization))   > 90` **and** `Int(max(0, timePercent)) ≤ 90` → `.warning`
    /// - otherwise → `.neutral`
    ///
    /// **Precision contract:** `99.9999` truncates to `99`, so it is NOT `.critical`.
    /// Do not add an epsilon tolerance — that would diverge from bash's behaviour.
    ///
    /// - Parameters:
    ///   - utilization: API `utilization` field, a percent in [0, 100] (e.g. `13.0`).
    ///     Must be finite and ≥ 0.
    ///   - timePercent: Elapsed-time percent in [0, 100] (e.g. `elapsedFraction * 100`).
    ///     Must be finite and ≥ 0.
    public static func limitIndicator(utilization: Double, timePercent: Double) -> LimitIndicator {
        let usageInt = Int(max(0, utilization))   // truncation toward zero == floor for x ≥ 0
        let timeInt  = Int(max(0, timePercent))
        if usageInt == 100 { return .critical }
        if usageInt > 90 && timeInt <= 90 { return .warning }
        return .neutral
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
        let timeFraction  = elapsedFraction(resetsAt: resetsAt, now: now, window: window)
        let pacing: PacingState = timeFraction >= usageFraction ? .onPaceOrBehind : .ahead
        return BarLayout(usageFraction: usageFraction, timeFraction: timeFraction, pacing: pacing)
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
