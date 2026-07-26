import Foundation

// MARK: - LimitRow

/// One section of the popup: a named limit window with its pacing, a drawable bar, and a split
/// reset countdown. The pure-data side of issue #11 — no AppKit, no human-readable sentences (the
/// view assembles "% used · on pace · resets in …"). Reset *time* strings are the one exception:
/// they are produced by `ResetClock` (shared time arithmetic, reused in Phase 2), not localised
/// prose, so they live here rather than in the view.
///
/// Used for every kind of section — `5h`, `7d`, the per-model sub-windows (`Opus`, `Sonnet`),
/// and the `weekly_scoped` models from `limits[]` (e.g. `Fable`, #65); all per-model rows are
/// paced as `.sevenDay` (they reset on the weekly cadence).
public struct LimitRow: Sendable, Equatable {
    /// Section heading, e.g. `"5-hour"`, `"7-day"`, or a bare model name `"Opus"` / `"Fable"` for the
    /// per-model rows (all 7-day paced; no "(7-day)" suffix). A raw label (the window identity), not a
    /// localised string — the view renders it as-is.
    public let title: String
    /// API `utilization`, percent in [0, 100].
    public let utilization: Double
    /// Pacing relative to the elapsed window (`PacingModel.barLayout(...).pacing`).
    public let pacing: PacingState
    /// Severity tier (`PacingModel.limitIndicator`).
    public let indicator: LimitIndicator
    /// Continuous bar geometry for drawing the pacing bar (same `BarLayout` the menu bar draws).
    public let bar: BarLayout
    /// Number of equal sub-intervals the popup bar's tick ruler splits this window into
    /// (`LimitWindow.subdivisions`): `5` for the 5-hour window, `7` for the 7-day and per-model
    /// windows. The view draws `subdivisions - 1` interior ticks (issue #38).
    public let subdivisions: Int
    /// Always-shown relative countdown — `"20m"`, `"3d"`, `"1h30m"` — or `nil` when the reset is
    /// now/past or `resets_at` was unparseable (the view shows a stale signal).
    public let resetRelative: String?
    /// Absolute wall-clock `"10:30"` — present **only when the reset is < 24 h away** (the view
    /// appends "at 10:30"); `nil` for far-off resets where a clock time is noise.
    public let resetAbsolute: String?
    /// Local weekday name `"Monday"` — the far-reset counterpart of ``resetAbsolute``: present **only
    /// for 7-day windows whose reset is ≥ 24 h away** (the view appends "on Monday"), so a reset days
    /// out names the day it lands on. `nil` for 5-hour windows and for any reset < 24 h away (which
    /// carries ``resetAbsolute`` instead). At most one of the two is ever non-`nil`.
    public let resetWeekday: String?
    /// Whether this is the **idle** 5-hour row — the 5h window does not exist server-side (no active
    /// session, ``UsageSnapshot/sessionIdle``, #100). When `true` the view renders a solid-blue knobless
    /// bar, the status word "ready to start", and **no second (utilization + reset) line at all**; the
    /// numeric fields (`utilization`, `pacing`, `indicator`, the three `reset*`) are inert placeholders
    /// the idle render path ignores. `false` on every normal row.
    public let sessionIdle: Bool

    public init(
        title: String,
        utilization: Double,
        pacing: PacingState,
        indicator: LimitIndicator,
        bar: BarLayout,
        subdivisions: Int,
        resetRelative: String?,
        resetAbsolute: String?,
        resetWeekday: String? = nil,
        sessionIdle: Bool = false
    ) {
        self.title = title
        self.utilization = utilization
        self.pacing = pacing
        self.indicator = indicator
        self.bar = bar
        self.subdivisions = subdivisions
        self.resetRelative = resetRelative
        self.resetAbsolute = resetAbsolute
        self.resetWeekday = resetWeekday
        self.sessionIdle = sessionIdle
    }
}

// MARK: - CreditsRow

/// The "Extra usage" (money-credits) section of the popup — the pure-data counterpart of
/// ``LimitRow`` for the paid overspend that covers you past the plan limits (#143/#145).
///
/// Like ``LimitRow`` it carries **raw** values only — money objects, a drawable ``BarLayout``, and a
/// pre-formatted relative reset string (`ResetClock`, the one prose exception) — and **no**
/// human-readable sentences: the view (`PopupViewController`) assembles "on pace / ahead / limit
/// reached" and "€spent / €limit" from these (ADR-0009). It is a **separate** field on
/// ``PopupLayout`` (not one of ``PopupLayout/rows``) because a credits section is not a limit window:
/// it has no utilisation percent, no tick subdivisions, and its "cap" may be absent (unlimited).
///
/// ## Two shapes, keyed by ``bar``
/// - **Limit set** (`bar != nil`): a full section — status word (from `bar.pacing` / cap-reached),
///   `spent / limit`, a pacing bar, and a "resets in Nd/Nh" line (``resetRelative``).
/// - **Unlimited** (`bar == nil`, ``limit`` is `nil`): a bare "Extra usage … €spent spent" line —
///   no cap to pace against, so no bar, no status word, no reset (``resetRelative`` is `nil`).
public struct CreditsRow: Sendable, Equatable {
    /// The exact amount spent this money window (`spend.used`, e.g. €10.77) — always present. The view
    /// formats the label from the integer minor units + exponent + currency, never a rounded `Double`.
    public let spent: Money
    /// The money cap (`spend.limit`), or `nil` when the monthly limit is **unlimited**. `nil` ⇒
    /// ``bar`` is also `nil` (nothing to pace) and the view shows the spent-only line.
    public let limit: Money?
    /// The pacing bar (`CreditsPacing.barLayout`), graded exactly like a token bar (usage vs. month
    /// elapsed), or `nil` for an **unlimited** limit — then the view draws no bar and no status word.
    /// The view colours it with the **same** `PopupBarView.aheadColor(usage:time:)` the token bars use.
    public let bar: BarLayout?
    /// The rounded relative countdown to the end of the money window — the next `00:00` UTC on the 1st
    /// (`CreditsPacing.monthEnd` → `ResetClock.relativeRounded`), e.g. `"6d"` / `"3h"`. `nil` when the
    /// limit is unlimited (no reset line) or the boundary was unresolvable. Unlike ``LimitRow`` the
    /// money window is always days-to-weeks out, so there is no absolute-clock/weekday counterpart.
    public let resetRelative: String?

    public init(spent: Money, limit: Money?, bar: BarLayout?, resetRelative: String?) {
        self.spent = spent
        self.limit = limit
        self.bar = bar
        self.resetRelative = resetRelative
    }
}

// MARK: - PopupLayout

/// The pure, AppKit-free model of the click-to-open popup for one usage snapshot — the testable
/// core behind `PopupViewController` (issue #11).
///
/// Mirrors `MenuBarLayout` (#10): `make(...)` is **stateless and deterministic** (`now`,
/// `lastUpdate`, `interval` are injected) and adds **no new pacing arithmetic** — it reuses
/// `PacingModel` and `ResetClock`. The struct computes *what* to show; the thin `NSViewController`
/// shell in `TokenPace` does *how* (ADR-0009).
///
/// The service-line values (`lastUpdateAge`, `intervalSeconds`) are **raw seconds** — the view
/// formats them ("just now", "3m") so a future localisation touches only the view.
///
/// Issue #12 adds ``warning``: when a poll is failing, the popup shows a two-line banner
/// **immediately** (no 30-min threshold — that gate is the menu bar's, not the popup's), above the
/// possibly-stale ``rows``. A healthy layout leaves it `nil`.
public struct PopupLayout: Sendable, Equatable {
    /// Age of the last successful 200, in seconds (clamped ≥ 0). Drives "Last update: …".
    public let lastUpdateAge: TimeInterval
    /// Current polling interval in seconds (`PollingBackoff.interval`). Drives "Update interval: …".
    public let intervalSeconds: TimeInterval
    /// The limit sections, in display order: `5h`, `7d`, then any present per-model rows —
    /// legacy sub-windows (`Opus`, `Sonnet`) first, then `weekly_scoped` models from `limits[]`
    /// (e.g. `Fable`). Absent models are simply not in the array (null-safe). Empty on a
    /// cold-start failure (no snapshot yet — the warning stands alone).
    public let rows: [LimitRow]
    /// The current failure cause when a poll is failing, else `nil`. Drives the popup warning banner
    /// (issue #12); the view turns it into the two-line title/detail (the localisation seam).
    public let warning: FailureReason?
    /// The Claude service status (two component states), or `nil` until the first status poll has
    /// succeeded (issue #31). When `nil`, the view shows **no** status lines (cold start); otherwise
    /// it renders one line per component with a colour dot and a linked status word — the view is
    /// the localisation/colour seam, this layer carries only the semantic ``ServiceStatus`` values.
    /// Independent of `warning`: the usage poll and the status poll fail and succeed separately.
    public let serviceStatus: StatusHealth?
    /// The "Extra usage" money-credits section (#145), or `nil` when credits are inactive for this
    /// snapshot (`snapshot.spend == nil` or `!CreditsPacing.isActive`). A **separate** field from
    /// ``rows`` — a credits section is not a limit window (see ``CreditsRow``). The view renders it as
    /// its own "Extra usage" block below the limit rows.
    public let credits: CreditsRow?

    public init(
        lastUpdateAge: TimeInterval,
        intervalSeconds: TimeInterval,
        rows: [LimitRow],
        warning: FailureReason? = nil,
        serviceStatus: StatusHealth? = nil,
        credits: CreditsRow? = nil
    ) {
        self.lastUpdateAge = lastUpdateAge
        self.intervalSeconds = intervalSeconds
        self.rows = rows
        self.warning = warning
        self.serviceStatus = serviceStatus
        self.credits = credits
    }

    // MARK: make

    /// Build the popup layout from one usage snapshot at instant `now`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - lastUpdate: Instant of the last successful 200 (→ `lastUpdateAge`). Mock today; real with #13.
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`). Mock today.
    public static func make(
        from snapshot: UsageSnapshot,
        now: Date,
        lastUpdate: Date,
        interval: TimeInterval
    ) -> PopupLayout {
        let rows = self.rows(from: snapshot, now: now)
        return PopupLayout(
            lastUpdateAge: max(0, now.timeIntervalSince(lastUpdate)),
            intervalSeconds: interval,
            rows: rows,
            credits: self.creditsRow(from: snapshot, now: now)
        )
    }

    // MARK: make (health-aware, issue #12)

    /// Build the popup from the last known snapshot **and** the polling health.
    ///
    /// The entry point the live loop (#13) calls. Unlike the menu bar's staged thresholds, the popup
    /// warns the moment a failure is in progress (SPEC: "за будь-якої непрацюючої авторизації …
    /// одразу"):
    /// - ``warning`` = `health.reason` whenever `health.isFailing`, else `nil`.
    /// - ``lastUpdateAge`` is measured from `health.lastSuccess` so the service line shows how stale
    ///   the data is (clamped `≥ 0`; `0` on a cold start where there is no last success).
    /// - ``rows`` come from the last known `snapshot` (stale data, shown with its timestamp), or are
    ///   empty on a cold-start failure (no snapshot yet — the warning stands alone).
    ///
    /// - Parameters:
    ///   - snapshot: The last successfully decoded poll, or `nil` if none has ever succeeded.
    ///   - health: The polling-health context (last success, failure start, reason).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`).
    ///   - serviceStatus: The latest Claude service status (issue #31), or `nil` until the first
    ///     status poll has succeeded (the status loop is independent of the usage poll). Threaded
    ///     through unchanged — the view renders it.
    public static func make(
        from snapshot: UsageSnapshot?,
        health: UsageHealth,
        now: Date,
        interval: TimeInterval,
        serviceStatus: StatusHealth? = nil
    ) -> PopupLayout {
        let rows = snapshot.map { self.rows(from: $0, now: now) } ?? []
        let lastUpdateAge = health.lastSuccess.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let warning = health.isFailing ? health.reason : nil
        let credits = snapshot.flatMap { self.creditsRow(from: $0, now: now) }
        return PopupLayout(
            lastUpdateAge: lastUpdateAge,
            intervalSeconds: interval,
            rows: rows,
            warning: warning,
            serviceStatus: serviceStatus,
            credits: credits
        )
    }

    // MARK: - Private

    /// The ordered limit sections for a snapshot: `5h`, `7d`, then any present per-model rows —
    /// the legacy top-level sub-windows (`Opus`/`Sonnet`, null-safe) followed by the
    /// `weekly_scoped` models from `limits[]` (e.g. `Fable`, #65; already deduped against the
    /// legacy rows by ``UsageSnapshot/scopedModelWindows``). All per-model rows are paced as
    /// `.sevenDay`. Shared by both ``make`` overloads.
    private static func rows(from snapshot: UsageSnapshot, now: Date) -> [LimitRow] {
        // The 5-hour row is the idle placeholder when the window has no active session (#100); every
        // other row is built normally, including the 7-day one (which always exists).
        var rows: [LimitRow] = [
            snapshot.sessionIdle ? idleFiveHourRow() : row(title: "5-hour", window: snapshot.fiveHour, as: .fiveHour, now: now),
            row(title: "7-day", window: snapshot.sevenDay, as: .sevenDay, now: now),
        ]
        if let opus = snapshot.sevenDayOpus {
            rows.append(row(title: "Opus", window: opus, as: .sevenDay, now: now))
        }
        if let sonnet = snapshot.sevenDaySonnet {
            rows.append(row(title: "Sonnet", window: sonnet, as: .sevenDay, now: now))
        }
        for scoped in snapshot.scopedModelWindows {
            rows.append(row(title: scoped.name, window: scoped.window, as: .sevenDay, now: now))
        }
        return rows
    }

    /// Build the "Extra usage" money-credits section from a snapshot's ``UsageSnapshot/spend``, or
    /// `nil` when credits are inactive for this snapshot.
    ///
    /// ## Show gate — deliberately softer than the menu-bar icon's
    /// The menu-bar credits **icon** shows only when `CreditsPacing.shouldShowIcon` holds — credits
    /// active **and** a base limit exhausted (a glanceable badge should be quiet until the paid tier is
    /// actually in play). The **dropdown** is the detail view the user has explicitly opened, so the
    /// gate is only ``CreditsPacing/isActive(_:)`` (`enabled` **or** `spend_limit_reached`): once
    /// credits are switched on, showing the amount spent is useful even before a plan limit is spent.
    /// We do **not** additionally require `baseLimitExhausted` here (that stays the icon's concern).
    ///
    /// ## Shape
    /// - `spent` is `spend.used` (exact ``Money``); when absent, it is reconstructed from the
    ///   `used_credits` scalar + `currency` / `decimal_places` so the line always has an amount.
    /// - `bar` is `CreditsPacing.barLayout` — `nil` for an unlimited limit (view shows spent-only).
    /// - `resetRelative` is the rounded countdown to `CreditsPacing.monthEnd` (next `00:00` UTC on the
    ///   1st), and is `nil` when the limit is unlimited (no cap ⇒ no reset line).
    private static func creditsRow(from snapshot: UsageSnapshot, now: Date) -> CreditsRow? {
        guard let spend = snapshot.spend, CreditsPacing.isActive(spend) else { return nil }
        let spent = spentMoney(from: spend)
        let bar = CreditsPacing.barLayout(for: spend, now: now)
        // A reset line only makes sense when there is a cap to reset against (bar != nil ⇔ limited).
        let resetRelative = bar == nil
            ? nil
            : CreditsPacing.monthEnd(now: now).flatMap { ResetClock.relativeRounded(resetsAt: $0, now: now) }
        return CreditsRow(spent: spent, limit: spend.limit, bar: bar, resetRelative: resetRelative)
    }

    /// The amount spent as a ``Money``, preferring the exact `spend.used` object and falling back to a
    /// reconstructed `Money` from the `extra_usage` scalars (`used_credits` minor units + `currency` +
    /// `decimal_places`) so a payload that carries only the `extra_usage` half still yields an amount.
    /// Last-ditch fallback is a zero in the credits `currency` (or empty) — the section still renders.
    private static func spentMoney(from spend: SpendInfo) -> Money {
        if let used = spend.used { return used }
        let currency = spend.currency ?? spend.limit?.currency ?? ""
        let exponent = spend.decimalPlaces ?? spend.limit?.exponent ?? 2
        let minor = spend.usedCredits.map { Int($0.rounded()) } ?? 0
        return Money(amountMinor: minor, currency: currency, exponent: exponent)
    }

    /// The idle 5-hour placeholder row (#100, ADR-0027): title `"5-hour"`, `sessionIdle: true`, all
    /// reset strings `nil`, and an inert zeroed bar (the view fills it solid blue and skips the second
    /// line). `subdivisions` stays the 5-hour value so the under-bar tick ruler keeps the row's anatomy
    /// in family with the active rows; the numeric fields are placeholders the idle render path ignores.
    private static func idleFiveHourRow() -> LimitRow {
        LimitRow(
            title: "5-hour",
            utilization: 0,
            pacing: .onPaceOrBehind,
            indicator: .neutral,
            bar: BarLayout(usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind),
            subdivisions: LimitWindow.fiveHour.subdivisions,
            resetRelative: nil,
            resetAbsolute: nil,
            resetWeekday: nil,
            sessionIdle: true)
    }

    /// Build one `LimitRow`, delegating all arithmetic to tested pure logic. An unparseable
    /// `resets_at` falls back to `now` for the bar geometry (→ `elapsedFraction == 1.0`, matching
    /// `MenuBarLayout`) and to `nil` reset strings (the view shows a stale signal).
    private static func row(title: String, window: UsageWindow, as kind: LimitWindow, now: Date) -> LimitRow {
        let parsed = ResetClock.parse(window.resetsAt)
        let bar = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: parsed ?? now,
            now: now,
            window: kind
        )
        let indicator = PacingModel.limitIndicator(
            utilization: window.utilization,
            timePercent: bar.timeFraction * 100
        )
        let relative = parsed.flatMap { ResetClock.relativeRounded(resetsAt: $0, now: now) }
        let absolute = parsed.flatMap { ResetClock.absoluteWithin(resetsAt: $0, now: now) }
        // 7-day windows whose reset is a day or more out name the weekday they land on ("on Monday")
        // in place of the omitted clock time; 5-hour windows always reset within 24 h, so they only
        // ever carry the clock time (weekdayBeyond returns nil for them anyway, but scope it explicitly).
        let weekday = (kind == .sevenDay)
            ? parsed.flatMap { ResetClock.weekdayBeyond(resetsAt: $0, now: now) }
            : nil
        return LimitRow(
            title: title,
            utilization: window.utilization,
            pacing: bar.pacing,
            indicator: indicator,
            bar: bar,
            subdivisions: kind.subdivisions,
            resetRelative: relative,
            resetAbsolute: absolute,
            resetWeekday: weekday
        )
    }
}
