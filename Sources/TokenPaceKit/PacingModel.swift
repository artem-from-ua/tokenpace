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
    /// The user's ``FarBehindInterval`` multiplier, mirrored onto the layout so ``severity`` (and the
    /// AppKit `behindColor`/`isFarBehind`, which read it off this struct) can scale the green→blue
    /// crossover width without re-reading config. **`0` means "off"** — the blue (`farBehind`) zone is
    /// disabled and the behind side stays green at any surplus; `1`/`2`/`3` scale the base 1h(5h)/1d(7d)
    /// width (see ``FarBehindInterval/multiplier``, whose `nil` maps to `0` here). Kept as a plain `Int`
    /// (not `Int?`) so the struct stays value-flat; the nil→0 mapping is `interval.multiplier ?? 0`.
    public let behindMultiplier: Int

    /// Left edge of the gap zone = `min(usageFraction, timeFraction)`.
    public var gapStart: Double { min(usageFraction, timeFraction) }
    /// Right edge of the gap zone = `max(usageFraction, timeFraction)`.
    public var gapEnd: Double   { max(usageFraction, timeFraction) }

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
            // `behindMultiplier == 0` (FarBehindInterval.off): blue is disabled — the behind side is
            // always plain green, regardless of surplus. behindThreshold returns +∞ for it, so the
            // strict `>` below can never fire, but short-circuit here for clarity.
            if behindMultiplier == 0 { return .calm }                                   // green (blue off)
            // 20-min start-of-window override: always plain green early on (blue must not flicker at
            // start). elapsed < 0 under clock skew (remaining > duration) also folds to green here.
            let elapsed = Double(windowDurationSeconds) - remainingSeconds
            if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return .calm }   // green
            return (timeFraction - usageFraction) > PacingModel.behindThreshold(windowDurationSeconds: windowDurationSeconds, multiplier: behindMultiplier)
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
    /// forces a countdown — see `MenuBarLayout.selectReset`.
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

    /// The green→blue (`.farBehind`) boundary for the on-pace/behind gap, as a **fixed span of real
    /// time** rather than a fraction of the window (unlike ``aheadThreshold(timeFraction:)``, which is
    /// dynamic). Returned as the fraction the pacing math compares against:
    /// `LimitWindow.blueBehindWidthSeconds × multiplier / windowDurationSeconds`. With the base 1h(5h)/
    /// 1d(7d) width, the default `multiplier = 2` (``FarBehindInterval/medium``) gives **2 h / 5 h = 0.40**
    /// (5h) and **2 d / 7 d ≈ 0.2857** (7d); `multiplier = 1` reproduces the old 0.20 / 0.1429 split, and
    /// `multiplier = 0` (``FarBehindInterval/off``) returns `+∞` so blue never appears.
    ///
    /// A surplus (`timeFraction − usageFraction`) at or below this stays green (`.calm`); a surplus
    /// strictly above it is blue (`.farBehind`). Being behind by more than an hour (5h) / a day (7d)
    /// means you have real, fixed headroom to push, independent of how far the window has elapsed.
    /// Shared by ``BarLayout/severity`` (Kit) and `PopupBarView.behindColor` (AppKit) so colour and
    /// severity never drift.
    ///
    /// The comparison side uses a strict `>` (a surplus exactly at the threshold is green — the louder
    /// of the two calm tones). A separate 20-min *start* override (``pacingBlueStartOverrideSeconds``)
    /// keeps the first 20 minutes green regardless of this.
    ///
    /// - Parameters:
    ///   - windowDurationSeconds: The window length (``LimitWindow/durationSeconds``: 18 000 for 5h,
    ///     604 800 for 7d), carried on ``BarLayout``. A non-positive value (inert placeholder bars)
    ///     returns `0` — any surplus reads as the calmer green, matching those bars' forced-calm intent.
    ///   - multiplier: The user's ``FarBehindInterval`` scale on the base 1h(5h)/1d(7d) width
    ///     (``BarLayout/behindMultiplier``): `1`/`2`/`3` widen the blue zone (base × multiplier), and
    ///     **`0` disables blue** by returning `.greatestFiniteMagnitude`, so the caller's strict `>`
    ///     comparison is always false (never blue). Defaults to `2` (the shipped ``FarBehindInterval/medium``).
    public static func behindThreshold(windowDurationSeconds: Int, multiplier: Int = 2) -> Double {
        guard multiplier > 0 else { return .greatestFiniteMagnitude }   // off → never blue
        guard windowDurationSeconds > 0 else { return 0 }
        let width = blueBehindWidthSeconds(forWindowDurationSeconds: windowDurationSeconds) * multiplier
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
    ///   - behindMultiplier: The user's ``FarBehindInterval`` scale for the green→blue crossover, stored
    ///     onto ``BarLayout/behindMultiplier`` (`0` = off/no-blue; `1`/`2`/`3` = ×base). Defaults to `2`
    ///     (``FarBehindInterval/medium``) so existing/synthetic callers keep the shipped look; the AppKit
    ///     layer must pass the **real** configured value (`interval.multiplier ?? 0`).
    public static func barLayout(
        utilization: Double,
        resetsAt: Date,
        now: Date,
        window: LimitWindow,
        behindMultiplier: Int = 2
    ) -> BarLayout {
        let usageFraction = min(1, max(0, utilization / 100))
        let remaining     = resetsAt.timeIntervalSince(now)   // seconds until reset (may be ≤ 0)
        let timeFraction  = elapsedFraction(resetsAt: resetsAt, now: now, window: window)
        let pacing: PacingState = timeFraction >= usageFraction ? .onPaceOrBehind : .ahead
        return BarLayout(usageFraction: usageFraction, timeFraction: timeFraction,
                         pacing: pacing, remainingSeconds: remaining,
                         windowDurationSeconds: window.durationSeconds,
                         behindMultiplier: behindMultiplier)
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
