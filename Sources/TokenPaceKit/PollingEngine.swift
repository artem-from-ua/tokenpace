import Foundation

// MARK: - Seams (injected dependencies)

/// A signal pushed into the loop from outside — system sleep/wake (`NSWorkspace`) or a network
/// transition (`NWPathMonitor`). The shell owns the platform observers and feeds these to the
/// scheduler; the engine stays free of AppKit/Network so it is unit-tested with a stub scheduler.
public enum PollSignal: Sendable, Equatable {
    /// The system is about to sleep, or (opt-in) the screen locked / turned off / a screensaver
    /// started → pause polling (no fetch while parked). See `ScreenLockObserver` for the screen path.
    case sleep
    /// The system woke, or the screen came back → resume. Polls immediately **only if the cache has
    /// gone stale** (≥ interval since the last success); a wake while the data is still fresh just
    /// re-arms the wait, so a blinking screen can't hammer the API (ADR-0032 D6, `wakeRearmInterval`).
    case wake
    /// Connectivity returned after a drop → same conditional re-poll as `.wake` (fetch now only if the
    /// cache is stale). On a cold start / still-failing state there is no fresh cache, so it fetches.
    case networkRestored
    /// The user asked for an immediate refresh (Troubleshoot window button) → poll now **and** clear
    /// any active 429 hold. Unlike `.wake`/`.networkRestored`, this always fetches (no staleness
    /// check) and clears the hold: a deliberate user action, honoured even mid-rate-limit.
    case manualRefresh
}

/// Why a `waitForNextPoll` returned — the interval elapsed normally, or a signal cut it short.
public enum PollWakeReason: Sendable, Equatable {
    /// The full interval passed → this is a scheduled poll.
    case elapsed
    /// A signal fired before the interval elapsed → an off-schedule poll (`.wake` / `.networkRestored`),
    /// or a request to park (`.sleep`).
    case interrupted(PollSignal)
}

/// The wait-between-polls seam. Production races `Task.sleep(interval)` against the next
/// `PollSignal`; tests drive it deterministically (hand back `.elapsed` or `.interrupted(...)`),
/// so the loop's "wake → immediate poll" / "sleep → park" behaviour is unit-tested without real
/// time, real sleep, or a real network.
public protocol PollScheduler: Sendable {
    /// Suspend up to `interval` seconds, returning early as soon as a signal arrives.
    func waitForNextPoll(interval: TimeInterval) async -> PollWakeReason
    /// Park indefinitely after a `.sleep` signal, returning once `.wake`/`.networkRestored` fires —
    /// so no fetch runs while the Mac is asleep.
    func waitWhileAsleep() async
}

/// The token seam — a one-method protocol over `TokenProvider.currentCredentials(now:)` so the
/// engine is tested without touching the Keychain (`Security`). Production is
/// ``KeychainTokenProvider``; tests inject a stub that returns literal credentials or throws a
/// `TokenError`.
///
/// Since ADR-0020 this returns ``TokenCredentials`` (token **plus** `expiresAt`), not a bare token:
/// the engine — not the provider — judges expiry, so a stale token still returns here (with a past
/// `expiresAt`) and the engine decides whether to short-circuit / refresh. The single read also
/// feeds ``TokenDiagnostics``.
public protocol TokenProviding: Sendable {
    func currentCredentials(now: Date) throws -> TokenCredentials
}

/// Production token seam — a thin `struct` wrapper over the static `TokenProvider` (a `static enum`
/// cannot conform to a protocol directly). Reads the Keychain on every poll, so a token refreshed
/// by Claude Code is picked up on the next cycle (ADR-0008 §2).
public struct KeychainTokenProvider: TokenProviding {
    public init() {}
    public func currentCredentials(now: Date) throws -> TokenCredentials {
        try TokenProvider.currentCredentials(now: now)
    }
}

/// Whether a Claude **Code** session is running on this Mac — the gate for the 15-min idle override
/// (no active session → poll every 15 min; a session → the 3-min base). A seam because process
/// enumeration is a platform side-effect; production is `ProcessClaudeActivityProbe` in the shell,
/// tests inject a `StubProbe` returning a fixed `Bool`.
public protocol ClaudeActivityProbe: Sendable {
    func isClaudeRunning() -> Bool
}

// MARK: - PollOutput

/// One iteration's result, mapped by the shell into `MenuBarLayout`/`PopupLayout`. Carries the
/// **last known** snapshot (stale-safe: kept across failures) so the bars survive an outage, the
/// `health` driving error states, and the **effective** interval for the popup's "Update interval"
/// line.
public struct PollOutput: Sendable, Equatable {
    public let snapshot: UsageSnapshot?
    public let health: UsageHealth
    public let interval: TimeInterval
    /// Raw diagnostics of **this** poll attempt for the Troubleshoot window (ADR-0020) — the exact
    /// HTTP status, full response body, and token dates. `nil` only for outputs built without a real
    /// attempt (e.g. a hand-constructed test fixture); every live iteration fills it.
    public let diagnostics: PollDiagnostics?
    /// The weekly utilization in both forms (#386) — the API's quantised integer and the value
    /// reconstructed from the five-hour counter — for the snapshot above.
    ///
    /// `nil` when there is no snapshot to describe. Carried beside `snapshot` rather than folded
    /// into it so the shell can disclose *both* numbers (Troubleshoot, the journal) while the
    /// renderers see only the effective one, via ``WeeklyUtilization/applied(to:)``.
    public let weekly: WeeklyUtilization?

    public init(
        snapshot: UsageSnapshot?,
        health: UsageHealth,
        interval: TimeInterval,
        diagnostics: PollDiagnostics? = nil,
        weekly: WeeklyUtilization? = nil
    ) {
        self.snapshot = snapshot
        self.health = health
        self.interval = interval
        self.diagnostics = diagnostics
        self.weekly = weekly
    }
}

// MARK: - Pure core: PollState / PollOutcome / advance

/// The outcome of one poll attempt — the input to the pure
/// ``PollingEngine/advance(previous:outcome:refresh:claudeActive:now:)``.
public enum PollOutcome: Sendable, Equatable {
    case success(UsageSnapshot)
    case tokenError(TokenError)
    case usageError(UsageError)
}

/// The engine's accumulated state between polls — the pure value the loop threads through
/// ``PollingEngine/advance(previous:outcome:refresh:claudeActive:now:)``. Holds the 429 hold
/// (``PollingBackoff``), the latest activity reading, and the inputs ``UsageHealth`` needs
/// (`lastSuccess`/`failingSince`/`reason`) plus the stale-safe `lastSnapshot`.
public struct PollState: Sendable, Equatable {
    public var backoff: PollingBackoff
    public var claudeActive: Bool
    public var lastSuccess: Date?
    public var failingSince: Date?
    public var lastSnapshot: UsageSnapshot?
    public var reason: FailureReason?
    /// Anti-flap gate for delegated-refresh attempts (ADR-0017) — blocks a respawn of the
    /// `claude` CLI for an escalating cooldown after each failed attempt.
    public var refreshGate: RefreshGate
    /// Deadline until which a spurious 5h session-idle is suppressed on a reset boundary
    /// (ADR-0041). Non-nil only while an active 5h window has just flipped to idle and we are still
    /// within the grace window; `nil` in the steady state. See ``applyIdleGrace(decoded:previous:activeUntil:now:claudeActive:)``.
    public var idleSuppressedUntil: Date?
    /// The `now` of the last poll whose 5h `utilization` **rose** vs the previous poll — the
    /// freshness clock for "real token spend happened recently" (ADR-0045). In-memory only (dies on
    /// relaunch): it gates the reset-boundary grace, and after a relaunch the grace has no prior
    /// window to protect anyway. `nil` until the first observed rise. Read by ``applyIdleGrace``.
    public var lastUtilizationChange: Date?
    /// Whether the usage API is deliberately not being polled (#341). Projected into
    /// ``UsageHealth/notPolling``; see ``PollingEngine/enteringServiceOnlyMode(_:previous:)`` for why
    /// entering this mode also clears `lastSnapshot`.
    public var notPolling: Bool = false
    /// The weekly-utilization reconstruction (#386) — the running estimate of the 5h↔7d exchange
    /// rate plus the accumulation since the last observed weekly bump.
    ///
    /// Lives here for the same reason ``lastUtilizationChange`` does: it is a fact about the
    /// *sequence* of polls, not about any single one, and ``PollingEngine/advance(previous:outcome:refresh:claudeActive:now:)``
    /// is the one seam that sees two consecutive snapshots. Unlike that stamp, this one is worth
    /// persisting across relaunches — the ratio takes ~20 h of active work to fill its window, so
    /// dropping it on every restart would keep the feature permanently cold (see
    /// ``WeeklyInterpolator/resumed(at:)`` for what survives a break and what does not).
    public var weeklyInterpolator: WeeklyInterpolator = WeeklyInterpolator()

    /// Cold start: healthy backoff (no hold), no data yet. `claudeActive` defaults to `true` so the
    /// very first interval is the responsive 3-min base until the first probe.
    public init(
        backoff: PollingBackoff = PollingBackoff(),
        claudeActive: Bool = true,
        lastSuccess: Date? = nil,
        failingSince: Date? = nil,
        lastSnapshot: UsageSnapshot? = nil,
        reason: FailureReason? = nil,
        refreshGate: RefreshGate = RefreshGate(),
        idleSuppressedUntil: Date? = nil,
        lastUtilizationChange: Date? = nil,
        notPolling: Bool = false,
        weeklyInterpolator: WeeklyInterpolator = WeeklyInterpolator()
    ) {
        self.backoff = backoff
        self.claudeActive = claudeActive
        self.lastSuccess = lastSuccess
        self.failingSince = failingSince
        self.lastSnapshot = lastSnapshot
        self.reason = reason
        self.refreshGate = refreshGate
        self.idleSuppressedUntil = idleSuppressedUntil
        self.lastUtilizationChange = lastUtilizationChange
        self.notPolling = notPolling
        self.weeklyInterpolator = weeklyInterpolator
    }

    /// The `UsageHealth` view-model input derived from this state.
    ///
    /// `pollInterval` carries the cadence polls are currently attempted at, because the menu bar's ⚠️
    /// threshold is expressed in *attempts*, not wall-clock minutes (`UsageHealth.glyphAfter(for:)`) —
    /// 15 min means five failures during a session and one while idle, and only the second of those
    /// deserves a warning.
    public var health: UsageHealth {
        UsageHealth(
            lastSuccess: lastSuccess, failingSince: failingSince, reason: reason,
            notPolling: notPolling, pollInterval: PollingEngine.effectiveInterval(self))
    }
}

// MARK: - Interval decision (for logging)

/// Why the effective interval changed between two polls — the payload of the **one log line per
/// interval change** the user asked for. Computed by ``PollingEngine/intervalDecision(previous:next:)``,
/// which returns `nil` when the interval did not move (so the loop logs only real changes, never spam —
/// the same "only on change" discipline as `StatusItemView.layout`, ADR-0009).
public struct IntervalDecision: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        /// No Claude Code session running → the 15-min idle override took effect.
        case claudeInactive
        /// A Claude Code session reappeared → back to the 3-min base.
        case claudeActiveResumed
        /// HTTP 429 → the server hold took over (overrides the idle/base).
        case rateLimited
        /// A 200 cleared an active 429 hold → back to the idle/base.
        case rateLimitCleared
    }

    public let from: TimeInterval
    public let to: TimeInterval
    public let cause: Cause

    public init(from: TimeInterval, to: TimeInterval, cause: IntervalDecision.Cause) {
        self.from = from
        self.to = to
        self.cause = cause
    }

    /// A `.public`-safe one-liner for `AppLogger.lifecycle`, e.g. "interval 3m→6m: usage unchanged".
    public var logMessage: String {
        "interval \(Self.mins(from))→\(Self.mins(to)): \(Self.phrase(cause))"
    }

    private static func mins(_ seconds: TimeInterval) -> String {
        let m = seconds / 60
        // Whole minutes render as "3m"; anything else falls back to seconds for honesty.
        return m == m.rounded() ? "\(Int(m))m" : "\(Int(seconds))s"
    }

    private static func phrase(_ cause: Cause) -> String {
        switch cause {
        case .claudeInactive:      return "no Claude Code session — idle override"
        case .claudeActiveResumed: return "Claude Code session active — resuming base cadence"
        case .rateLimited:         return "rate-limited (HTTP 429) — honoring Retry-After"
        case .rateLimitCleared:    return "rate-limit cleared — resuming base cadence"
        }
    }
}

// MARK: - PollingEngine

/// The live polling loop's brain — drives `Keychain → UsageClient` on a schedule, reacting to
/// sleep/wake, network changes, the data changing, and whether a Claude Code session is running.
///
/// **Pure core + thin shell** (the ADR-0008/0009/0010 pattern): all decision logic
/// (``advance(previous:outcome:refresh:claudeActive:now:)``, ``effectiveInterval(_:)``,
/// ``intervalDecision(previous:next:)``) is pure and table-tested; the `async` ``run()`` loop wires
/// it to injected seams (`UsageTransport`, `TokenProviding`, `DelegatedRefresher`, `PollScheduler`,
/// `ClaudeActivityProbe`, a `now` clock). The shell (`AppDelegate`) supplies the live seams and consumes the output stream
/// on `@MainActor`. The engine itself is **not** `@MainActor`, so tests never need the main actor.
///
/// ## Interval model — a fixed 3-min base with two overrides (ADR-0032)
/// ``effectiveInterval(_:)`` picks the wait with this priority (higher wins), floored at
/// ``minInterval``:
/// 1. **429 Retry-After hold** (``PollingBackoff``) — if holding, wait exactly the honored interval
///    (server told us to slow down; honour it above everything). No escalation across 429s.
/// 2. **Claude-inactive 15-min override** — no session → poll rarely.
/// 3. **Base** — otherwise a flat ``baseInterval`` (180 s).
///
/// The **reset-triggered immediate poll** is *not* an interval rule here — it is owned by the shell's
/// optimistic-reset timer (#36), which fires exactly on `resets_at`, overlays a zero-usage bar, and
/// forces a `.manualRefresh`. Keeping it there (rather than duplicating a reset-cap in this interval
/// math) is the single-source-of-truth choice recorded in ADR-0032.
public struct PollingEngine: Sendable {

    /// The healthy base cadence — 180 s (SPEC "Частота оновлення"). The floor every override narrows
    /// from, and the value the loop returns to after a 429 clears.
    public static let baseInterval: TimeInterval = 180

    /// The interval used when no Claude Code session is running — a hard override. 15 min (user
    /// decision, ADR-0032; halved from the earlier 30 min so an idle-but-present user still sees data
    /// refresh within a quarter hour).
    public static let inactiveInterval: TimeInterval = 15 * 60

    /// The **hard floor** on the gap between any two polls — a safety rail independent of the
    /// scheduler. Even if a scheduler returned instantly (a bug we shipped once: a broken signal
    /// iterator made `waitForNextPoll` return with no delay, hammering the API ~50×/s and tripping a
    /// 429), the loop sleeps at least this long between requests. 60 s is comfortably below the
    /// 180 s base cadence, so it never slows normal operation; it only caps the worst case.
    /// Enforced twice: `effectiveInterval` never returns less, and `run()` re-checks elapsed wall
    /// time after every wait. `minIntervalNeverBelowFloor` and `loopNeverPollsFasterThanFloor` guard
    /// both rails in tests.
    public static let minInterval: TimeInterval = 60

    /// How long a spurious 5h session-idle is suppressed after an active window flips to idle on a
    /// reset boundary (ADR-0041). Right after a 5h reset the server briefly (~one poll, ~3 min)
    /// returns `five_hour` with no `resets_at` — the new window is only created by the first token
    /// spend — so the decoder honestly reports `sessionIdle: true`. That is a boundary blip, not a
    /// real idle: we hold the "ready" bar for this window, and only surface a genuine idle if the
    /// window still has not reappeared once it elapses. 5 min covers one or two base-cadence polls
    /// with margin while keeping a true idle from hiding for long.
    public static let idleGraceWindow: TimeInterval = 5 * 60

    /// How recently 5h utilization must have risen for the reset-boundary grace to arm (ADR-0045). A
    /// rise means real token spend; if none happened within this window the pause is genuine and idle
    /// surfaces immediately. 15 min ≈ several base-cadence polls — long enough to bridge a short lull
    /// between prompts, short enough that a truly-parked session is not held warm across a reset.
    public static let utilFreshnessWindow: TimeInterval = 15 * 60

    let transport: UsageTransport
    let tokenProvider: TokenProviding
    let refresher: DelegatedRefresher?
    let scheduler: PollScheduler
    let probe: ClaudeActivityProbe
    let now: @Sendable () -> Date
    /// Whether to poll the usage API at all (#341), read **live at the top of every iteration** —
    /// the same discipline as the journal seam. The shell closes over `PersistedConfig`, so a toggle
    /// in Settings takes effect on the next tick without reconfiguring the engine; the accompanying
    /// `.manualRefresh` signal is what makes "the next tick" mean *now* rather than up to an interval
    /// later. Defaults to always-on so every existing construction site reads unchanged.
    let usageApiEnabled: @Sendable () -> Bool
    /// The weekly reconstruction state to start from (#386) — the shell hands back what it persisted,
    /// so the ratio survives a relaunch instead of re-warming for ~20 h of active work. Defaults to a
    /// fresh estimator, so every existing construction site (and every test) reads unchanged.
    let restoreWeekly: @Sendable () -> WeeklyInterpolator
    /// Called whenever that state advances, so the shell can persist it. Same seam discipline as
    /// `usageApiEnabled`: the Kit owns the value, the shell owns the storage. Defaults to a no-op.
    let persistWeekly: @Sendable (WeeklyInterpolator) -> Void

    public init(
        transport: UsageTransport,
        tokenProvider: TokenProviding = KeychainTokenProvider(),
        refresher: DelegatedRefresher? = nil,
        scheduler: PollScheduler,
        probe: ClaudeActivityProbe,
        now: @escaping @Sendable () -> Date,
        usageApiEnabled: @escaping @Sendable () -> Bool = { true },
        restoreWeekly: @escaping @Sendable () -> WeeklyInterpolator = { WeeklyInterpolator() },
        persistWeekly: @escaping @Sendable (WeeklyInterpolator) -> Void = { _ in }
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.refresher = refresher
        self.scheduler = scheduler
        self.probe = probe
        self.now = now
        self.usageApiEnabled = usageApiEnabled
        self.restoreWeekly = restoreWeekly
        self.persistWeekly = persistWeekly
    }

    // MARK: Pure transitions

    /// Fold one poll outcome into the next state. No clock, no I/O — `now` is injected. The single
    /// source of the engine's behaviour, exhaustively table-tested.
    ///
    /// - `success`: clear the 429 hold, mark `lastSuccess = now`, clear the failure; keep the snapshot
    ///   as the new `lastSnapshot` (also the reset-cap's source of the nearest `resets_at`).
    /// - `usageError(.rateLimited)`: enter/refresh the 429 hold honouring `Retry-After` (no
    ///   escalation across 429s); begin/continue the failure run; **keep** `lastSnapshot` (stale).
    /// - other `usageError`: same as above but **do not** hold (offline/timeout/5xx are not a 429 —
    ///   staying at the base cadence lets recovery happen promptly).
    /// - `tokenError`: the loop skipped the network entirely; record the failure, touch neither
    ///   the hold nor the snapshot.
    ///
    /// `refresh` is the delegated-refresh attempt made during this poll (`nil` → none, ADR-0017):
    /// an attempt that actually fixed the token (`.refreshed` and the outcome is no longer an
    /// expired-token error) resets the ``RefreshGate``; any other attempt escalates its cooldown.
    public static func advance(
        previous: PollState,
        outcome: PollOutcome,
        refresh: DelegatedRefreshOutcome? = nil,
        claudeActive: Bool,
        now: Date
    ) -> PollState {
        var next = previous
        next.claudeActive = claudeActive

        if let refresh {
            let stillExpired = outcome == .tokenError(.expired)
            next.refreshGate = (refresh == .refreshed && !stillExpired)
                ? previous.refreshGate.afterSuccess()
                : previous.refreshGate.afterFailure(now: now)
        }

        switch outcome {
        case let .success(snapshot):
            next.backoff = previous.backoff.reset()
            next.lastSuccess = now
            next.failingSince = nil
            next.reason = nil
            // Stamp the util-freshness clock (ADR-0045): a *rise* in 5h utilization means real token
            // spend just happened. This gates the reset-boundary grace so a genuine pause (no recent
            // spend) surfaces idle immediately instead of holding a bar. A reset drops utilization to
            // 0 — not a rise — so the boundary itself never disturbs the stamp; it keeps the pre-reset
            // spend time until the *next* real spend. On the first poll (no previous snapshot) any
            // non-zero utilization counts as a rise from the implicit zero baseline.
            let previousUtil = previous.lastSnapshot?.fiveHour.utilization ?? 0
            if snapshot.fiveHour.utilization > previousUtil {
                next.lastUtilizationChange = now
            }
            // Fold the poll into the weekly reconstruction (#386), reading the **decoded** snapshot
            // rather than the idle-grace rebuild below: the grace only masks a spurious 5h idle, and
            // rolling a window forward for the UI must not be mistaken for spend.
            next.weeklyInterpolator = previous.weeklyInterpolator.advanced(with: snapshot, now: now)
            // Suppress a spurious session-idle in the seconds after a 5h reset (ADR-0041/0045). The
            // rebuilt snapshot (idle held off, or a genuine idle passed through) becomes lastSnapshot.
            let (rendered, until) = Self.applyIdleGrace(
                decoded: snapshot, previous: previous.lastSnapshot,
                activeUntil: previous.idleSuppressedUntil, now: now,
                claudeActive: claudeActive,
                lastUtilizationChange: previous.lastUtilizationChange)
            next.idleSuppressedUntil = until
            next.lastSnapshot = rendered

        case let .usageError(error):
            if case let .rateLimited(retryAfter) = error {
                // A 429 is the server saying "not so fast", not "the data is unavailable". It gets the
                // backoff hold and the popup's reason line, but it does **not** start (or extend) the
                // failure run that ages the menu bar into ⚠️ — a `Retry-After` of several minutes would
                // otherwise trip the glyph threshold on its own, reporting a fault where the system is
                // working exactly as designed (ADR-0091).
                next.backoff = previous.backoff.honoring(retryAfter: retryAfter)
                next.reason = FailureReason(error)
                next.failingSince = previous.failingSince   // preserved, never started
                break
            }
            recordFailure(into: &next, previous: previous, reason: FailureReason(error), now: now)

        case let .tokenError(error):
            recordFailure(into: &next, previous: previous, reason: FailureReason(error), now: now)
        }

        return next
    }

    /// Fold "the usage poll is off" into the state (#341) — the transition the loop applies instead
    /// of polling, when the seam reports the usage API disabled.
    ///
    /// **Clears `lastSnapshot`, deliberately.** Keeping it would create a pair that never existed
    /// before — "not failing, and a snapshot in hand" — while nothing refreshes that snapshot. That
    /// pair is what breaks the naive consumers: the popup would draw bars from frozen data, the
    /// broken-reset banner would fire off a stale reading, and the back-to-work / extra-usage edge
    /// detectors (whose guards are exactly `failingSince == nil` + `let snapshot`) would re-trigger on
    /// every tick. Dropping the snapshot removes the fuel rather than patching each consumer.
    ///
    /// `lastSuccess` survives: it is honest history ("this is when we last had data"), and the popup
    /// needs it to explain how old the numbers were. No failure is invented — not asking is not
    /// failing — and the 429 hold is reset, so re-enabling the poll starts clean.
    public static func enteringServiceOnlyMode(previous: PollState, claudeActive: Bool) -> PollState {
        var next = previous
        next.claudeActive = claudeActive
        next.notPolling = true
        next.lastSnapshot = nil
        next.failingSince = nil
        next.reason = nil
        next.backoff = previous.backoff.reset()
        next.idleSuppressedUntil = nil
        return next
    }

    /// Fold "the usage poll is back on" into the state (#341). Only lifts the flag — the next real
    /// poll fills in data or records a failure the usual way.
    public static func leavingServiceOnlyMode(previous: PollState) -> PollState {
        var next = previous
        next.notPolling = false
        return next
    }

    /// Set `failingSince` on the **first** failure after a success, preserve it on subsequent
    /// consecutive failures, and record the reason. `lastSuccess`/`lastSnapshot` are left as-is so
    /// the menu bar can show stale data and age it.
    private static func recordFailure(
        into next: inout PollState,
        previous: PollState,
        reason: FailureReason,
        now: Date
    ) {
        next.failingSince = previous.failingSince ?? now
        next.reason = reason
    }

    /// The interval to wait before the next poll, with the priority 429 hold > idle > base (see the
    /// type doc). Never returns below ``minInterval`` — the first of two rails that make a tight
    /// request loop impossible.
    public static func effectiveInterval(_ state: PollState) -> TimeInterval {
        max(minInterval, rawInterval(state))
    }

    /// The interval before the ``minInterval`` floor is applied — the pure priority combination.
    private static func rawInterval(_ state: PollState) -> TimeInterval {
        if state.backoff.isHolding {              // an active 429 hold overrides everything
            return state.backoff.interval
        }
        if !state.claudeActive {                  // no Claude Code session → hard 15-min override
            return inactiveInterval
        }
        return baseInterval                       // otherwise the flat 3-min base
    }

    /// The wait to re-arm after a redundant `.wake` / `.networkRestored`, or `nil` when the loop
    /// should poll immediately (ADR-0032 D6). Returns `nil` — poll now — when the cache is already
    /// stale (`interval` or more since the last success) **or** there is no prior success yet (cold
    /// start / still-failing: a wake must be free to fetch). Otherwise returns the remaining time
    /// until the cache would be stale, floored at ``minInterval`` so a burst of wakes can never
    /// tighten the cadence below the safety rail. Pure — `now` is injected.
    static func wakeRearmInterval(
        lastSuccess: Date?, interval: TimeInterval, now: Date
    ) -> TimeInterval? {
        guard let lastSuccess else { return nil }        // no success yet → let the wake fetch
        let remaining = interval - now.timeIntervalSince(lastSuccess)
        guard remaining > 0 else { return nil }          // cache already stale → poll now
        return max(minInterval, remaining)
    }

    /// Why the effective interval changed from `previous` to `next`, or `nil` if it did not move.
    /// The loop logs exactly the non-nil results, one line per real change.
    public static func intervalDecision(previous: PollState, next: PollState) -> IntervalDecision? {
        let from = effectiveInterval(previous)
        let to = effectiveInterval(next)
        guard from != to else { return nil }
        return IntervalDecision(from: from, to: to, cause: cause(previous: previous, next: next))
    }

    /// Attribute an interval change to the rule that drove it, checked in priority order so the
    /// reported cause matches which rule actually owns the new interval.
    private static func cause(previous: PollState, next: PollState) -> IntervalDecision.Cause {
        if next.backoff.isHolding { return .rateLimited }
        if previous.backoff.isHolding { return .rateLimitCleared }   // 429 just cleared on a 200

        // The only remaining interval mover is the Claude-active/idle flip.
        return next.claudeActive ? .claudeActiveResumed : .claudeInactive
    }

    // MARK: Weekly ratio (for logging)

    /// How far the weekly exchange rate must move before it is worth a log line — 5 %.
    ///
    /// The estimate is a rolling median over quantised samples, so it twitches by a few percent as
    /// the window slides; logging every twitch would flood the `network` category. A genuine plan or
    /// promotion change moves it by tens of percent (the observed "+50 % weekly limit" promo would
    /// move N from 10 to 15), so this floor separates noise from news.
    static let weeklyRatioLogThreshold = 0.05

    /// The one line to log when the weekly exchange rate moves materially, or `nil` when it did not
    /// — the same "only on change" discipline as ``intervalDecision(previous:next:)``.
    ///
    /// Also fires on the **first** real estimate (the seed being displaced), because that is the
    /// moment the reconstruction starts speaking for this user's own data rather than a default.
    static func weeklyRatioLog(previous: PollState, next: PollState) -> String? {
        let before = previous.weeklyInterpolator.ratio
        let after = next.weeklyInterpolator.ratio
        guard after.sampleCount > 0 else { return nil }

        let moved = abs(after.estimate - before.estimate) / max(before.estimate, 0.001)
        let firstEstimate = before.sampleCount == 0
        guard firstEstimate || moved >= weeklyRatioLogThreshold else { return nil }

        return String(format: "weekly ratio N=%.1f (%d samples)", after.estimate, after.sampleCount)
    }

    // MARK: Session-idle transition (for logging)

    /// The one-time log line when the 5-hour session-idle state flips (#100, ADR-0027), or `nil` when it
    /// did not change — so the loop logs a transition **once**, not the idle state on every poll (the
    /// same "only on change" discipline as `intervalDecision`).
    ///
    /// - `nil`/active → idle (`current` snapshot is idle, `previous` was absent or active): the 5h
    ///   window stopped existing server-side ⇒ `"five_hour idle — no active session (resets_at absent)"`.
    /// - idle → active (`previous` was idle, `current` is not): a new session opened the window ⇒
    ///   `"five_hour window active again"`.
    /// - no change (both idle, both active, or `current == nil`): `nil`.
    ///
    /// Compares the snapshots' ``UsageSnapshot/sessionIdle`` only; a `nil` `current` (cold-start
    /// failure, no snapshot yet) is treated as "no transition" so a failing first poll logs nothing.
    public static func sessionIdleTransition(previous: UsageSnapshot?, current: UsageSnapshot?) -> String? {
        guard let current else { return nil }
        let wasIdle = previous?.sessionIdle ?? false
        switch (wasIdle, current.sessionIdle) {
        case (false, true): return "five_hour idle — no active session (resets_at absent)"
        case (true, false): return "five_hour window active again"
        default:            return nil
        }
    }

    // MARK: Session-idle grace on reset boundary (ADR-0041, refined ADR-0045)

    /// Suppress a spurious 5h session-idle that appears in the seconds after a reset (ADR-0041/0045).
    ///
    /// A 5h reset destroys the window; the next one is created only by the first token spend. In the
    /// gap the server returns `five_hour` with no `resets_at`, so the stateless decoder honestly
    /// reports ``UsageSnapshot/sessionIdle`` `= true`. When the **previous** poll held a genuinely
    /// active 5h window (not idle, with a present `resets_at`) **and** the user was recently working,
    /// that flip is a boundary blip — the window merely reset — not the user going idle. We hold a
    /// calm "ready" bar for ``idleGraceWindow`` and surface a real idle only once the grace elapses
    /// without the window reappearing.
    ///
    /// Activity gate (ADR-0045, D5): the grace arms **only** when `claudeActive` (the `claude` CLI is
    /// running) **and** utilization rose within the last ``utilFreshnessWindow`` — a real recent spend.
    /// A genuine pause (process gone, or no spend for 15 min) surfaces idle immediately, no hold. Both
    /// conditions are required: an open-but-idle `claude` session must not keep the bar warm.
    ///
    /// The gate lives here, not in the decoder, because the decoder is stateless (it sees only the
    /// current body plus an injected `now`); this is the one seam that has the previous snapshot in
    /// scope — the same place ``sessionIdleTransition(previous:current:)`` compares the two.
    ///
    /// Returns the snapshot to render and the new suppression deadline (`nil` = not suppressing):
    /// - `decoded` not idle → `(decoded, nil)`: steady state, clear any armed grace.
    /// - `decoded` idle, grace already armed and `now` before the deadline → `(suppress, deadline)`:
    ///   keep holding the ready bar with the **unchanged** deadline. Checked *before* the arming gate,
    ///   so a mid-grace active↔idle flicker cannot re-arm a fresh window (ADR-0045, D-rearm).
    /// - `decoded` idle, grace elapsed (`now` at/after the deadline) → `(decoded, nil)`: the window
    ///   never came back — surface the genuine idle.
    /// - `decoded` idle, no grace yet, previous active **and** recently working → `(suppress,
    ///   now + idleGraceWindow)`: arm the grace, this is a reset blip.
    /// - `decoded` idle, no grace yet, previous absent/idle or no recent activity → `(decoded, nil)`:
    ///   a genuine idle (cold start, still-idle session, or a real pause) is never suppressed.
    ///
    /// `suppress(_:now:)` rebuilds the snapshot with `sessionIdle: false` **and** a rolled-forward 5h
    /// `resets_at` (`now + 5h`, the same value `ResetClock.optimisticReset` synthesizes), so the bar
    /// reads a calm 0% "on pace" with an honest countdown to the next reset — never the "resetting…"
    /// fallback an empty `resets_at` produced.
    static func applyIdleGrace(
        decoded: UsageSnapshot,
        previous: UsageSnapshot?,
        activeUntil: Date?,
        now: Date,
        claudeActive: Bool,
        lastUtilizationChange: Date?
    ) -> (snapshot: UsageSnapshot, suppressedUntil: Date?) {
        guard decoded.sessionIdle else {
            // The window is active. Render it as-is — but if a grace is still within its deadline,
            // carry that SAME deadline forward instead of clearing it (ADR-0045, re-arm guard). A
            // boundary that flickers active↔idle would otherwise clear the grace on the active blip
            // and re-arm a fresh 5 min on the next idle, holding the ready bar indefinitely. Keeping
            // the original deadline means an active blip cannot extend the window; once it elapses,
            // the next idle surfaces genuinely.
            if let deadline = activeUntil, now < deadline {
                return (decoded, deadline)
            }
            return (decoded, nil)                                  // no grace, or elapsed → clear
        }

        if let deadline = activeUntil {                            // grace already armed
            return now < deadline ? (suppress(decoded, now: now), deadline)  // hold the ready bar
                                  : (decoded, nil)                 // elapsed → surface real idle
        }

        // No grace yet — arm only if the previous poll was a genuinely active 5h window AND the user
        // was recently working (process alive AND a token spend within the freshness window).
        let prevActive = (previous?.sessionIdle == false) && (previous?.fiveHour.hasResetsAt == true)
        let utilFresh = lastUtilizationChange.map {
            now.timeIntervalSince($0) < utilFreshnessWindow
        } ?? false
        guard prevActive && claudeActive && utilFresh else {
            return (decoded, nil)                                  // pause / cold / idle → real idle
        }
        return (suppress(decoded, now: now), now.addingTimeInterval(idleGraceWindow))
    }

    /// Rebuild a snapshot with ``UsageSnapshot/sessionIdle`` forced to `false` and the 5h window
    /// rolled forward to a fresh `now + 5h` reset — the same value ``ResetClock/optimisticReset(_:now:)``
    /// synthesizes for the shell overlay (`ResetClock.nextReset`). Used by ``applyIdleGrace`` so the
    /// reset-boundary grace renders an honest "ready" bar (0% + real countdown) instead of the
    /// "resetting…" a bare `resets_at: ""` produced through the pacing path.
    private static func suppress(_ s: UsageSnapshot, now: Date) -> UsageSnapshot {
        let rolledForward = UsageWindow(
            utilization: s.fiveHour.utilization,
            resetsAt: ResetClock.isoString(from: ResetClock.nextReset(now: now, window: .fiveHour)))
        return UsageSnapshot(
            fiveHour: rolledForward, sevenDay: s.sevenDay, sevenDayOpus: s.sevenDayOpus,
            sevenDaySonnet: s.sevenDaySonnet, limits: s.limits, sessionIdle: false, spend: s.spend)
    }

    // MARK: Live loop

    /// Run the polling loop, emitting one ``PollOutput`` per iteration. The stream ends only when the
    /// task is cancelled (the shell holds it for the process lifetime).
    public func run() -> AsyncStream<PollOutput> {
        AsyncStream { continuation in
            let task = Task {
                // Restore the weekly reconstruction (#386) and age it for the break since the last
                // run: the ratio always survives, the accumulation only if the gap was short.
                var state = PollState(weeklyInterpolator: restoreWeekly().resumed(at: now()))
                while !Task.isCancelled {
                    let active = probe.isClaudeRunning()
                    let previous = state
                    // #341: the usage poll is a user switch. When it is off we skip the request
                    // entirely — no Keychain read, no network — and fold the mode into the state
                    // instead. The heartbeat itself keeps running: the shell rides it to poll the
                    // status page, which is the only data source left in this mode.
                    let pollingUsage = usageApiEnabled()
                    var result: PollResult?
                    if pollingUsage {
                        let poll = await pollOnce(state: state, claudeActive: active)
                        result = poll
                        state = Self.advance(
                            previous: Self.leavingServiceOnlyMode(previous: previous),
                            outcome: poll.outcome, refresh: poll.refresh,
                            claudeActive: active, now: now())
                    } else {
                        state = Self.enteringServiceOnlyMode(previous: previous, claudeActive: active)
                    }

                    // Log the mode flip once per transition, not the mode every tick — the same
                    // "only on change" discipline as the interval and idle logs below.
                    if previous.notPolling != state.notPolling {
                        AppLogger.lifecycle.notice(
                            "usage poll \(state.notPolling ? "off — service status only" : "on", privacy: .public)")
                    }

                    if let decision = Self.intervalDecision(previous: previous, next: state) {
                        AppLogger.lifecycle.notice("\(decision.logMessage, privacy: .public)")
                    }

                    // Log the session-idle flip once per transition (#100), not the idle state every poll.
                    if let transition = Self.sessionIdleTransition(
                        previous: previous.lastSnapshot, current: state.lastSnapshot) {
                        AppLogger.network.notice("\(transition, privacy: .public)")
                    }

                    // Log once when the reset-boundary idle grace arms (ADR-0041) — nil → non-nil,
                    // the same "only on change" discipline as the interval/idle-transition logs above.
                    if previous.idleSuppressedUntil == nil, state.idleSuppressedUntil != nil {
                        AppLogger.network.notice("five_hour idle suppressed — within reset grace")
                    }

                    // The weekly exchange rate (#386), logged **only when it actually moves** — the
                    // same discipline as the interval line above. A shifted N is the one observable
                    // trace of a changed plan/promotion, since the payload announces neither.
                    if let line = Self.weeklyRatioLog(previous: previous, next: state) {
                        AppLogger.network.notice("\(line, privacy: .public)")
                    }
                    if previous.weeklyInterpolator.isDegraded != state.weeklyInterpolator.isDegraded {
                        let phase = state.weeklyInterpolator.isDegraded
                            ? "degraded — polling gap" : "recovered"
                        AppLogger.network.notice("weekly interpolation \(phase, privacy: .public)")
                    }
                    if state.weeklyInterpolator != previous.weeklyInterpolator {
                        persistWeekly(state.weeklyInterpolator)
                    }

                    let interval = Self.effectiveInterval(state)
                    continuation.yield(PollOutput(
                        snapshot: state.lastSnapshot, health: state.health, interval: interval,
                        diagnostics: result?.diagnostics,
                        weekly: state.lastSnapshot.map {
                            state.weeklyInterpolator.value(forRaw: $0.sevenDay.utilization)
                        }))

                    // Wait for the next poll, but suppress a **redundant** wake: a `.wake` /
                    // `.networkRestored` that arrives while the cached data is still fresh (last
                    // success < interval ago) does not fetch — it re-arms the wait for the remaining
                    // interval (ADR-0032 D6). This stops a screen that blinks on/off, or a flaky
                    // network, from hammering the API when the data on screen is already current.
                    // `.manualRefresh` (deliberate user action) and `.sleep`/`.elapsed` fetch as before.
                    var wait = interval
                    waitLoop: while true {
                        switch await scheduler.waitForNextPoll(interval: wait) {
                        case .interrupted(.sleep):
                            await scheduler.waitWhileAsleep()   // park: no fetch while asleep
                            break waitLoop                      // resume with an immediate poll
                        case .interrupted(.manualRefresh):
                            // A user-requested refresh clears any active 429 hold, so the immediate
                            // poll below runs at the base interval rather than deep in a Retry-After hold.
                            state.backoff = state.backoff.reset()
                            break waitLoop
                        case .interrupted(.wake), .interrupted(.networkRestored):
                            // Fetch now only if the cache is already stale; otherwise re-arm for the
                            // time left until it would be. Pure decision in `wakeRearmInterval`.
                            // In service-only mode `lastSuccess` is old history, not a fresh cache
                            // (#341) — passing it here would re-arm the wait against data we are not
                            // refreshing, and delay the status poll this heartbeat carries.
                            guard let remaining = Self.wakeRearmInterval(
                                lastSuccess: state.notPolling ? nil : state.lastSuccess,
                                interval: interval, now: now())
                            else { break waitLoop }              // stale (or no prior success) → poll now
                            wait = remaining
                            // loop: wait out the remainder; the next signal re-enters this switch.
                        case .elapsed:
                            break waitLoop                      // the (possibly re-armed) wait passed
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One read-token-then-fetch attempt, plus the delegated-refresh attempt (if any) made along
    /// the way — the loop feeds both into ``advance(previous:outcome:refresh:claudeActive:now:)``.
    struct PollResult: Sendable, Equatable {
        let outcome: PollOutcome
        /// The delegated-refresh attempt's result, or `nil` when no attempt ran this cycle.
        let refresh: DelegatedRefreshOutcome?
        /// Raw diagnostics of this attempt (ADR-0020), threaded through to `PollOutput`.
        let diagnostics: PollDiagnostics
    }

    /// One read-token-then-fetch attempt, collapsed to a ``PollResult``. An expired/absent token
    /// short-circuits **before** the network (ADR-0007: a stale token guarantees a 401 and burns
    /// rate-limit), so a token error means no request was sent.
    ///
    /// Since ADR-0020 the **engine** judges expiry (the provider hands back token + `expiresAt`), so
    /// the "expired token never goes to the network" contract is enforced here. On expiry the engine
    /// first tries a **delegated refresh** (ADR-0017): the injected ``DelegatedRefresher`` spawns the
    /// `claude` CLI so Claude Code rotates its own Keychain credentials, then the token is re-read
    /// once — all within this same cycle, so recovery does not wait for the next poll. The
    /// ``RefreshGate`` in `state` throttles attempts; a blocked or failed attempt falls through to
    /// the plain `.tokenError(.expired)` path.
    ///
    /// Every path also builds the raw ``PollDiagnostics`` for the Troubleshoot window: `token` dates
    /// whenever the credentials read (even expired), a `.notSent` fetch record when the network was
    /// skipped, and the full ``FetchDiagnostics`` from ``UsageClient/diagnosedFetch`` otherwise.
    func pollOnce(state: PollState, claudeActive: Bool) async -> PollResult {
        var creds: TokenCredentials
        var token = TokenDiagnostics?.none
        var refresh: DelegatedRefreshOutcome?
        do {
            creds = try tokenProvider.currentCredentials(now: now())
        } catch let error as TokenError {
            // Credentials unreadable → no token dates to show; the request is never sent.
            return tokenErrorResult(error, refresh: nil)
        } catch {
            // currentCredentials only throws TokenError; bucket anything else defensively
            // (no Security import needed — `.malformedData` carries no OSStatus).
            return tokenErrorResult(.malformedData, refresh: nil)
        }
        token = TokenDiagnostics(readAt: now(), expiresAt: creds.expiresAt,
                                 subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier)

        // Expiry is judged here now (moved out of the provider, ADR-0020): a stale token must not
        // reach the network. On expiry try one delegated refresh + re-read within this cycle.
        if creds.isExpired(now: now()) {
            AppLogger.keychain.notice("token expired, len=\(creds.accessToken.count, privacy: .public)")
            guard let refresher, state.refreshGate.allows(now: now()) else {
                return tokenErrorResult(.expired, refresh: nil, token: token)
            }
            let attempt = await refresher.refresh()
            refresh = attempt
            guard attempt == .refreshed,
                  let reread = try? tokenProvider.currentCredentials(now: now()),
                  !reread.isExpired(now: now()) else {
                return tokenErrorResult(.expired, refresh: attempt, token: token)
            }
            creds = reread
            token = TokenDiagnostics(readAt: now(), expiresAt: reread.expiresAt,
                                     subscriptionType: reread.subscriptionType, rateLimitTier: reread.rateLimitTier)
        }

        let fetched = await UsageClient.diagnosedFetch(
            accessToken: creds.accessToken, now: now(), transport: transport)
        let diagnostics = PollDiagnostics(fetch: fetched.diagnostics, token: token)
        switch fetched.result {
        case let .success(snapshot):
            return PollResult(outcome: .success(snapshot), refresh: refresh, diagnostics: diagnostics)
        case let .failure(error):
            return PollResult(outcome: .usageError(error), refresh: refresh, diagnostics: diagnostics)
        }
    }

    /// Build a token-error ``PollResult`` whose fetch diagnostic is `.notSent` (the network was
    /// skipped, ADR-0007), tagged with the reason and — when the credentials read but were expired —
    /// the token dates, so the window can show exactly when the token expired.
    private func tokenErrorResult(
        _ error: TokenError, refresh: DelegatedRefreshOutcome?, token: TokenDiagnostics? = nil
    ) -> PollResult {
        let fetch = FetchDiagnostics(
            attemptAt: now(), httpStatus: nil, body: nil,
            outcome: .notSent(reason: Self.notSentReason(error)))
        return PollResult(
            outcome: .tokenError(error), refresh: refresh,
            diagnostics: PollDiagnostics(fetch: fetch, token: token))
    }

    /// A short `.public`-safe reason for a `.notSent` fetch diagnostic — never the token.
    private static func notSentReason(_ error: TokenError) -> String {
        switch error {
        case .itemNotFound:    return "not signed in"
        case .expired:         return "token expired"
        case .accessDenied:    return "keychain access denied"
        case .keychainError:   return "keychain read failed"
        case .malformedData:   return "malformed credentials"
        }
    }
}
