import Foundation

// MARK: - CreditsPacing

/// Pure, AppKit-free pacing logic for the money-credits ("extra usage") state (#143).
///
/// Turns a decoded ``SpendInfo`` into the two decisions the credits icon needs — **whether to show
/// it** and **how to pace its colour** — without importing the view palette (ADR-0009). The menu bar
/// / dropdown (#144/#145) map the resulting ``BarLayout`` to a colour with the **same**
/// `PopupBarView.aheadColor(usage:time:)` used for the token bars, and format the amount label; this
/// type owns only the arithmetic.
///
/// ## Credits pace exactly like a token limit — usage vs. time
/// The maintainer's rule: the credits icon colour is computed **the same way as the 5h/7d bars**, not
/// with a bespoke "percent of the cap" threshold. That means a `usage`-vs-`time` gap, feeding the same
/// ``BarLayout`` the token bars use, so `aheadColor` grades it identically:
/// green (on pace / behind) → yellow (mildly ahead) → orange (well ahead) → **red only at the cap**.
///
/// The two axes for credits:
/// - **`usageFraction` = `used_credits / limit`** — the share of the money cap spent.
/// - **`timeFraction` = the share of the calendar month elapsed** — the money window is the calendar
///   month, resetting at **00:00 UTC on the 1st** (confirmed via Anthropic's Spend Limits API docs;
///   the web UI's "Resets Aug 1"). The API delivers **no** `resets_at` for spend (spike #142:
///   `spend`/`extra_usage` carry no time field, `daily`/`weekly` are null), so we derive the month
///   fraction locally in UTC (see ``monthElapsedFraction(now:timeZone:)`` and ``resetTimeZone``).
///
/// ## Decisions the maintainer already made (spike #142, do not revisit here)
/// - The icon trigger is `enabled == true` **OR** `spend_limit_reached == true` — never `enabled`
///   alone, because the server flips `enabled` to false at the exact moment the cap is hit.
/// - The colour comes from the **same** `usage`-vs-`time` pacing as the token bars — never the server
///   `spend.severity`. Red appears **only** at the cap (`used >= limit` or `spend_limit_reached`),
///   matching `aheadColor`'s `usage >= 1 → red` rung; being "ahead of pace" is yellow/orange, not red.
public enum CreditsPacing {

    // MARK: - Trigger

    /// Whether the credits mechanism is **active** — the first half of the icon-show trigger.
    ///
    /// `true` when credits are enabled **or** the money cap has been reached. The `OR` is
    /// load-bearing: when the cap is exceeded the server sends `enabled: false` +
    /// `spend_limit_reached: true`, so testing `enabled` alone would drop the icon precisely when the
    /// user has hit their money ceiling. See spike #142.
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

    /// Whether credits are **actively being spent right now** — the stricter predicate behind the popup's
    /// blue "active" badge (#146).
    ///
    /// Differs from ``shouldShowIcon(_:baseLimitExhausted:)`` in the over-limit case: the icon shows
    /// even when the money cap is hit (red, "you've hit the ceiling"), but the **badge must not** — once
    /// `spend_limit_reached`, the server has set `enabled: false` and credits are **no longer covering**
    /// anything (Claude is blocked until the limit resets). So "actively spending" requires credits to be
    /// **enabled and not yet capped**, on top of a base limit being exhausted (otherwise nothing is
    /// overflowing into credits):
    /// - `enabled == true` **and** `spend_limit_reached == false` **and** `baseLimitExhausted`.
    public static func isSpending(_ spend: SpendInfo, baseLimitExhausted: Bool) -> Bool {
        spend.enabled && !spend.spendLimitReached && baseLimitExhausted
    }

    /// Whether paid credits can **still cover** new work — the money escape hatch that keeps an
    /// exhausted plan limit from actually blocking you (#158).
    ///
    /// `true` only when a `spend` block is present, credits are **enabled**, and the money cap is **not
    /// yet reached** (`spend_limit_reached == false`). This is deliberately the base-limit-agnostic
    /// half of ``isSpending(_:baseLimitExhausted:)``: the caller (idle-blocked detection) already knows
    /// the plan limit is exhausted, and asks only "is there paid headroom left to keep working?".
    ///
    /// A `nil` spend (pre-credits payload / no money window) is **not** cover — there is no paid tier
    /// in play. Once `spend_limit_reached`, the server flips `enabled` to false and credits stop
    /// covering anything, so both flags gate this together.
    public static func creditsCanCover(_ spend: SpendInfo?) -> Bool {
        guard let spend else { return false }
        return spend.enabled && !spend.spendLimitReached
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

    /// Whether one of the **two main windows that actually gate work** — `five_hour` or `seven_day` — is
    /// exhausted (`utilization >= 100`). This is the exhaustion notion for **blocking**, deliberately
    /// narrower than ``anyBaseLimitExhausted(in:)``:
    ///
    /// - **Per-model sub-windows do NOT gate work.** A model at 100 % (`sevenDayOpus` / `sevenDaySonnet`
    ///   / a `weekly_scoped` entry) does not block — Claude gates only on `five_hour` / `seven_day`, then
    ///   extra-usage credits. `anyBaseLimitExhausted` counts sub-windows because it drives the credits
    ///   **icon**'s show gate (overflow into credits is worth surfacing there); blocking must not.
    /// - **Either main window blocks on its own.** `five_hour` at 100 % blocks even with `seven_day`
    ///   quota (you wait for the 5-hour reset), and vice-versa — hence `OR`, not `AND`.
    /// - **An idle 5h window is "ready to start", not exhausted.** When ``UsageSnapshot/sessionIdle`` the
    ///   5h window carries `utilization: 0` and no window exists yet; starting one is allowed, so only
    ///   `seven_day` can block in that state.
    public static func mainWindowExhausted(in snapshot: UsageSnapshot) -> Bool {
        let fiveHourExhausted = !snapshot.sessionIdle && snapshot.fiveHour.utilization >= 100
        return fiveHourExhausted || snapshot.sevenDay.utilization >= 100
    }

    /// Whether the user is **blocked** — no path left to do work right now (#158, #177). Blocked means
    /// every way to start/continue is closed:
    ///
    /// ```
    /// blocked = mainWindowExhausted  AND NOT creditsCanCover(spend)
    /// ```
    ///
    /// A main window (5h **or** 7d) is exhausted (see ``mainWindowExhausted(in:)`` — either one blocks on
    /// its own; per-model sub-windows do not block; an idle 5h is "ready to start") **and** paid credits
    /// cannot cover (`enabled` & not capped). A main window at 100 % with credits still covering is
    /// **not** blocked — work continues on the paid tier.
    ///
    /// This is the general predicate behind both the idle-blocked grey bar (`sessionIdle` case) and the
    /// red blocking-reset badge on an active exhausted state. The `sessionIdle` gate lives in the
    /// **consumers** (`PopupLayout` / `MenuBarLayout`), not here — this predicate is `true` for an active
    /// exhausted state too, which is exactly what the popup's red badge needs. It is the inverse of
    /// ``WorkAvailability/canWork(_:)``: both share ``mainWindowExhausted(in:)`` so the red badge and the
    /// "Back to work!" notification stay in lock-step.
    public static func isBlocked(in snapshot: UsageSnapshot) -> Bool {
        mainWindowExhausted(in: snapshot) && !creditsCanCover(snapshot.spend)
    }

    /// Whether a **subscription** limit (5h **or** 7d) is exhausted **while paid credits are still
    /// covering** the work — the "you can keep going, but only because you're paying for it" state (#193).
    ///
    /// ```
    /// subscriptionExhaustedWhileCovered = mainWindowExhausted  AND  creditsCanCover(spend)
    /// ```
    ///
    /// This is the deliberate **complement** of ``isBlocked(in:)`` on an exhausted main window: both start
    /// from ``mainWindowExhausted(in:)``, then split on whether credits can cover — `isBlocked` is the
    /// *cannot-cover* half (no path to work), this is the *can-cover* half (work continues, on the paid
    /// tier). The two are mutually exclusive and never both `true`.
    ///
    /// The popup surfaces this as a **red** countdown to the blocking subscription limit's reset — the
    /// moment the plan quota returns and credits stop being spent (#193). It is **not** blocked
    /// (``WorkAvailability/canWork(_:)`` is `true` here), so it drives no "Back to work!" edge and no idle
    /// grey bar — only the red reset badge on the exhausted token row.
    public static func subscriptionExhaustedWhileCovered(in snapshot: UsageSnapshot) -> Bool {
        mainWindowExhausted(in: snapshot) && creditsCanCover(snapshot.spend)
    }

    // MARK: - Pacing (usage vs. time — same as the token bars)

    /// The pacing bar for the credits icon, graded **exactly like a token limit** (usage vs. time), or
    /// `nil` when there is **no** cap to pace against (`limit == nil` / unlimited / zero limit) — the
    /// UI then shows the spent amount only, no bar/colour.
    ///
    /// Feeds the same ``BarLayout`` the 5h/7d bars use, so the view's `aheadColor(usage:time:)` grades
    /// it identically: green → yellow → orange → **red at the cap**. Built with the same rule as
    /// `PacingModel.barLayout`: `pacing = timeFraction >= usageFraction ? .onPaceOrBehind : .ahead`.
    ///
    /// `usageFraction` = `used / limit`; `timeFraction` = ``monthElapsedFraction(now:)``. When the cap
    /// is hit (`spend_limit_reached`, or `used >= limit`) `usageFraction` is forced to `1`, so the view
    /// renders it red via `aheadColor`'s `usage >= 1` rung even if the raw fraction rounds just under.
    ///
    /// - Parameters:
    ///   - spend: The decoded credits state.
    ///   - now: Current instant (inject for deterministic tests; do **not** call `Date()` here).
    ///   - timeZone: Wall-clock zone whose month boundaries define the window (see
    ///     ``monthElapsedFraction(now:timeZone:)`` for why this matters). Default ``resetTimeZone``
    ///     (UTC) — the zone the monthly spend limit actually resets in.
    public static func barLayout(
        for spend: SpendInfo,
        now: Date,
        timeZone: TimeZone = CreditsPacing.resetTimeZone
    ) -> BarLayout? {
        guard let rawUsage = spentFraction(of: spend) else { return nil }  // no cap → no pacing
        // At the cap, force a full bar so `aheadColor` shows red (`usage >= 1`) regardless of rounding.
        let usageFraction = spend.spendLimitReached ? 1 : min(1, max(0, rawUsage))
        let timeFraction = monthElapsedFraction(now: now, timeZone: timeZone)
        // Seconds until the month resets, for the 20-minute orange override (a month-end can be
        // < 20 min away). `monthEnd` returns nil only if the calendar can't resolve the boundary
        // (never in practice) — then leave the window "far" so only the dynamic threshold applies.
        let remaining = monthEnd(now: now, timeZone: timeZone)?.timeIntervalSince(now)
            ?? Double(LimitWindow.sevenDay.durationSeconds)
        let pacing: PacingState = timeFraction >= usageFraction ? .onPaceOrBehind : .ahead
        // Credits are out of the blue-zone scope: the money window is not a token limit, so "you are
        // far behind pace, push harder" is not advice that applies to spending. `blueAllowed: false`
        // states that in the model rather than relying on the render layer never setting `isBaseLimit`.
        // The window length is the 7-day one purely as a stable placeholder for the monthly window.
        return BarLayout(usageFraction: usageFraction, timeFraction: timeFraction,
                         pacing: pacing, remainingSeconds: remaining,
                         windowDurationSeconds: LimitWindow.sevenDay.durationSeconds,
                         blueAllowed: false)
    }

    /// The time zone the monthly spend limit resets in — **UTC**.
    ///
    /// Confirmed against Anthropic's official Spend Limits API docs: *"monthly spend resets at 00 UTC
    /// on the first of each calendar month"* (https://platform.claude.com/docs/en/manage-claude/spend-limits-api).
    /// This is a **calendar** month in UTC, not a billing anniversary and not the device's local zone —
    /// so, unlike the token windows (whose reset *time* `ResetClock` renders in the device's local
    /// zone), the money window's boundary is fixed to UTC. Injectable so tests are deterministic.
    public static let resetTimeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

    /// The fraction of the current **calendar month** that has elapsed, in `[0, 1]` — the money
    /// window's `timeFraction`, mirroring `PacingModel.elapsedFraction` but for a variable-length
    /// month rather than a fixed rolling window.
    ///
    /// The money limit resets at **00:00 UTC on the 1st of each calendar month** (see
    /// ``resetTimeZone``; the web UI's "Resets Aug 1"), and the API carries no reset time for it
    /// (spike #142), so we compute it locally: elapsed since the start of this UTC month divided by the
    /// month's full length.
    ///
    /// **Time zone is injected** (mirroring `ResetClock`) and defaults to ``resetTimeZone`` (UTC):
    /// "the 1st at 00:00" lands at a different instant per zone, shifting `timeFraction` by up to a
    /// day's worth around the month boundary, so the zone must match the actual reset zone. DST and
    /// month length (28–31 days) are handled by Foundation via the constructed `Calendar`. Degrades to
    /// `0` if boundaries can't be resolved (never crashes, never over-paces).
    public static func monthElapsedFraction(
        now: Date,
        timeZone: TimeZone = CreditsPacing.resetTimeZone
    ) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else {
            return 0
        }
        let total = nextMonth.timeIntervalSince(monthStart)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(monthStart)
        return min(1, max(0, elapsed / total))
    }

    /// The **instant** the current money window ends — `00:00` on the 1st of the *next* calendar
    /// month, in ``resetTimeZone`` (UTC) — i.e. the moment the monthly spend counter resets.
    ///
    /// The dropdown's "resets in Nd/Nh" line (#145) needs an actual `Date` to feed the shared
    /// relative-time formatter (`ResetClock.relativeRounded`), whereas ``monthElapsedFraction`` only
    /// yields the *fraction* elapsed. This is that fraction's numerator boundary made explicit: the
    /// same next-month `00:00` UTC computed in ``monthElapsedFraction`` (see ``resetTimeZone`` for why
    /// the reset is fixed to UTC, not the device zone). Returns `nil` only if the calendar can't
    /// resolve the boundary (never in practice) — the caller then simply omits the reset line.
    ///
    /// - Parameters:
    ///   - now: Current instant (inject for deterministic tests; do **not** call `Date()` here).
    ///   - timeZone: Wall-clock zone whose month boundary defines the reset. Default ``resetTimeZone``
    ///     (UTC) — the zone the monthly spend limit actually resets in.
    public static func monthEnd(
        now: Date,
        timeZone: TimeZone = CreditsPacing.resetTimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    /// The `used / limit` fraction (spent share of the money cap), or `nil` when there is **no**
    /// usable cap to pace against — `limit == nil` (unlimited) or a limit of zero minor units.
    ///
    /// Uses the exact integer ``Money`` values (`used.amount_minor / limit.amount_minor`) when both
    /// are present, falling back to the `extra_usage.used_credits` scalar for the numerator when
    /// `spend.used` is absent. The result is **not** clamped — a fraction `> 1` (spent past the cap)
    /// is meaningful; ``barLayout(for:now:calendar:)`` clamps it for rendering.
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
