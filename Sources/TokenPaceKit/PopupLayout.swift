import Foundation

// MARK: - LimitRow

/// One section of the popup: a named limit window with its pacing, a drawable bar, and a split
/// reset countdown. Pure data — no AppKit, no human-readable sentences (the view assembles
/// "% used · on pace · resets in …"). Reset *time* strings are the one exception: they are
/// produced by `ResetClock`, not localised prose, so they live here rather than in the view.
///
/// Used for every kind of section — `5h`, `7d`, the per-model sub-windows (`Opus`, `Sonnet`),
/// and the `weekly_scoped` models from `limits[]` (e.g. `Fable`); all per-model rows are paced
/// as `.sevenDay` (they reset on the weekly cadence).
public struct LimitRow: Sendable, Equatable {
    /// Section heading, e.g. `"5-hour"`, `"7-day"`, or a bare model name `"Opus"` / `"Fable"` for the
    /// per-model rows (all 7-day paced; no "(7-day)" suffix). Not localised — the view renders it as-is.
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
    /// windows. The view draws `subdivisions - 1` interior ticks.
    public let subdivisions: Int
    /// The complete, unified reset line for this window (`ResetClock.resetLine`): `"15d"`,
    /// `"7d next Monday"`, `"5d on Friday"`, `"20h at 03:00"`, `"45m at 03:00"`. `nil` when the
    /// reset is now/past or `resets_at` was unparseable (the view shows its "resetting…" fallback).
    public let resetLine: String?
    /// The same line with the `"resets in"` lead-in (`ResetClock.resetLine(verbose: true)`).
    /// Both forms are precomputed because the choice is the **live ⌥ Option state**, which flips
    /// while the menu is open without a re-poll. `nil` in exactly the cases ``resetLine`` is.
    public let resetLineVerbose: String?
    /// Whether this is the **idle** 5-hour row — the 5h window does not exist server-side (no
    /// active session, ``UsageSnapshot/sessionIdle``). When `true` the view renders a green
    /// knobless bar, the status word "ready to start", and **no second line at all**; the numeric
    /// fields are inert placeholders the idle render path ignores. `false` on every normal row.
    public let sessionIdle: Bool
    /// Whether this idle 5-hour row is also **blocked**: the 7-day limit is exhausted and paid
    /// credits cannot cover, so there is no path to start a session. When `true` the view draws
    /// the idle pill **grey** and shows "waiting for limit reset" instead of "ready to start".
    /// Only ever `true` alongside ``sessionIdle``; `false` on every other row.
    public let sessionBlocked: Bool

    public init(
        title: String,
        utilization: Double,
        pacing: PacingState,
        indicator: LimitIndicator,
        bar: BarLayout,
        subdivisions: Int,
        resetLine: String?,
        resetLineVerbose: String? = nil,
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
        self.resetLineVerbose = resetLineVerbose
        self.sessionIdle = sessionIdle
        self.sessionBlocked = sessionBlocked
    }
}

// MARK: - CreditsRow

/// The "Extra usage" (money-credits) section of the popup — the pure-data counterpart of
/// ``LimitRow`` for the paid overspend that covers you past the plan limits.
///
/// Like ``LimitRow`` it carries **raw** values only — money objects, a drawable ``BarLayout``, and a
/// pre-formatted reset line — and **no** human-readable sentences: the view assembles
/// "on pace / ahead / limit reached" and "€spent / €limit" from these (ADR-0009). It is a
/// **separate** field on ``PopupLayout`` (not one of ``PopupLayout/rows``) because a credits
/// section is not a limit window: no utilisation percent, no tick subdivisions, and its "cap"
/// may be absent (unlimited).
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
    public let bar: BarLayout?
    /// The unified reset line to the end of the money window — the next `00:00` UTC on the 1st
    /// (`CreditsPacing.monthEnd` → `ResetClock.resetLine`), in the same format every limit uses:
    /// `"15d"`, `"5d on Friday"`, `"20h at 03:00"`. The `00:00` UTC boundary reads as the user's
    /// **local** day/time. `nil` when the limit is unlimited or the boundary was unresolvable.
    public let resetLine: String?
    /// The ⌥ form of ``resetLine``, with the `"resets in"` lead-in — see
    /// ``LimitRow/resetLineVerbose`` for why both are precomputed. `nil` whenever ``resetLine`` is.
    public let resetLineVerbose: String?
    /// Whether paid credits are **actually being spent right now** — `enabled` **and** at least one base
    /// limit is exhausted (`CreditsPacing.shouldShowIcon`, the same gate as the menu-bar icon). Drives
    /// the blue **"in use"** badge next to the heading: the section itself shows whenever credits are
    /// merely *active* (enabled/reached), but the badge appears only while the plan limit is actually
    /// overflowing into credits.
    public let inUse: Bool
    /// Whether the money cap is **spent** — the server's own `spend_limit_reached`, not an arithmetic
    /// comparison of the two amounts.
    ///
    /// Distinct from `bar.usageFraction >= 1`: the fraction answers "how full is the bar", this answers
    /// "has the paid tier been switched off". The view needs the second one for the **unlimited** row,
    /// which has no bar — without a cap there is nothing to be `1` of, yet credits can still run out.
    public let spendLimitReached: Bool
    /// The captions for the credits bar's two boundary ticks — the money window's first and last day,
    /// `("Aug 1", "Aug 31")`, from `CreditsPacing.monthBoundaryLabels`. `nil` when there is no
    /// bar to caption (unlimited) or the calendar could not resolve the bounds.
    ///
    /// These name the **UTC** month bounds that define the bar's own `0` and `1` — they do not follow
    /// ``resetLine``'s local zone (`CreditsPacing.monthBoundaryLabels`).
    public let monthBounds: (start: String, end: String)?

    public init(spent: Money, limit: Money?, bar: BarLayout?, resetLine: String?,
                resetLineVerbose: String? = nil, inUse: Bool = false,
                spendLimitReached: Bool = false,
                monthBounds: (start: String, end: String)? = nil) {
        self.spent = spent
        self.limit = limit
        self.bar = bar
        self.resetLine = resetLine
        self.resetLineVerbose = resetLineVerbose
        self.inUse = inUse
        self.spendLimitReached = spendLimitReached
        self.monthBounds = monthBounds
    }

    /// Hand-written because a tuple property has no synthesised `==` (tuples are not `Equatable`).
    public static func == (lhs: CreditsRow, rhs: CreditsRow) -> Bool {
        lhs.spent == rhs.spent && lhs.limit == rhs.limit && lhs.bar == rhs.bar
            && lhs.resetLine == rhs.resetLine && lhs.resetLineVerbose == rhs.resetLineVerbose
            && lhs.inUse == rhs.inUse
            && lhs.spendLimitReached == rhs.spendLimitReached
            && lhs.monthBounds?.start == rhs.monthBounds?.start
            && lhs.monthBounds?.end == rhs.monthBounds?.end
    }
}

// MARK: - PopupLayout

/// The pure, AppKit-free model of the click-to-open popup for one usage snapshot — the testable
/// core behind `PopupViewController`.
///
/// Mirrors `MenuBarLayout`: `make(...)` is **stateless and deterministic** (`now`, `lastUpdate`,
/// `interval` are injected) and adds **no new pacing arithmetic** — it reuses `PacingModel` and
/// `ResetClock`. The struct computes *what* to show; the thin `NSViewController` shell in
/// `TokenPace` does *how* (ADR-0009).
///
/// The service-line values (`lastUpdateAge`, `intervalSeconds`) are **raw seconds** — the view
/// formats them ("just now", "3m") so a future localisation touches only the view.
///
/// ``warning``: when a poll is failing, the popup shows a two-line banner **immediately** (no
/// 30-min threshold — that gate is the menu bar's, not the popup's), above the possibly-stale
/// ``rows``. A healthy layout leaves it `nil`.
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
    /// The current failure cause when a poll is failing, else `nil`. Drives the popup warning banner;
    /// the view turns it into the two-line title/detail (the localisation seam).
    public let warning: FailureReason?
    /// The Claude service status (two component states), or `nil` until the first status poll has
    /// succeeded. When `nil`, the view shows **no** status lines (cold start); otherwise it renders
    /// one line per component with a colour dot and a linked status word. Independent of `warning`:
    /// the usage poll and the status poll fail and succeed separately.
    public let serviceStatus: StatusHealth?
    /// Age of each satellite provider's last successful status poll, in seconds. A provider is absent
    /// when it has never succeeded or is not monitored.
    ///
    /// Keyed rather than folded into ``lastUpdateAge``: every provider polls on a cadence of its own,
    /// so one age standing for all of them would be a quiet lie.
    public let providerStatusAges: [ProviderID: TimeInterval]
    /// Each satellite provider's visible incidents, rendered on that provider's own plate under
    /// Option.
    ///
    /// Separate from ``incidents``, which stays Claude's — one list would put another provider's
    /// outage under the Claude header, and the incident rows deliberately do not name the services
    /// they affect (ADR-0071 §3), so they cannot self-correct that attribution.
    public let providerIncidents: [ProviderID: [VisibleIncident]]
    /// The "Extra usage" money-credits section, or `nil` when credits are inactive for this
    /// snapshot (`snapshot.spend == nil` or `!CreditsPacing.isActive`). A **separate** field from
    /// ``rows`` — a credits section is not a limit window (see ``CreditsRow``).
    public let credits: CreditsRow?
    /// Which one reset the view should highlight in **red** as the **blocking** reset — the reset that
    /// actually unblocks work. Set in two cases:
    /// - **Blocked** (no path to work: idle-blocked, or active with a main window exhausted and credits
    ///   not covering) — the "last stand" pick (`BlockingReset.forBlocked`), which may be the credits reset.
    /// - **Subscription-exhausted while credits cover** (`CreditsPacing.subscriptionExhaustedWhileCovered`)
    ///   — the latest exhausted **token** reset (`BlockingReset.forSubscriptionExhausted`); never the
    ///   credits reset, since credits are the cover, not the blocker.
    ///
    /// `nil` in every other state. When non-`nil`:
    /// - ``BlockingReset/Choice/token(id:resetsAt:)`` — `id` is the index into ``rows`` whose reset
    ///   line the view paints red;
    /// - ``BlockingReset/Choice/credits(resetsAt:)`` — the "Extra usage" section's reset line is painted
    ///   red instead.
    /// Exactly one reset is ever highlighted, even when several limits are simultaneously exhausted.
    public let blockingReset: BlockingReset.Choice?

    /// The index in ``rows`` at which the **per-model / per-service** rows begin — the first row after
    /// the base `5h`/`7d` pair, i.e. `2` on a normal snapshot. Rows before it are the base limits and
    /// are never gated; rows from here on are the optional group governed by
    /// ``PopupSectionVisibility``. Equal to ``rows``'s count when a snapshot carries no per-model
    /// windows (empty group).
    ///
    /// Expressed as an **index** rather than by dropping the rows here because `BlockingReset` keys
    /// its `.token(id:)` pick to the *full* row order (`0` = 5h, `1` = 7d, then per-model) and the
    /// view matches it with `id == index`. Filtering here would renumber the rows and mis-paint the
    /// red blocking-reset badge; the view hides rows while keeping their original indices.
    public let perModelRowsStart: Int

    /// Whether any **per-model / per-service** row is orange or red (`PacingSeverity.isNonCalm`) — the
    /// "is this group worth attention?" input to ``PopupSectionVisibility/shows(isNonCalm:isAboveZero:optionHeld:)``.
    /// `false` when the group is empty.
    public let perModelRowsAreNonCalm: Bool

    /// Whether any **per-model / per-service** row has been used at all (`utilization > 0`) — the
    /// "is there anything in this group?" input to ``PopupSectionVisibility/aboveZero``. `false` when
    /// the group is empty or every row sits at a flat zero.
    ///
    /// Independent of ``perModelRowsAreNonCalm``: this reads the raw value, that reads the pacing
    /// verdict, and early in a 7-day window a 2 % row is simultaneously above zero *and* orange.
    public let perModelRowsAreAboveZero: Bool

    /// Whether the **Extra usage** credits section is orange or red — `credits.bar`'s severity, or
    /// `false` when there is no credits section or it is unlimited (`bar == nil`, nothing to pace).
    public let creditsIsNonCalm: Bool

    /// Whether any money has been spent this period (`credits.spent` non-zero), or `false` when there
    /// is no credits section.
    ///
    /// Reads ``CreditsRow/spent`` and **not** ``CreditsRow/bar``: an unlimited money cap produces no
    /// bar and therefore no severity, so ``creditsIsNonCalm`` is permanently `false` there and a
    /// `nonCalm` gate would hide a paying user's spend forever. `spent` is always present
    /// (`spentMoney(from:)` falls back to a zero amount), so this stays meaningful in every state.
    public let creditsIsAboveZero: Bool

    /// The Claude Code sessions awaiting user input to advertise flush-right in the "Claude" section
    /// header (ADR-0066), or `nil` to draw nothing. `nil` whenever the feature is off, the count is
    /// `0`, or the watcher isn't running. When non-`nil` (count `≥ 1`) the popup draws a `hand.raised`
    /// icon tinted by ``AwaitingSessions/urgency``; a count of `1` shows the bare icon, `≥ 2` appends
    /// the count. Clicking the block opens the per-project breakdown (``AwaitingSessions/perProject``).
    /// Sourced by the shell from `AwaitingInputWatcher`, independent of the usage snapshot.
    public let awaitingInput: AwaitingSessions?

    /// The short plan label shown in brand colour right after "Claude" in the header (e.g. "Max (5x)"),
    /// or `nil` to draw just "Claude". Derived from the Keychain `rateLimitTier` via
    /// ``claudePlanLabel(rateLimitTier:)`` — comes from the OAuth payload, not the usage snapshot, so
    /// the shell grafts it on via ``withPlanLabel(_:)`` rather than threading it through `make`.
    public let planLabel: String?

    /// The status-page incidents worth showing, already filtered by ``IncidentVisibility``. Empty on
    /// every ordinary frame. Arrives on the status poll's own cadence rather than with the usage
    /// snapshot, so the shell grafts it on via ``withIncidents(_:)`` instead of threading it through `make`.
    public let incidents: [VisibleIncident]

    /// What the single subscribe row should show, or `nil` when there is nothing to subscribe to and
    /// the row is omitted entirely.
    public let subscription: EpisodeSubscriptionState?

    /// What the user currently monitors — the popup's own copy of the mode the menu bar shows as
    /// `zzz` or ⚠️. The view uses it to swap the red failure banner for a plain explanation, to keep
    /// the service rows visible while everything is green, and to read ``lastUpdateAge`` as the age
    /// of the *status* poll rather than the usage poll.
    public let monitoringMode: MonitoringMode

    /// Which data sources are switched on.
    public enum MonitoringMode: Sendable, Equatable {
        /// The usage API is polled — the ordinary case.
        case usageAndServices
        /// The usage poll is off; status-page services are still watched.
        case servicesOnly
        /// Nothing is monitored at all.
        case nothing
    }

    /// The weekly window has no reset instant and none can be reconstructed — a cold start that has
    /// never seen one (ADR-0107). Every row is withheld while this is `true`.
    ///
    /// **Not a ``FailureReason``.** Nothing has failed: the request returned 200 and the body was
    /// well-formed. The API simply has not created a weekly window yet, because no tokens have been
    /// spent. Dressing it as `.serverProblem` would show "Usage API unavailable", sending the user to
    /// check their network when the actual fix is to start working.
    ///
    /// Rows are withheld rather than partially drawn because the emptiness cascades: the per-model
    /// windows inherit the weekly reset, so they would all render with a time marker pinned to the
    /// far edge — `elapsedFraction` returns `1.0` for an unparseable reset.
    public let weeklyResetUnknown: Bool

    public init(
        lastUpdateAge: TimeInterval,
        intervalSeconds: TimeInterval,
        rows: [LimitRow],
        warning: FailureReason? = nil,
        serviceStatus: StatusHealth? = nil,
        credits: CreditsRow? = nil,
        blockingReset: BlockingReset.Choice? = nil,
        perModelRowsStart: Int? = nil,
        perModelRowsAreNonCalm: Bool = false,
        perModelRowsAreAboveZero: Bool = false,
        creditsIsNonCalm: Bool = false,
        creditsIsAboveZero: Bool = false,
        awaitingInput: AwaitingSessions? = nil,
        incidents: [VisibleIncident] = [],
        subscription: EpisodeSubscriptionState? = nil,
        planLabel: String? = nil,
        monitoringMode: MonitoringMode = .usageAndServices,
        weeklyResetUnknown: Bool = false,
        providerStatusAges: [ProviderID: TimeInterval] = [:],
        providerIncidents: [ProviderID: [VisibleIncident]] = [:]
    ) {
        self.lastUpdateAge = lastUpdateAge
        self.intervalSeconds = intervalSeconds
        self.rows = rows
        self.warning = warning
        self.serviceStatus = serviceStatus
        self.credits = credits
        self.blockingReset = blockingReset
        // Default: the two base rows come first, so the group starts at 2 — clamped for a short
        // `rows` (cold start / broken-data layout: empty, or fewer than two rows).
        self.perModelRowsStart = perModelRowsStart ?? min(2, rows.count)
        self.perModelRowsAreNonCalm = perModelRowsAreNonCalm
        self.perModelRowsAreAboveZero = perModelRowsAreAboveZero
        self.creditsIsNonCalm = creditsIsNonCalm
        self.creditsIsAboveZero = creditsIsAboveZero
        self.awaitingInput = awaitingInput
        self.planLabel = planLabel
        self.incidents = incidents
        self.subscription = subscription
        self.monitoringMode = monitoringMode
        self.weeklyResetUnknown = weeklyResetUnknown
        self.providerStatusAges = providerStatusAges
        self.providerIncidents = providerIncidents
    }

    /// A copy of this layout with **one** field replaced, everything else carried over. Every `with*`
    /// helper below routes through here so adding a field is one edit, not one edit per helper.
    private func copy(
        lastUpdateAge: TimeInterval? = nil,
        awaitingInput: AwaitingSessions?? = nil,
        incidents: [VisibleIncident]? = nil,
        subscription: EpisodeSubscriptionState?? = nil,
        planLabel: String?? = nil,
        providerStatusAges: [ProviderID: TimeInterval]? = nil,
        providerIncidents: [ProviderID: [VisibleIncident]]? = nil
    ) -> PopupLayout {
        PopupLayout(
            lastUpdateAge: lastUpdateAge ?? self.lastUpdateAge,
            intervalSeconds: intervalSeconds, rows: rows,
            warning: warning, serviceStatus: serviceStatus, credits: credits,
            blockingReset: blockingReset, perModelRowsStart: perModelRowsStart,
            perModelRowsAreNonCalm: perModelRowsAreNonCalm,
            perModelRowsAreAboveZero: perModelRowsAreAboveZero,
            creditsIsNonCalm: creditsIsNonCalm, creditsIsAboveZero: creditsIsAboveZero,
            awaitingInput: awaitingInput ?? self.awaitingInput,
            incidents: incidents ?? self.incidents,
            subscription: subscription ?? self.subscription,
            planLabel: planLabel ?? self.planLabel,
            monitoringMode: monitoringMode,
            weeklyResetUnknown: weeklyResetUnknown,
            providerStatusAges: providerStatusAges ?? self.providerStatusAges,
            providerIncidents: providerIncidents ?? self.providerIncidents)
    }

    /// A copy of this layout with the awaiting-input count grafted on, everything else unchanged.
    /// The shell calls this on the `make(...)` result so the awaiting indicator — sourced from
    /// `AwaitingInputWatcher`, not the usage snapshot — doesn't have to thread through `make`.
    public func withAwaitingInput(_ awaitingInput: AwaitingSessions?) -> PopupLayout {
        copy(awaitingInput: .some(awaitingInput))
    }

    /// A copy of this layout with the status-page incidents grafted on, everything else unchanged.
    /// Incidents ride the status poll, not the usage poll.
    public func withIncidents(_ incidents: [VisibleIncident]) -> PopupLayout {
        copy(incidents: incidents)
    }

    /// A copy of this layout with the subscribe row's state grafted on. `nil` omits the row.
    public func withSubscription(_ subscription: EpisodeSubscriptionState?) -> PopupLayout {
        copy(subscription: .some(subscription))
    }

    /// A copy of this layout whose ``lastUpdateAge`` is measured from the **status** poll instead of
    /// the usage poll — used only in ``MonitoringMode/servicesOnly``, where the usage clock is
    /// deliberately stopped and reporting its age would be a lie ("0 s ago" for data nobody fetched).
    ///
    /// `nil` means the status poll has not landed yet — the common case on entry to the mode, since
    /// the shell clears its status clock at exactly that moment. The age then stays `0` and the view
    /// shows no age rather than inventing one.
    public func withStatusAge(_ age: TimeInterval?) -> PopupLayout {
        guard monitoringMode == .servicesOnly, let age else { return self }
        return copy(lastUpdateAge: max(0, age))
    }

    /// A copy of this layout with the plan label grafted on, everything else unchanged. The shell
    /// calls this on the `make(...)` result so the plan label — sourced from the OAuth `rateLimitTier`,
    /// not the usage snapshot — doesn't have to thread through `make`.
    public func withPlanLabel(_ planLabel: String?) -> PopupLayout {
        copy(planLabel: .some(planLabel))
    }

    /// A copy carrying one satellite provider's status-poll age, grafted on like the plan label,
    /// since it comes from the shell's own poll bookkeeping rather than from any usage snapshot. A
    /// `nil` age removes the entry — the provider has nothing to report rather than an age of zero.
    public func withProviderStatusAge(_ provider: ProviderID, _ age: TimeInterval?) -> PopupLayout {
        var ages = providerStatusAges
        ages[provider] = age.map { max(0, $0) }
        return copy(providerStatusAges: ages)
    }

    /// A copy carrying one satellite provider's visible incidents, grafted like Claude's.
    public func withProviderIncidents(_ provider: ProviderID, _ incidents: [VisibleIncident]) -> PopupLayout {
        var all = providerIncidents
        all[provider] = incidents
        return copy(providerIncidents: all)
    }

    /// One satellite provider's own poll age, or `nil` when it has none.
    public func statusAge(of provider: ProviderID) -> TimeInterval? { providerStatusAges[provider] }

    /// One satellite provider's visible incidents.
    public func incidents(of provider: ProviderID) -> [VisibleIncident] {
        providerIncidents[provider] ?? []
    }

    // MARK: make

    /// Build the popup layout from one usage snapshot at instant `now`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - lastUpdate: Instant of the last successful 200 (→ `lastUpdateAge`).
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`).
    ///
    /// The per-model rows are **always** built: whether they are drawn is the view's call, since it
    /// depends on the live ⌥ Option state, which changes while the menu is open and without a
    /// re-poll. ``perModelRowsStart`` and ``perModelRowsAreNonCalm`` carry everything the view needs.
    public static func make(
        from snapshot: UsageSnapshot,
        now: Date,
        lastUpdate: Date,
        interval: TimeInterval
    ) -> PopupLayout {
        let rows = self.rows(from: snapshot, now: now)
        let credits = self.creditsRow(from: snapshot, now: now)
        return PopupLayout(
            lastUpdateAge: max(0, now.timeIntervalSince(lastUpdate)),
            intervalSeconds: interval,
            rows: rows,
            credits: credits,
            blockingReset: self.blockingReset(from: snapshot, now: now),
            perModelRowsStart: min(baseRowCount, rows.count),
            perModelRowsAreNonCalm: self.groupIsNonCalm(rows),
            perModelRowsAreAboveZero: self.groupIsAboveZero(rows),
            creditsIsNonCalm: credits?.bar?.severity.isNonCalm ?? false,
            creditsIsAboveZero: credits.map { !$0.spent.isZero } ?? false
        )
    }

    // MARK: make (health-aware, issue #12)

    /// Build the popup from the last known snapshot **and** the polling health.
    ///
    /// The entry point the live loop calls. Unlike the menu bar's staged thresholds, the popup warns
    /// the moment a failure is in progress (SPEC: "on any non-working authorization … immediately"):
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
    ///   - serviceStatus: The latest Claude service status, or `nil` until the first status poll has
    ///     succeeded (the status loop is independent of the usage poll). Threaded through unchanged.
    ///   - monitoringAnything: Whether anything is monitored at all. `false` produces a layout with
    ///     no rows and no red banner — nothing is broken, so the view explains the state in words
    ///     instead. Default `true`.
    ///
    /// As in the other overload, the per-model rows are always built; ``perModelRowsStart`` /
    /// ``perModelRowsAreNonCalm`` / ``creditsIsNonCalm`` let the view apply the user's
    /// ``PopupSectionVisibility`` against the live ⌥ state.
    public static func make(
        from snapshot: UsageSnapshot?,
        health: UsageHealth,
        now: Date,
        interval: TimeInterval,
        serviceStatus: StatusHealth? = nil,
        monitoringAnything: Bool = true
    ) -> PopupLayout {
        let lastUpdateAge = health.lastSuccess.map { max(0, now.timeIntervalSince($0)) } ?? 0

        // Ahead of every failure branch below: monitoring mode is a user choice, and the failure
        // machinery would otherwise dress it up as breakage. In both modes there are no rows:
        // whatever snapshot survived is not being refreshed, and drawing bars from it would present
        // frozen numbers as current.
        //
        // `lastUpdateAge` starts from the usage clock and is replaced by `withStatusAge(_:)` in the
        // services-only mode — the shell owns that value, since it is the one polling the status page.
        if !monitoringAnything {
            return PopupLayout(
                lastUpdateAge: lastUpdateAge, intervalSeconds: interval, rows: [],
                serviceStatus: serviceStatus, monitoringMode: .nothing)
        }
        if !health.isCollectingUsage {
            return PopupLayout(
                lastUpdateAge: lastUpdateAge, intervalSeconds: interval, rows: [],
                serviceStatus: serviceStatus, monitoringMode: .servicesOnly)
        }

        // A malformed **current** 200 body — an active window with a non-empty, unparseable `resets_at`
        // (`hasBrokenActiveReset`, ADR-0043). Unlike a *health* failure (where the last **good**
        // snapshot's stale rows are still worth showing), here the current snapshot itself is corrupt, so
        // there is nothing trustworthy to render: show **only** the red warning banner (`.serverProblem`),
        // with no limit rows / credits / blocking-reset — the same shape as a cold-start failure.
        //
        // The guard is `!isFailing`, which the "nothing monitored" state would also satisfy; the
        // monitoring branches above already return before reaching here.
        let brokenData = !health.isFailing && (snapshot?.hasBrokenActiveReset == true)
        if brokenData {
            return PopupLayout(
                lastUpdateAge: lastUpdateAge, intervalSeconds: interval, rows: [],
                warning: .serverProblem, serviceStatus: serviceStatus)
        }

        // No weekly reset at all, and no anchor to reconstruct one from (ADR-0107) — a cold start
        // that has never seen a token spent. Deliberately **not** a `warning`: the poll succeeded and
        // the body was valid, so the failure vocabulary would misdescribe it. Rows are withheld for
        // the same reason as `brokenData` above: the per-model windows inherit the empty weekly
        // reset, so every one would draw a marker pinned to the far edge. `hasBrokenActiveReset` does
        // not catch this — it requires `utilization > 0` and a *non-empty* unparseable string.
        // The `utilization == 0` half mirrors `MenuBarLayout`, so both surfaces agree on this state.
        if !health.isFailing,
           snapshot?.sevenDay.resetsAt.isEmpty == true,
           snapshot?.sevenDay.utilization == 0 {
            return PopupLayout(
                lastUpdateAge: lastUpdateAge, intervalSeconds: interval, rows: [],
                serviceStatus: serviceStatus, weeklyResetUnknown: true)
        }

        let rows = snapshot.map {
            self.rows(from: $0, now: now)
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
            blockingReset: blockingReset,
            perModelRowsStart: min(baseRowCount, rows.count),
            perModelRowsAreNonCalm: self.groupIsNonCalm(rows),
            perModelRowsAreAboveZero: self.groupIsAboveZero(rows),
            creditsIsNonCalm: credits?.bar?.severity.isNonCalm ?? false,
            creditsIsAboveZero: credits.map { !$0.spent.isZero } ?? false
        )
    }

    // MARK: - Private

    /// The number of **base** limit rows every non-empty layout starts with: `5h` then `7d`. Rows from
    /// this index on are the optional per-model / per-service group (``perModelRowsStart``), and
    /// `BlockingReset` keys its `.token(id:)` pick to this same ordering.
    static let baseRowCount = 2

    /// Whether any row in the per-model group (everything from ``baseRowCount`` on) is orange/red.
    /// `false` when the snapshot carries no per-model windows.
    private static func groupIsNonCalm(_ rows: [LimitRow]) -> Bool {
        rows.dropFirst(baseRowCount).contains { $0.bar.severity.isNonCalm }
    }

    /// Whether any **per-model** row has been used at all — the `aboveZero` counterpart of
    /// ``groupIsNonCalm(_:)``, dropping the same base rows so a busy 5h/7d window never speaks for the
    /// optional group.
    ///
    /// Reads `utilization` (the API percent) rather than anything derived from the bar: the bar encodes
    /// pacing, and pacing is a verdict about the value, not the value itself.
    private static func groupIsAboveZero(_ rows: [LimitRow]) -> Bool {
        rows.dropFirst(baseRowCount).contains { $0.utilization > 0 }
    }

    /// The ordered limit sections for a snapshot: `5h`, `7d`, then any present per-model rows: the
    /// legacy top-level sub-windows (`Opus`/`Sonnet`, null-safe) followed by the `weekly_scoped` models
    /// from `limits[]` (e.g. `Fable`; already deduped against the legacy rows by
    /// ``UsageSnapshot/scopedModelWindows``). All per-model rows are paced as `.sevenDay`.
    ///
    /// The per-model rows are **always** included — visibility is the view's decision (see
    /// ``PopupSectionVisibility``), and dropping them here would renumber the indices `BlockingReset`
    /// depends on.
    ///
    /// Shared by both ``make`` overloads.
    private static func rows(
        from snapshot: UsageSnapshot, now: Date
    ) -> [LimitRow] {
        // The 5-hour row is the idle placeholder when the window has no active session; every other
        // row is built normally, including the 7-day one (which always exists). When idle is also
        // **blocked** the placeholder carries `sessionBlocked` so the view greys it and swaps the
        // status word to "waiting for limit reset". (An *active* fully-exhausted 5h row is not idle, so
        // it shows the normal "limit reached" — only the red blocking-reset badge marks it, via
        // `blockingReset`.)
        let idleBlocked = snapshot.sessionIdle && CreditsPacing.isBlocked(in: snapshot)
        // The weekly gate (`PacingModel.weeklyHasHeadroom`): blue is "the week has room you are not
        // using", so the 5-hour bar may only go blue while the 7-day window itself has headroom. The
        // 7-day row never gates on itself and passes `true`.
        //
        // Per-model rows do **not** take this gate — they are slices of that same week, so the advice
        // would be addressed to itself, and they pass `false` outright (reason 2 on
        // `BarLayout.blueAllowed`). Letting them take it lets the model report blue while the popup
        // silences it again through `PopupBarView.isBaseLimit`, and the journal records a blue never on screen.
        let weeklyHeadroom = PacingModel.weeklyHasHeadroom(in: snapshot, now: now)
        var rows: [LimitRow] = [
            snapshot.sessionIdle ? idleFiveHourRow(blocked: idleBlocked) : row(title: "5-hour", window: snapshot.fiveHour, as: .fiveHour, now: now, blueAllowed: weeklyHeadroom),
            row(title: "7-day", window: snapshot.sevenDay, as: .sevenDay, now: now, blueAllowed: true),
        ]
        if let opus = snapshot.sevenDayOpus {
            rows.append(row(title: "Opus", window: opus, as: .sevenDay, now: now, blueAllowed: false))
        }
        if let sonnet = snapshot.sevenDaySonnet {
            rows.append(row(title: "Sonnet", window: sonnet, as: .sevenDay, now: now, blueAllowed: false))
        }
        for scoped in snapshot.scopedModelWindows {
            rows.append(row(title: scoped.name, window: scoped.window, as: .sevenDay, now: now, blueAllowed: false))
        }
        return rows
    }

    /// Build the "Extra usage" money-credits section from a snapshot's ``UsageSnapshot/spend``, or
    /// `nil` when credits are inactive for this snapshot.
    ///
    /// ## Show gate — deliberately softer than the menu-bar icon's
    /// The menu-bar credits **icon** shows only when `CreditsPacing.shouldShowIcon` holds — credits
    /// active **and** a base limit exhausted. The **dropdown** is the detail view the user has
    /// explicitly opened, so the gate is only ``CreditsPacing/isActive(_:)`` (`enabled` **or**
    /// `spend_limit_reached`): once credits are switched on, showing the amount spent is useful even
    /// before a plan limit is spent. `baseLimitExhausted` is not additionally required (icon's concern).
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
        let monthEnd = bar == nil ? nil : CreditsPacing.monthEnd(now: now)
        let resetLine = monthEnd.flatMap { ResetClock.resetLine(resetsAt: $0, now: now) }
        let resetLineVerbose = monthEnd.flatMap {
            ResetClock.resetLine(resetsAt: $0, now: now, verbose: true)
        }
        // "active" badge = credits are actually being spent right now — `isSpending` (enabled AND not
        // capped AND a main window exhausted). Stricter than the icon's `shouldShowIcon`: once the
        // money cap is reached the server disables credits, so the badge must NOT claim they're
        // active even though the icon still shows (red "ceiling hit"). Uses `mainWindowExhausted` —
        // NOT the icon's wider `anyBaseLimitExhausted` — so only the windows that actually gate work
        // (5h / 7d) turn it "active": a per-model row at 100% does not put credits in use.
        let inUse = CreditsPacing.isSpending(
            spend, baseLimitExhausted: CreditsPacing.mainWindowExhausted(in: snapshot))
        // Boundary captions for the bar's own ruler — only when there *is* a bar to caption.
        let monthBounds = bar == nil ? nil : CreditsPacing.monthBoundaryLabels(now: now)
        return CreditsRow(
            spent: spent, limit: spend.limit, bar: bar, resetLine: resetLine,
            resetLineVerbose: resetLineVerbose, inUse: inUse,
            spendLimitReached: spend.spendLimitReached, monthBounds: monthBounds)
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

    /// The idle 5-hour placeholder row (ADR-0027): title `"5-hour"`, `sessionIdle: true`, the reset
    /// line `nil`, and an inert zeroed bar (the view draws a grey track plus a zero pill and skips
    /// the second line). `subdivisions` stays the 5-hour value so the under-bar tick ruler keeps the
    /// row's anatomy in family with the active rows; the numeric fields are placeholders the idle
    /// render path ignores.
    private static func idleFiveHourRow(blocked: Bool = false) -> LimitRow {
        LimitRow(
            title: "5-hour",
            utilization: 0,
            pacing: .onPaceOrBehind,
            indicator: .neutral,
            // Inert placeholder: `.onPaceOrBehind` → `severity` is `.calm` before `remainingSeconds`
            // is ever read, so the value here is immaterial (0).
            bar: BarLayout(usageFraction: 0, timeFraction: 0, pacing: .onPaceOrBehind, remainingSeconds: 0, windowDurationSeconds: 0, blueAllowed: false),
            subdivisions: LimitWindow.fiveHour.subdivisions,
            resetLine: nil,
            sessionIdle: true,
            sessionBlocked: blocked)
    }

    /// The blocking reset for the popup — `nil` unless the snapshot is **blocked** (no path to
    /// work: idle-blocked, or an active state with both 5h and 7d exhausted and credits not covering;
    /// ``CreditsPacing/isBlocked(in:)``). Delegates to the shared ``BlockingReset/forBlocked(snapshot:now:)``
    /// so the popup badge and the menu-bar countdown pick the same reset. The returned
    /// ``BlockingReset/Choice`` carries a popup **row index** (`token(id:)`) or the credits section
    /// (`credits`) — the view maps it to the one reset line it paints as a red badge.
    private static func blockingReset(from snapshot: UsageSnapshot, now: Date) -> BlockingReset.Choice? {
        // Blocked (no path to work: idle-blocked, or active with a main window exhausted and credits
        // not covering) → the "last stand" pick, which may be the credits reset.
        if CreditsPacing.isBlocked(in: snapshot) {
            return BlockingReset.forBlocked(snapshot: snapshot, now: now)
        }
        // Not blocked, but a subscription limit is exhausted **and** paid credits are covering the
        // work: still surface a red badge on the blocking subscription limit's reset — the moment the
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
                            blueAllowed: Bool = true) -> LimitRow {
        let parsed = ResetClock.parse(window.resetsAt)
        let bar = PacingModel.barLayout(
            utilization: window.utilization,
            resetsAt: parsed ?? now,
            now: now,
            window: kind,
            blueAllowed: blueAllowed
        )
        let indicator = PacingModel.limitIndicator(utilization: window.utilization)
        let resetLine = parsed.flatMap { ResetClock.resetLine(resetsAt: $0, now: now) }
        let resetLineVerbose = parsed.flatMap {
            ResetClock.resetLine(resetsAt: $0, now: now, verbose: true)
        }
        return LimitRow(
            title: title,
            utilization: window.utilization,
            pacing: bar.pacing,
            indicator: indicator,
            bar: bar,
            subdivisions: kind.subdivisions,
            resetLine: resetLine,
            resetLineVerbose: resetLineVerbose
        )
    }
}
