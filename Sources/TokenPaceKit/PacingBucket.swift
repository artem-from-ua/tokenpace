import Foundation

// MARK: - PacingBucket

/// The **objective** five-way pacing colour a bar would show — `blue`/`green`/`yellow`/`orange`/`red`
/// — computed purely from a ``BarLayout``, independent of the user's cosmetic colour settings.
///
/// This exists for the usage journal (#242), where each window stores the colour tier it *paces* at.
/// Two deliberate departures from what the live UI paints:
///
/// 1. **No `ColorAdvice` muting.** The menu bar can mute the pacing bars' calm colours to white
///    (``ColorAdvice``; since ADR-0105 it reaches nothing else).
///    That is pure cosmetics — a viewer preference about how loud the widget should look — so the
///    journal records the bucket a "control-freak" viewer would see, every colour on, and the series
///    stays comparable regardless of what any one user turned off.
///
///    Note what is **not** an exception any more: ``BarLayout/blueAllowed`` **is** honoured. It is not
///    a cosmetic setting but an objective fact about the data — whether the advice "the week has room
///    you are not using" is true, addressed to someone, and meaningful at all (the three reasons on
///    ``BarLayout/blueAllowed``) — and the journal must record what was true.
///
/// 2. **Green vs yellow is split.** ``BarLayout/severity`` collapses both into `.calm`; the actual
///    colour split lives in the AppKit `aheadColor`/`behindColor`. This type restates that split so
///    the journal can distinguish "mildly behind" (green) from "mildly ahead" (yellow).
///
/// The thresholds are the shared ``PacingModel/aheadThreshold(timeFraction:)`` /
/// ``PacingModel/behindThreshold(windowDurationSeconds:multiplier:)`` (the same formulas the render
/// layer uses), so this never drifts from the pixels.
public enum PacingBucket: String, Sendable, Equatable, Codable, CaseIterable {
    /// Deep behind pace / big surplus (behind by `>` the 2 h / 2 d threshold, past the 20-min start
    /// override, and only when ``BarLayout/blueAllowed`` — the bar is one whose blue would say
    /// something true and actionable about the week).
    case blue
    /// On pace or mildly behind — surplus within the behind-threshold, or the first 20 min.
    case green
    /// Mildly ahead — a lead below the dynamic ahead-threshold.
    case yellow
    /// Ahead by `≥` the dynamic threshold, or the window resets in `≤ 20 min` (not yet exhausted).
    case orange
    /// The limit is exhausted (`usageFraction >= 1`) — the window is blocked until it resets.
    case red

    /// The objective bucket for a bar, restating the `aheadColor`/`behindColor` split (see the type
    /// doc). Reads ``BarLayout/blueAllowed`` off the layout, exactly as the render layer does, so the
    /// recorded bucket and the pixel the user saw cannot disagree.
    ///
    /// That last clause used to be a hope rather than a guarantee. The popup carried a **second** gate
    /// the model knew nothing about — `PopupBarView.isBaseLimit`, which forced per-model rows green
    /// whatever the layout said — so this function faithfully returned `.blue` for scoped windows the
    /// user was looking at in green. It now holds by construction: the per-model rule lives on
    /// ``BarLayout/blueAllowed`` (reason 2 there), the view-side gate is gone, and both sides read the
    /// one field.
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
        if !layout.blueAllowed { return .green }                                     // blue not on offer here
        let elapsed = Double(layout.windowDurationSeconds) - layout.remainingSeconds
        if elapsed <= PacingModel.pacingBlueStartOverrideSeconds { return .green }   // 20-min start override
        let surplus = layout.timeFraction - layout.usageFraction
        let threshold = PacingModel.behindThreshold(windowDurationSeconds: layout.windowDurationSeconds)
        return surplus > threshold ? .blue : .green
    }
}
