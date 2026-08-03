import Foundation

// MARK: - PacingBucket

/// The **objective** five-way pacing colour a bar would show — `blue`/`green`/`yellow`/`orange`/`red`
/// — computed purely from a ``BarLayout``, independent of the user's cosmetic colour settings.
///
/// This exists for the usage journal (#242), where each window stores the colour tier it *paces* at.
/// Two deliberate departures from what the live UI paints:
///
/// 1. **No `CalmColorMode` muting.** The menu bar can mute calm colours to white or disable the blue
///    (`farBehind`) zone (``CalmColorMode``, ``FarBehindInterval``). The journal records the bucket a
///    "control-freak" viewer would see — every colour on, blue always in play — so the series stays
///    comparable regardless of what any one user turned off. The single exception is the green↔blue
///    threshold, which is always evaluated at the shipped **medium** width (2 h for the 5h window,
///    3 d for the 7d — ``PacingModel/behindThreshold(windowDurationSeconds:multiplier:)`` at
///    `multiplier: 2`), never `off`.
///
/// 2. **Green vs yellow is split.** ``BarLayout/severity`` collapses both into `.calm`; the actual
///    colour split lives in the AppKit `aheadColor`/`behindColor`. This type restates that split so
///    the journal can distinguish "mildly behind" (green) from "mildly ahead" (yellow).
///
/// The thresholds are the shared ``PacingModel/aheadThreshold(timeFraction:)`` /
/// ``PacingModel/behindThreshold(windowDurationSeconds:multiplier:)`` (the same formulas the render
/// layer uses), so this never drifts from the pixels.
public enum PacingBucket: String, Sendable, Equatable, Codable, CaseIterable {
    /// Deep behind pace / big surplus (behind by `>` the 2 h / 3 d medium threshold, past the 20-min
    /// start override). Renders blue on the menu bar unless the user disabled the blue zone.
    case blue
    /// On pace or mildly behind — surplus within the behind-threshold, or the first 20 min.
    case green
    /// Mildly ahead — a lead below the dynamic ahead-threshold.
    case yellow
    /// Ahead by `≥` the dynamic threshold, or the window resets in `≤ 20 min` (not yet exhausted).
    case orange
    /// The limit is exhausted (`usageFraction >= 1`) — the window is blocked until it resets.
    case red

    /// The medium ``FarBehindInterval`` multiplier the objective bucket always evaluates the
    /// green→blue crossover at — the shipped default, so a user who turned blue *off* or *up* does
    /// not change what the journal records.
    private static let controlFreakBehindMultiplier = 2

    /// The objective bucket for a bar, restating the `aheadColor`/`behindColor` split with the
    /// green→blue threshold pinned to the medium width (see the type doc).
    ///
    /// `layout.behindMultiplier` is **ignored** — the journal must not vary with the user's
    /// `FarBehindInterval` — so the surplus side is recomputed at the medium multiplier.
    public static func of(_ layout: BarLayout) -> PacingBucket {
        // Ahead side (usage > time): red if exhausted, orange near the reset, else yellow/orange by the
        // dynamic ahead-threshold. Mirrors `PopupViewController.aheadColor`.
        if layout.pacing == .ahead {
            if layout.usageFraction >= 1 { return .red }
            if layout.remainingSeconds <= PacingModel.pacingOrangeOverrideSeconds { return .orange }
            let lead = layout.usageFraction - layout.timeFraction
            return lead < PacingModel.aheadThreshold(timeFraction: layout.timeFraction) ? .yellow : .orange
        }
        // On-pace/behind side (time >= usage): exhaustion still wins (a just-reset 100 % window can read
        // as on-pace), then green/blue by the fixed-width behind-threshold at the medium multiplier.
        if layout.usageFraction >= 1 { return .red }
        let elapsed = Double(layout.windowDurationSeconds) - layout.remainingSeconds
        if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return .green }   // 20-min start override
        let surplus = layout.timeFraction - layout.usageFraction
        let threshold = PacingModel.behindThreshold(
            windowDurationSeconds: layout.windowDurationSeconds,
            multiplier: controlFreakBehindMultiplier)
        return surplus > threshold ? .blue : .green
    }
}
