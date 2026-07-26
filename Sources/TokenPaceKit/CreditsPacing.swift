import Foundation

// MARK: - CreditsPacing

/// Pure, AppKit-free pacing logic for the money-credits ("extra usage") state (#143).
///
/// Turns a decoded ``SpendInfo`` into the two decisions the credits icon needs — **whether to show
/// it** and **which colour tier** — without importing the view palette (ADR-0009). The menu bar /
/// dropdown (#144/#145) map ``PacingSeverity`` to a colour and format the amount label; this type
/// owns only the arithmetic.
///
/// ## Why credits pace differently from a window
/// A rolling limit (5h/7d) paces **usage against elapsed time** — you can be "ahead" or "behind" the
/// clock. The money cap has **no time axis in scope**: `spend.balance` / `auto_reload` are not in
/// this endpoint (spike #142), so the base is the **limit alone**. Severity is therefore graded from
/// the plain `used / limit` fraction, not a usage-vs-time gap. When there is **no limit** (the user
/// set the monthly cap to *unlimited*, `spend.limit: null`) there is nothing to pace against — the
/// UI shows the spent amount only, with no bar and a neutral (``calm``) tier.
///
/// ## Decisions the maintainer already made (spike #142, do not revisit here)
/// - The icon trigger is `enabled == true` **OR** `spend_limit_reached == true` — never `enabled`
///   alone, because the server flips `enabled` to false at the exact moment the cap is hit.
/// - The colour is computed from **our own** `used / limit` thresholds, never the server
///   `spend.severity` tier.
public enum CreditsPacing {

    // MARK: - Trigger

    /// Whether the credits mechanism is **active** — the first half of the icon-show trigger.
    ///
    /// `true` when credits are enabled **or** the money cap has been reached. The `OR` is
    /// load-bearing: when the cap is exceeded the server sends `enabled: false` +
    /// `spend_limit_reached: true`, so testing `enabled` alone would drop the icon precisely when the
    /// user has hit their money ceiling (the ``PacingSeverity/exhausted`` state). See spike #142.
    ///
    /// This is **not** the full show decision on its own — the icon is additionally gated on at least
    /// one base limit being exhausted; see ``shouldShowIcon(_:baseLimitExhausted:)``.
    public static func isActive(_ spend: SpendInfo) -> Bool {
        spend.enabled || spend.spendLimitReached
    }

    /// Whether the credits icon should be shown.
    ///
    /// Two conditions must both hold:
    /// 1. credits are active — ``isActive(_:)`` (`enabled` OR `spend_limit_reached`);
    /// 2. at least one **base** limit (5h / 7d / weekly-scoped) is exhausted — credits only "kick in"
    ///    once a plan limit is spent, so there is nothing to surface before then.
    ///
    /// The base-limit predicate is passed in rather than derived here so the trigger stays a pure,
    /// one-line policy. ``anyBaseLimitExhausted(in:)`` computes a reasonable value from a snapshot's
    /// `utilization` signals; the final wiring into the menu-bar show/hide flow lands in #144.
    ///
    /// - TODO(#144): confirm this gate against the live menu-bar "expanded vs hidden" logic — the
    ///   base-limit source there may be richer (e.g. server `is_active` / `severity`) than the
    ///   `utilization >= 100` heuristic ``anyBaseLimitExhausted(in:)`` uses today.
    public static func shouldShowIcon(_ spend: SpendInfo, baseLimitExhausted: Bool) -> Bool {
        isActive(spend) && baseLimitExhausted
    }

    /// Heuristic "is any base limit exhausted?" from a snapshot's `utilization` values — `true` when
    /// any of `five_hour` / `seven_day` / the per-model sub-windows / the `weekly_scoped` entries has
    /// `utilization >= 100`.
    ///
    /// This lives here as the default source for ``shouldShowIcon(_:baseLimitExhausted:)`` so the
    /// trigger is testable end-to-end today, but the exhaustion signal is deliberately isolated as
    /// its own predicate (see the TODO on `shouldShowIcon`) — #144 may replace it with the menu bar's
    /// own notion of "limit hit". The server caps `utilization` at 100, so `>=` (not `>`) is correct.
    public static func anyBaseLimitExhausted(in snapshot: UsageSnapshot) -> Bool {
        let windows: [Double] =
            [snapshot.fiveHour.utilization, snapshot.sevenDay.utilization]
            + [snapshot.sevenDayOpus, snapshot.sevenDaySonnet].compactMap { $0?.utilization }
            + snapshot.scopedModelWindows.map(\.window.utilization)
        return windows.contains { $0 >= 100 }
    }

    // MARK: - Severity

    /// The colour tier for the credits icon, from **our own** `used / limit` thresholds — never the
    /// server `spend.severity` (maintainer decision, spike #142).
    ///
    /// Mirrors the grading of ``BarLayout/severity`` so the credits icon reads on the same scale as
    /// the pacing bars, adapted for an axis that has **no time component** (see the type doc):
    /// - ``PacingSeverity/exhausted`` (red) — the cap is hit: `spend_limit_reached == true` **or** the
    ///   `used / limit` fraction is `>= 1`. Mirrors `BarLayout`'s `usageFraction >= 1` rung.
    /// - ``PacingSeverity/ahead`` (orange) — within the last 15 points of the cap (`fraction >= 0.85`)
    ///   but not yet exhausted. Mirrors `BarLayout`'s strict 15-point boundary (there the gap between
    ///   the usage and time edges; here, with no time edge, the distance from the cap itself).
    /// - ``PacingSeverity/calm`` (green/yellow) — everything below, **and** the no-limit case: when
    ///   `limit == nil` there is nothing to pace against, so the tier is neutral (`calm`) and the UI
    ///   shows the spent amount only.
    ///
    /// The `>= 0.85` boundary is strict (no epsilon), matching the integer-percent contract of
    /// `BarLayout.severity` — exactly 85 % spent is `ahead`, 84 % is `calm`.
    public static func severity(for spend: SpendInfo) -> PacingSeverity {
        if spend.spendLimitReached { return .exhausted }
        guard let fraction = spentFraction(of: spend) else { return .calm }  // no limit → neutral
        if fraction >= 1 { return .exhausted }
        return fraction >= 0.85 ? .ahead : .calm
    }

    /// The `used / limit` fraction (spent share of the money cap), or `nil` when there is **no**
    /// usable cap to pace against — `limit == nil` (unlimited) or a limit of zero minor units.
    ///
    /// Uses the exact integer ``Money`` values (`used.amount_minor / limit.amount_minor`) when both
    /// are present, falling back to the `extra_usage.used_credits` scalar for the numerator when
    /// `spend.used` is absent. The result is **not** clamped — a fraction `> 1` (spent past the cap)
    /// is meaningful and drives the ``PacingSeverity/exhausted`` decision above.
    public static func spentFraction(of spend: SpendInfo) -> Double? {
        guard let limit = spend.limit, limit.amountMinor > 0 else { return nil }
        let usedMinor: Double
        if let used = spend.used {
            usedMinor = Double(used.amountMinor)
        } else if let credits = spend.usedCredits {
            usedMinor = credits   // `used_credits` is already in minor units (e.g. 1077.0 == €10.77)
        } else {
            return nil
        }
        return usedMinor / Double(limit.amountMinor)
    }
}
