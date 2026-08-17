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
    /// The same line with the `"resets in"` lead-in (`ResetClock.resetLine(verbose: true)`):
    /// `"resets in 20h at 03:00"`. Both forms are precomputed because the choice between them is the
    /// **live ⌥ Option state**, which flips while the menu is open and without a re-poll — the same
    /// reason the per-model rows are always built. The view picks; the layout stays ⌥-agnostic.
    /// `nil` in exactly the cases ``resetLine`` is.
    public let resetLineVerbose: String?
    /// Whether this is the **idle** 5-hour row — the 5h window does not exist server-side (no active
    /// session, ``UsageSnapshot/sessionIdle``, #100). When `true` the view renders a green knobless
    /// bar, the status word "ready to start", and **no second (utilization + reset) line at all**; the
    /// numeric fields (`utilization`, `pacing`, `indicator`, the three `reset*`) are inert placeholders
    /// the idle render path ignores. `false` on every normal row.
    public let sessionIdle: Bool
    /// Whether this idle 5-hour row is also **blocked** (#158): the 7-day limit is exhausted and paid
    /// credits cannot cover, so there is no path to start a session. When `true` the view draws the
    /// idle pill **grey** (not green) and shows the status word "waiting for limit reset" instead
    /// of "ready to start". Only ever `true` alongside ``sessionIdle``; `false` on every other row.
    public let sessionBlocked: Bool
    // No `weeklyHeadroom` here since #381: the idle "ready to start" pill is **green** whatever the week
    // is doing, on both surfaces, so the fill no longer needs the weekly verdict carried alongside an
    // inert bar. `PacingModel.weeklyHasHeadroom` is untouched — it still gates `blueAllowed` for every
    // *active* row, which is what ADR-0081 was about.

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
    /// The ⌥ form of ``resetLine``, with the `"resets in"` lead-in — see
    /// ``LimitRow/resetLineVerbose`` for why both are precomputed. `nil` whenever ``resetLine`` is.
    public let resetLineVerbose: String?
    /// Whether paid credits are **actually being spent right now** — `enabled` **and** at least one base
    /// limit is exhausted (`CreditsPacing.shouldShowIcon`, the same gate as the menu-bar icon). Drives
    /// the blue **"in use"** badge next to the heading: the section itself shows whenever credits are
    /// merely *active* (enabled/reached), but the badge appears only while the plan limit is actually
    /// overflowing into credits.
    public let inUse: Bool
    /// The captions for the credits bar's two boundary ticks — the money window's first and last day,
    /// `("Aug 1", "Aug 31")`, from `CreditsPacing.monthBoundaryLabels`. `nil` when there is no
    /// bar to caption (unlimited) or the calendar could not resolve the bounds; the view then draws the
    /// bar without a ruler rather than inventing labels.
    ///
    /// Precomputed here, like ``resetLine``, so the view formats no dates (ADR-0009). These name the
    /// **UTC** month bounds that define the bar's own `0` and `1` — see
    /// `CreditsPacing.monthBoundaryLabels` for why they do not follow ``resetLine``'s local zone.
    public let monthBounds: (start: String, end: String)?

    public init(spent: Money, limit: Money?, bar: BarLayout?, resetLine: String?,
                resetLineVerbose: String? = nil, inUse: Bool = false,
                monthBounds: (start: String, end: String)? = nil) {
        self.spent = spent
        self.limit = limit
        self.bar = bar
        self.resetLine = resetLine
        self.resetLineVerbose = resetLineVerbose
        self.inUse = inUse
        self.monthBounds = monthBounds
    }

    /// Hand-written because a tuple property has no synthesised `==` (tuples are not `Equatable`).
    public static func == (lhs: CreditsRow, rhs: CreditsRow) -> Bool {
        lhs.spent == rhs.spent && lhs.limit == rhs.limit && lhs.bar == rhs.bar
            && lhs.resetLine == rhs.resetLine && lhs.resetLineVerbose == rhs.resetLineVerbose
            && lhs.inUse == rhs.inUse
            && lhs.monthBounds?.start == rhs.monthBounds?.start
            && lhs.monthBounds?.end == rhs.monthBounds?.end
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

    /// The index in ``rows`` at which the **per-model / per-service** rows begin — the first row after
    /// the base `5h`/`7d` pair, i.e. `2` on a normal snapshot. Rows before it are the base limits and
    /// are never gated; rows from here on are the optional group governed by
    /// ``PopupSectionVisibility`` (#211). Equal to ``rows``'s count when a snapshot carries no
    /// per-model windows (empty group).
    ///
    /// The group is expressed as an **index** rather than by dropping the rows here because
    /// `BlockingReset` keys its `.token(id:)` pick to the *full* row order (`0` = 5h, `1` = 7d, then the
    /// per-model windows) and the view matches it with `id == index`. Filtering in this layer would
    /// renumber the rows the view enumerates and mis-paint the red blocking-reset badge; the view
    /// therefore hides rows while keeping their original indices.
    public let perModelRowsStart: Int

    /// Whether any **per-model / per-service** row is orange or red (`PacingSeverity.isNonCalm`) — the
    /// "is this group worth attention?" input to ``PopupSectionVisibility/shows(isNonCalm:isAboveZero:optionHeld:)``.
    /// `false` when the group is empty. Computed here (the pure layer) so the view needs no pacing
    /// knowledge, and recomputed on every poll like the rows themselves.
    public let perModelRowsAreNonCalm: Bool

    /// Whether any **per-model / per-service** row has been used at all (`utilization > 0`) — the
    /// "is there anything in this group?" input to ``PopupSectionVisibility/aboveZero``. `false` when
    /// the group is empty or every row sits at a flat zero.
    ///
    /// Deliberately independent of ``perModelRowsAreNonCalm``: this reads the raw value, that reads the
    /// pacing verdict, and early in a 7-day window a 2 % row is simultaneously above zero *and* orange.
    /// Only the base rows are excluded, exactly as in the non-calm flag.
    public let perModelRowsAreAboveZero: Bool

    /// Whether the **Extra usage** credits section is orange or red — `credits.bar`'s severity, or
    /// `false` when there is no credits section or it is unlimited (`bar == nil`, nothing to pace, so
    /// nothing to be alarmed about).
    public let creditsIsNonCalm: Bool

    /// Whether any money has been spent this period (`credits.spent` non-zero), or `false` when there
    /// is no credits section.
    ///
    /// Reads ``CreditsRow/spent`` and **not** ``CreditsRow/bar`` — that distinction is the whole reason
    /// this flag exists. An unlimited money cap (`spend.limit == null`) produces no bar and therefore no
    /// severity, so ``creditsIsNonCalm`` is permanently `false` there and a `nonCalm` gate would hide a
    /// paying user's spend forever. `spent` is always present (`spentMoney(from:)` falls back to a zero
    /// amount), so this stays meaningful in every credits state.
    public let creditsIsAboveZero: Bool

    /// The Claude Code sessions awaiting user input to advertise flush-right in the "Claude" section
    /// header (#233, ADR-0066), or `nil` to draw nothing. `nil` whenever the feature is off, the count
    /// is `0`, or the watcher isn't running. When non-`nil` (count `≥ 1`) the popup draws a
    /// `hand.raised` icon tinted by ``AwaitingSessions/urgency``; a count of `1` shows the bare icon,
    /// `≥ 2` appends the count. Clicking the block opens the per-project breakdown
    /// (``AwaitingSessions/perProject``). Sourced by the shell from `AwaitingInputWatcher`,
    /// independent of the usage snapshot, so it's supplied to `make` rather than derived from it.
    public let awaitingInput: AwaitingSessions?

    /// The short plan label shown in brand colour right after "Claude" in the header (e.g. "Max 5x"),
    /// or `nil` to draw just "Claude". Derived from the Keychain `rateLimitTier` via
    /// ``claudePlanLabel(rateLimitTier:)`` — like ``awaitingInput``, it comes from a source outside the
    /// usage snapshot (the OAuth payload), so the shell grafts it on via ``withPlanLabel(_:)`` rather
    /// than threading it through `make`.
    public let planLabel: String?

    /// The status-page incidents worth showing (#279), already filtered by ``IncidentVisibility``.
    /// Empty on every ordinary frame. Like ``planLabel`` and ``awaitingInput`` these arrive on the
    /// status poll's own cadence rather than with the usage snapshot, so the shell grafts them on via
    /// ``withIncidents(_:)`` instead of threading them through `make`.
    public let incidents: [VisibleIncident]

    /// What the single subscribe row should show, or `nil` when there is nothing to subscribe to and
    /// the row is omitted entirely (#279).
    public let subscription: EpisodeSubscriptionState?

    /// What the user currently monitors (#341) — the popup's own copy of the mode the menu bar shows
    /// as `zzz` or ⚠️. The view uses it to swap the red failure banner for a plain explanation, to
    /// keep the service rows visible while everything is green, and to read ``lastUpdateAge`` as the
    /// age of the *status* poll rather than the usage poll.
    public let monitoringMode: MonitoringMode

    /// Which data sources are switched on (#341).
    public enum MonitoringMode: Sendable, Equatable {
        /// The usage API is polled — the ordinary case, and every layout that predates #341.
        case usageAndServices
        /// The usage poll is off; status-page services are still watched.
        case servicesOnly
        /// Nothing is monitored at all.
        case nothing
    }

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
        monitoringMode: MonitoringMode = .usageAndServices
    ) {
        self.lastUpdateAge = lastUpdateAge
        self.intervalSeconds = intervalSeconds
        self.rows = rows
        self.warning = warning
        self.serviceStatus = serviceStatus
        self.credits = credits
        self.blockingReset = blockingReset
        // Default: the two base rows come first, so the per-model group starts at 2 — clamped for the
        // short `rows` a cold start / broken-data layout carries (empty, or fewer than two rows).
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
    }

    /// A copy of this layout with **one** field replaced, everything else carried over.
    ///
    /// Every `with*` helper below routes through here. They used to reconstruct the whole value by
    /// hand, which is a standing trap: the compiler cannot tell a dropped field from an intentional
    /// omission, so a field added by one branch and a helper touched by another merge cleanly into
    /// a layout that silently loses data. One copy point means adding a field is one edit.
    private func copy(
        lastUpdateAge: TimeInterval? = nil,
        awaitingInput: AwaitingSessions?? = nil,
        incidents: [VisibleIncident]? = nil,
        subscription: EpisodeSubscriptionState?? = nil,
        planLabel: String?? = nil
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
            monitoringMode: monitoringMode)
    }

    /// A copy of this layout with the awaiting-input count grafted on, everything else unchanged
    /// (#233). The shell calls this on the `make(...)` result so the awaiting indicator — sourced
    /// from `AwaitingInputWatcher`, not the usage snapshot — doesn't have to thread through `make`.
    public func withAwaitingInput(_ awaitingInput: AwaitingSessions?) -> PopupLayout {
        copy(awaitingInput: .some(awaitingInput))
    }

    /// A copy of this layout with the status-page incidents grafted on, everything else unchanged
    /// (#279). Incidents ride the status poll, not the usage poll, so the shell calls this on the
    /// `make(...)` result exactly as it does for the awaiting-input breakdown.
    public func withIncidents(_ incidents: [VisibleIncident]) -> PopupLayout {
        copy(incidents: incidents)
    }

    /// A copy of this layout with the subscribe row's state grafted on (#279). `nil` omits the row.
    public func withSubscription(_ subscription: EpisodeSubscriptionState?) -> PopupLayout {
        copy(subscription: .some(subscription))
    }

    /// A copy of this layout whose ``lastUpdateAge`` is measured from the **status** poll instead of
    /// the usage poll (#341) — used only in ``MonitoringMode/servicesOnly``, where the usage clock is
    /// deliberately stopped and reporting its age would be a lie ("0 s ago" for data nobody fetched).
    ///
    /// A graft rather than a `make` parameter, following ``withIncidents(_:)`` and
    /// ``withSubscription(_:)``: like those, this value rides the status poll's own cadence, so it
    /// arrives outside the usage snapshot and threading it through `make` would touch every call site
    /// for a value most of them do not have.
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

    // MARK: make

    /// Build the popup layout from one usage snapshot at instant `now`.
    ///
    /// - Parameters:
    ///   - snapshot: A decoded usage poll (`UsageClient`/#9).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - lastUpdate: Instant of the last successful 200 (→ `lastUpdateAge`). Mock today; real with #13.
    ///   - interval: Current polling interval in seconds (`PollingBackoff.interval`). Mock today.
    ///
    /// The per-model rows are **always** built (#211 → the tri-state `PopupSectionVisibility`): whether
    /// they are drawn is the view's call, since it depends on the live ⌥ Option state, which changes
    /// while the menu is open and without a re-poll. ``perModelRowsStart`` and
    /// ``perModelRowsAreNonCalm`` carry everything the view needs to decide.
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
    ///
    /// As in the other overload, the per-model rows are always built; ``perModelRowsStart`` /
    /// ``perModelRowsAreNonCalm`` / ``creditsIsNonCalm`` let the view apply the user's
    /// ``PopupSectionVisibility`` against the live ⌥ state (#211).
    ///   - monitoringAnything: Whether anything is monitored at all (#341). `false` produces a layout
    ///     with no rows and no red banner — nothing is broken, so the view explains the state in
    ///     words instead. Default `true`.
    public static func make(
        from snapshot: UsageSnapshot?,
        health: UsageHealth,
        now: Date,
        interval: TimeInterval,
        serviceStatus: StatusHealth? = nil,
        monitoringAnything: Bool = true
    ) -> PopupLayout {
        let lastUpdateAge = health.lastSuccess.map { max(0, now.timeIntervalSince($0)) } ?? 0

        // #341, ahead of every failure branch below — for the same reason as in `MenuBarLayout`: these
        // are user choices, and the failure machinery would otherwise dress them up as breakage. In
        // both modes there are no rows: whatever snapshot survived is not being refreshed, and drawing
        // bars from it would present frozen numbers as current.
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
        // (`hasBrokenActiveReset`, #167/ADR-0043). Unlike a *health* failure (where the last **good**
        // snapshot's stale rows are still worth showing), here the current snapshot itself is corrupt, so
        // there is nothing trustworthy to render: show **only** the red warning banner (`.serverProblem`),
        // with no limit rows / credits / blocking-reset — the same shape as a cold-start failure.
        //
        // Note the guard is `!isFailing`, which #341's third state would also satisfy: a stale snapshot
        // with a broken reset would raise a red server-problem banner in a mode where nothing is being
        // fetched. The monitoring branches above return before reaching here, which is why this line
        // needs no condition of its own.
        let brokenData = !health.isFailing && (snapshot?.hasBrokenActiveReset == true)
        if brokenData {
            return PopupLayout(
                lastUpdateAge: lastUpdateAge, intervalSeconds: interval, rows: [],
                warning: .serverProblem, serviceStatus: serviceStatus)
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
    /// from `limits[]` (e.g. `Fable`, #65; already deduped against the legacy rows by
    /// ``UsageSnapshot/scopedModelWindows``). All per-model rows are paced as `.sevenDay`.
    ///
    /// The per-model rows are **always** included — visibility is the view's decision (#211, see
    /// ``PopupSectionVisibility``), and dropping them here would renumber the indices `BlockingReset`
    /// depends on.
    ///
    /// Shared by both ``make`` overloads.
    private static func rows(
        from snapshot: UsageSnapshot, now: Date
    ) -> [LimitRow] {
        // The 5-hour row is the idle placeholder when the window has no active session (#100); every
        // other row is built normally, including the 7-day one (which always exists). When idle is also
        // **blocked** (#158) the placeholder carries `sessionBlocked` so the view greys it and swaps the
        // status word to "waiting for limit reset". (An *active* fully-exhausted 5h row is not idle, so
        // it shows the normal "limit reached" — only the red blocking-reset badge marks it, via
        // `blockingReset`.)
        let idleBlocked = snapshot.sessionIdle && CreditsPacing.isBlocked(in: snapshot)
        // The weekly gate (`PacingModel.weeklyHasHeadroom`): blue is "there is room to push", so every
        // row that spends from the weekly budget — the 5-hour window and the 7-day-paced per-model
        // rows — may only go blue while the 7-day window itself has headroom. The 7-day row never
        // gates on itself.
        let weeklyHeadroom = PacingModel.weeklyHasHeadroom(in: snapshot, now: now)
        var rows: [LimitRow] = [
            snapshot.sessionIdle ? idleFiveHourRow(blocked: idleBlocked) : row(title: "5-hour", window: snapshot.fiveHour, as: .fiveHour, now: now, blueAllowed: weeklyHeadroom),
            row(title: "7-day", window: snapshot.sevenDay, as: .sevenDay, now: now, blueAllowed: true),
        ]
        if let opus = snapshot.sevenDayOpus {
            rows.append(row(title: "Opus", window: opus, as: .sevenDay, now: now, blueAllowed: weeklyHeadroom))
        }
        if let sonnet = snapshot.sevenDaySonnet {
            rows.append(row(title: "Sonnet", window: sonnet, as: .sevenDay, now: now, blueAllowed: weeklyHeadroom))
        }
        for scoped in snapshot.scopedModelWindows {
            rows.append(row(title: scoped.name, window: scoped.window, as: .sevenDay, now: now, blueAllowed: weeklyHeadroom))
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
        let monthEnd = bar == nil ? nil : CreditsPacing.monthEnd(now: now)
        let resetLine = monthEnd.flatMap { ResetClock.resetLine(resetsAt: $0, now: now) }
        let resetLineVerbose = monthEnd.flatMap {
            ResetClock.resetLine(resetsAt: $0, now: now, verbose: true)
        }
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
        // Boundary captions for the bar's own ruler — only when there *is* a bar to caption.
        let monthBounds = bar == nil ? nil : CreditsPacing.monthBoundaryLabels(now: now)
        return CreditsRow(
            spent: spent, limit: spend.limit, bar: bar, resetLine: resetLine,
            resetLineVerbose: resetLineVerbose, inUse: inUse, monthBounds: monthBounds)
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
    /// reset line `nil`, and an inert zeroed bar (the view draws a grey track plus a zero pill and skips
    /// the second line). `subdivisions` stays the 5-hour value so the under-bar tick ruler keeps the
    /// row's anatomy in family with the active rows; the numeric fields are placeholders the idle render
    /// path ignores.
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
