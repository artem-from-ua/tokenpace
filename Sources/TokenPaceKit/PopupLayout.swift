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
    /// Exhausted flag (`PacingModel.limitIndicator`: `.critical` when the window is at 100 %).
    public let indicator: LimitIndicator
    /// Continuous bar geometry for drawing the pacing bar (same `BarLayout` the menu bar draws).
    public let bar: BarLayout
    /// Number of equal sub-intervals the popup bar's tick ruler splits this window into
    /// (`LimitWindow.subdivisions`): `5` for the 5-hour window, `7` for the 7-day and per-model
    /// windows. The view draws `subdivisions - 1` interior ticks (issue #38).
    public let subdivisions: Int
    /// The complete, unified reset line for this window (`ResetClock.resetLine`): `"15d"`,
    /// `"7d next Monday"`, `"5d on Friday"`, `"20h at 03:00"`, `"45m at 03:00"` — the same format
    /// every limit uses (#167). `nil` when the reset is now/past or `resets_at` was unparseable
    /// (the view shows its "resetting…" fallback).
    public let resetLine: String?
    /// Whether this is the **idle** 5-hour row — the 5h window does not exist server-side (no active
    /// session, ``UsageSnapshot/sessionIdle``, #100). When `true` the view renders a solid-blue knobless
    /// bar, the status word "ready to start", and **no second (utilization + reset) line at all**; the
    /// numeric fields (`utilization`, `pacing`, `indicator`, the three `reset*`) are inert placeholders
    /// the idle render path ignores. `false` on every normal row.
    public let sessionIdle: Bool
    /// Whether this idle 5-hour row is also **blocked** (#158): the 7-day limit is exhausted and paid
    /// credits cannot cover, so there is no path to start a session. When `true` the view draws the
    /// solid idle bar **grey** (not blue) and shows the status word "waiting for limit reset" instead
    /// of "ready to start". Only ever `true` alongside ``sessionIdle``; `false` on every other row.
    public let sessionBlocked: Bool

    public init(
        title: String,
        utilization: Double,
        pacing: PacingState,
        indicator: LimitIndicator,
        bar: BarLayout,
        subdivisions: Int,
        resetLine: String?,
        sessionIdle: Bool = false,
        sessionBlocked: Bool = false
    ) {
        self.title = title
        self.utilization = utilization
        self.pacing = pacing
        self.indicator = indicator
        self.bar = bar
        self.subdivisions = subdivisions
        self.resetLine = resetLine
        self.sessionIdle = sessionIdle
        self.sessionBlocked = sessionBlocked
    }
}

// MARK: - CreditsRow

/// The "Extra usage" (money-credits) section of the popup — the pure-data counterpart of
/// ``LimitRow`` for the paid overspend that covers you past the plan limits (#143/#145).
///
/// Like ``LimitRow`` it carries **raw** values only — money objects, a drawable ``BarLayout``, and a
/// pre-formatted reset line (`ResetClock`, the one prose exception) — and **no**
/// human-readable sentences: the view (`PopupViewController`) assembles "on pace / ahead / limit
/// reached" and "€spent / €limit" from these (ADR-0009). It is a **separate** field on
/// ``PopupLayout`` (not one of ``PopupLayout/rows``) because a credits section is not a limit window:
/// it has no utilisation percent, no tick subdivisions, and its "cap" may be absent (unlimited).
///
/// ## Two shapes, keyed by ``bar``
/// - **Limit set** (`bar != nil`): a full section — status word (from `bar.pacing` / cap-reached),
///   `spent / limit`, a pacing bar, and the unified reset line (``resetLine``).
/// - **Unlimited** (`bar == nil`, ``limit`` is `nil`): a bare "Extra usage … €spent spent" line —
///   no cap to pace against, so no bar, no status word, no reset (``resetLine`` is `nil`).
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
    /// The unified reset line to the end of the money window — the next `00:00` UTC on the 1st
    /// (`CreditsPacing.monthEnd` → `ResetClock.resetLine`), in the **same** format every limit uses
    /// (#167): `"15d"`, `"5d on Friday"`, `"20h at 03:00"`. The `00:00` UTC boundary reads as the
    /// user's **local** day/time. `nil` when the limit is unlimited (no reset line) or the boundary
    /// was unresolvable.
    public let resetLine: String?
    /// Whether paid credits are **actually being spent right now** — `enabled` **and** at least one base
    /// limit is exhausted (`CreditsPacing.shouldShowIcon`, the same gate as the menu-bar icon). Drives
    /// the blue **"in use"** badge next to the heading: the section itself shows whenever credits are
    /// merely *active* (enabled/reached), but the badge appears only while the plan limit is actually
    /// overflowing into credits.
    public let inUse: Bool

    public init(spent: Money, limit: Money?, bar: BarLayout?, resetLine: String?, inUse: Bool = false) {
        self.spent = spent
        self.limit = limit
        self.bar = bar
        self.resetLine = resetLine
        self.inUse = inUse
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
    /// Which one reset the view should highlight in **red** as the **blocking** reset — the reset that
    /// actually unblocks work. Set in two cases (#158, #193):
    /// - **Blocked** (no path to work: idle-blocked, or active with a main window exhausted and credits not
    ///   covering) — the "last stand" pick (`BlockingReset.forBlocked`), which may be the credits reset.
    /// - **Subscription-exhausted while credits cover** (`CreditsPacing.subscriptionExhaustedWhileCovered`,
    ///   #193) — the latest exhausted **token** reset (`BlockingReset.forSubscriptionExhausted`); never the
    ///   credits reset, since credits are the cover, not the blocker. Not blocked (work continues on the
    ///   paid tier), but the red badge marks when the plan quota returns and credits stop being spent.
    ///
    /// `nil` in every other state. When non-`nil`:
    /// - ``BlockingReset/Choice/token(id:resetsAt:)`` — `id` is the index into ``rows`` whose reset
    ///   line the view paints red;
    /// - ``BlockingReset/Choice/credits(resetsAt:)`` — the "Extra usage" section's reset line is painted
    ///   red instead.
    /// Exactly one reset is ever highlighted, even when several limits are simultaneously exhausted.
    public let blockingReset: BlockingReset.Choice?

    /// The Claude Code sessions awaiting user input to advertise flush-right in the "Claude" section
    /// header (#233, ADR-0066), or `nil` to draw nothing. `nil` whenever the feature is off, the count
    /// is `0`, or the watcher isn't running. When non-`nil` (count `≥ 1`) the popup draws a
    /// `hand.raised` icon tinted by ``AwaitingSessions/urgency``; a count of `1` shows the bare icon,
    /// `≥ 2` appends the count. Clicking the block opens the per-project breakdown
    /// (``AwaitingSessions/perProject``). Sourced by the shell from `AwaitingInputWatcher`,
    /// independent of the usage snapshot, so it's supplied to `make` rather than derived from it.
    public let awaitingInput: AwaitingSessions?

    public init(
        lastUpdateAge: TimeInterval,
        intervalSeconds: TimeInterval,
        rows: [LimitRow],
        warning: FailureReason? = nil,
        serviceStatus: StatusHealth? = nil,
        credits: CreditsRow? = nil,
        blockingReset: BlockingReset.Choice? = nil,
        awaitingInput: AwaitingSessions? = nil
    ) {
        self.lastUpdateAge = lastUpdateAge
        self.intervalSeconds = intervalSeconds
        self.rows = rows
        self.warning = warning
        self.serviceStatus = serviceStatus
        self.credits = credits
        self.blockingReset = blockingReset
        self.awaitingInput = awaitingInput
    }

    /// A copy of this layout with the awaiting-input count grafted on, everything else unchanged
    /// (#233). The shell calls this on the `make(...)` result so the awaiting indicator — sourced
    /// from `AwaitingInputWatcher`, not the usage snapshot — doesn't have to thread through `make`.
    public func withAwaitingInput(_ awaitingInput: AwaitingSessions?) -> PopupLayout {
        PopupLayout(
            lastUpdateAge: lastUpdateAge, intervalSeconds: intervalSeconds, rows: rows,
            warning: warning, serviceStatus: serviceStatus, credits: credits,
            blockingReset: blockingReset, awaitingInput: awaitingInput)
    }

    // MARK: make

    /// Build the popup layout from one usage snapshot at instant `now`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - lastUpdate: Instant of the last successful 200 (→ `lastUpdateAge`). Mock today; real with #13.
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`). Mock today.
    ///   - showModelSpecificLimits: When `false`, omit the per-model rows (`Opus`/`Sonnet`/scoped),
    ///     keeping only `5h` and `7d` (#211). Defaults to `true`.
    public static func make(
        from snapshot: UsageSnapshot,
        now: Date,
        lastUpdate: Date,
        interval: TimeInterval,
        showModelSpecificLimits: Bool = true,
        behindMultiplier: Int = 2
    ) -> PopupLayout {
        let rows = self.rows(from: snapshot, now: now, showModelSpecificLimits: showModelSpecificLimits,
                             behindMultiplier: behindMultiplier)
        return PopupLayout(
            lastUpdateAge: max(0, now.timeIntervalSince(lastUpdate)),
            intervalSeconds: interval,
            rows: rows,
            credits: self.creditsRow(from: snapshot, now: now),
            blockingReset: self.blockingReset(from: snapshot, now: now)
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
    ///   - showModelSpecificLimits: When `false`, omit the per-model rows (`Opus`/`Sonnet`/scoped),
    ///     keeping only `5h` and `7d` (#211). Defaults to `true`.
    public static func make(
        from snapshot: UsageSnapshot?,
        health: UsageHealth,
        now: Date,
        interval: TimeInterval,
        serviceStatus: StatusHealth? = nil,
        showModelSpecificLimits: Bool = true,
        behindMultiplier: Int = 2
    ) -> PopupLayout {
        let lastUpdateAge = health.lastSuccess.map { max(0, now.timeIntervalSince($0)) } ?? 0

        // A malformed **current** 200 body — an active window with a non-empty, unparseable `resets_at`
        // (`hasBrokenActiveReset`, #167/ADR-0043). Unlike a *health* failure (where the last **good**
        // snapshot's stale rows are still worth showing), here the current snapshot itself is corrupt, so
        // there is nothing trustworthy to render: show **only** the red warning banner (`.serverProblem`),
        // with no limit rows / credits / blocking-reset — the same shape as a cold-start failure.
        let brokenData = !health.isFailing && (snapshot?.hasBrokenActiveReset == true)
        if brokenData {
            return PopupLayout(
                lastUpdateAge: lastUpdateAge, intervalSeconds: interval, rows: [],
                warning: .serverProblem, serviceStatus: serviceStatus)
        }

        let rows = snapshot.map {
            self.rows(from: $0, now: now, showModelSpecificLimits: showModelSpecificLimits,
                      behindMultiplier: behindMultiplier)
        } ?? []
        // A failing poll surfaces its own reason (with the last known — possibly stale — rows above).
        let warning: FailureReason? = health.isFailing ? health.reason : nil
        let credits = snapshot.flatMap { self.creditsRow(from: $0, now: now) }
        let blockingReset = snapshot.flatMap { self.blockingReset(from: $0, now: now) }
        return PopupLayout(
            lastUpdateAge: lastUpdateAge,
            intervalSeconds: interval,
            rows: rows,
            warning: warning,
            serviceStatus: serviceStatus,
            credits: credits,
            blockingReset: blockingReset
        )
    }

    // MARK: - Private

    /// The ordered limit sections for a snapshot: `5h`, `7d`, then — when
    /// `showModelSpecificLimits` is `true` — any present per-model rows: the legacy top-level
    /// sub-windows (`Opus`/`Sonnet`, null-safe) followed by the `weekly_scoped` models from
    /// `limits[]` (e.g. `Fable`, #65; already deduped against the legacy rows by
    /// ``UsageSnapshot/scopedModelWindows``). All per-model rows are paced as `.sevenDay`.
    ///
    /// - Parameter showModelSpecificLimits: When `false`, the per-model rows are omitted and only
    ///   the `5h` and `7d` rows remain (the "Show model-specific limits" opt-out, #211). Defaults to
    ///   `true` so callers that don't care keep the full set.
    ///
    /// Shared by both ``make`` overloads.
    private static func rows(
        from snapshot: UsageSnapshot, now: Date, showModelSpecificLimits: Bool = true,
        behindMultiplier: Int = 2
    ) -> [LimitRow] {
        // The 5-hour row is the idle placeholder when the window has no active session (#100); every
        // other row is built normally, including the 7-day one (which always exists). When idle is also
        // **blocked** (#158) the placeholder carries `sessionBlocked` so the view greys it and swaps the
        // status word to "waiting for limit reset". (An *active* fully-exhausted 5h row is not idle, so
        // it shows the normal "limit reached" — only the red blocking-reset badge marks it, via
        // `blockingReset`.)
        let idleBlocked = snapshot.sessionIdle && CreditsPacing.isBlocked(in: snapshot)
        var rows: [LimitRow] = [
            snapshot.sessionIdle ? idleFiveHourRow(blocked: idleBlocked) : row(title: "5-hour", window: snapshot.fiveHour, as: .fiveHour, now: now, behindMultiplier: behindMultiplier),
            row(title: "7-day", window: snapshot.sevenDay, as: .sevenDay, now: now, behindMultiplier: behindMultiplier),
        ]
        if showModelSpecificLimits {
            if let opus = snapshot.sevenDayOpus {
                rows.append(row(title: "Opus", window: opus, as: .sevenDay, now: now, behindMultiplier: behindMultiplier))
            }
            if let sonnet = snapshot.sevenDaySonnet {
                rows.append(row(title: "Sonnet", window: sonnet, as: .sevenDay, now: now, behindMultiplier: behindMultiplier))
            }
            for scoped in snapshot.scopedModelWindows {
                rows.append(row(title: scoped.name, window: scoped.window, as: .sevenDay, now: now, behindMultiplier: behindMultiplier))
            }
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
    /// - `resetLine` is the unified reset line to `CreditsPacing.monthEnd` (next `00:00` UTC on the
    ///   1st), and is `nil` when the limit is unlimited (no cap ⇒ no reset line).
    private static func creditsRow(from snapshot: UsageSnapshot, now: Date) -> CreditsRow? {
        guard let spend = snapshot.spend, CreditsPacing.isActive(spend) else { return nil }
        let spent = spentMoney(from: spend)
        let bar = CreditsPacing.barLayout(for: spend, now: now)
        // A reset line only makes sense when there is a cap to reset against (bar != nil ⇔ limited).
        let resetLine = bar == nil
            ? nil
            : CreditsPacing.monthEnd(now: now).flatMap { ResetClock.resetLine(resetsAt: $0, now: now) }
        // "active" badge = credits are actually being spent right now — `isSpending` (enabled AND not
        // capped AND a main window exhausted). Deliberately stricter than the icon's `shouldShowIcon`:
        // once the money cap is reached the server disables credits (Claude is blocked), so the badge
        // must NOT claim they are active even though the icon still shows (red "ceiling hit"). It also
        // uses `mainWindowExhausted` — NOT the icon's wider `anyBaseLimitExhausted` — so only the two
        // windows that actually gate work (5h / 7d) turn it "active": a per-model row at 100 %
        // (Opus / Sonnet / a scoped model like Fable or Mythos) does not put credits in use, since work
        // isn't blocked and nothing has overflowed onto the paid tier yet.
        let inUse = CreditsPacing.isSpending(
            spend, baseLimitExhausted: CreditsPacing.mainWindowExhausted(in: snapshot))
        return CreditsRow(
            spent: spent, limit: spend.limit, bar: bar, resetLine: resetLine, inUse: inUse)
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

    /// The idle 5-hour placeholder row (#100, ADR-0027): title `"5-hour"`, `sessionIdle: true`, the
    /// reset line `nil`, and an inert zeroed bar (the view fills it solid blue and skips the second
    /// line). `subdivisions` stays the 5-hour value so the under-bar tick ruler keeps the row's anatomy
    /// in family with the active rows; the numeric fields are placeholders the idle render path ignores.
    private static func idleFiveHourRow(blocked: Bool = false) -> LimitRow {
        LimitRow(
            title: "5-hour",
            utilization: 0,
            pacing: .onPaceOrBehind,
            indicator: .neutral,
            // Inert placeholder: `.onPaceOrBehind` → `severity` is `.calm` before `remainingSeconds`
            // is ever read, so the value here is immaterial (0).
            bar: BarLayout(usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind, remainingSeconds: 0, windowDurationSeconds: 0, behindMultiplier: 2),
            subdivisions: LimitWindow.fiveHour.subdivisions,
            resetLine: nil,
            sessionIdle: true,
            sessionBlocked: blocked)
    }

    /// The blocking reset for the popup (#158) — `nil` unless the snapshot is **blocked** (no path to
    /// work: idle-blocked, or an active state with both 5h and 7d exhausted and credits not covering;
    /// ``CreditsPacing/isBlocked(in:)``). Delegates to the shared ``BlockingReset/forBlocked(snapshot:now:)``
    /// so the popup badge and the menu-bar countdown pick the same reset. The returned
    /// ``BlockingReset/Choice`` carries a popup **row index** (`token(id:)`) or the credits section
    /// (`credits`) — the view maps it to the one reset line it paints as a red badge.
    private static func blockingReset(from snapshot: UsageSnapshot, now: Date) -> BlockingReset.Choice? {
        // Blocked (no path to work: idle-blocked, or active with a main window exhausted and credits not
        // covering) → the "last stand" pick, which may be the credits reset (#158).
        if CreditsPacing.isBlocked(in: snapshot) {
            return BlockingReset.forBlocked(snapshot: snapshot, now: now)
        }
        // Not blocked, but a subscription limit is exhausted **and** paid credits are covering the work
        // (#193): still surface a red badge on the blocking subscription limit's reset — the moment the
        // plan quota returns and credits stop being spent. Never the credits reset here (credits are the
        // *cover*, not the blocker), so this uses the token-only `forSubscriptionExhausted`.
        if CreditsPacing.subscriptionExhaustedWhileCovered(in: snapshot) {
            return BlockingReset.forSubscriptionExhausted(snapshot: snapshot, now: now)
        }
        return nil
    }

    /// Build one `LimitRow`, delegating all arithmetic to tested pure logic. An unparseable
    /// `resets_at` falls back to `now` for the bar geometry (→ `elapsedFraction == 1.0`, matching
    /// `MenuBarLayout`) and to `nil` reset strings (the view shows a stale signal).
    private static func row(title: String, window: UsageWindow, as kind: LimitWindow, now: Date,
                            behindMultiplier: Int = 2) -> LimitRow {
        let parsed = ResetClock.parse(window.resetsAt)
        let bar = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: parsed ?? now,
            now: now,
            window: kind,
            behindMultiplier: behindMultiplier
        )
        let indicator = PacingModel.limitIndicator(utilization: window.utilization)
        let resetLine = parsed.flatMap { ResetClock.resetLine(resetsAt: $0, now: now) }
        return LimitRow(
            title: title,
            utilization: window.utilization,
            pacing: bar.pacing,
            indicator: indicator,
            bar: bar,
            subdivisions: kind.subdivisions,
            resetLine: resetLine
        )
    }
}
