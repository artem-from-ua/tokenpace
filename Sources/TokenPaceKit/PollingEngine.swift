import Foundation

// MARK: - Seams (injected dependencies)

/// A signal pushed into the loop from outside — system sleep/wake (`NSWorkspace`) or a network
/// transition (`NWPathMonitor`). The shell owns the platform observers and feeds these to the
/// scheduler; the engine stays free of AppKit/Network so it is unit-tested with a stub scheduler.
public enum PollSignal: Sendable, Equatable {
    /// The system is about to sleep → pause polling (no fetch while asleep).
    case sleep
    /// The system just woke → poll immediately (data may be stale; AC #1).
    case wake
    /// Connectivity returned after a drop → poll immediately so the bars refresh within seconds
    /// instead of waiting out the cadence (AC #2 "auto-recovery").
    case networkRestored
    /// The user asked for an immediate refresh (Troubleshoot window button) → poll now **and** reset
    /// any active 429 backoff to the base interval. Unlike `.wake`/`.networkRestored`, this clears the
    /// backoff: it is a deliberate user action, so honour it even mid-rate-limit (they accept the risk
    /// of another 429).
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

/// Whether a Claude **Code** session is running on this Mac — the gate for the 30-min idle override
/// (no active session → poll rarely; a session → adaptive 3–15 min). A seam because process
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

    public init(
        snapshot: UsageSnapshot?,
        health: UsageHealth,
        interval: TimeInterval,
        diagnostics: PollDiagnostics? = nil
    ) {
        self.snapshot = snapshot
        self.health = health
        self.interval = interval
        self.diagnostics = diagnostics
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
/// ``PollingEngine/advance(previous:outcome:refresh:claudeActive:now:)``. Holds both interval dimensions
/// (``PollingBackoff`` for 429, ``AdaptiveCadence`` for content), the latest activity reading, and
/// the inputs ``UsageHealth`` needs (`lastSuccess`/`failingSince`/`reason`) plus the stale-safe
/// `lastSnapshot`.
public struct PollState: Sendable, Equatable {
    public var backoff: PollingBackoff
    public var adaptive: AdaptiveCadence
    public var claudeActive: Bool
    public var lastSuccess: Date?
    public var failingSince: Date?
    public var lastSnapshot: UsageSnapshot?
    public var reason: FailureReason?
    /// Anti-flap gate for delegated-refresh attempts (ADR-0017) — blocks a respawn of the
    /// `claude` CLI for an escalating cooldown after each failed attempt.
    public var refreshGate: RefreshGate

    /// Cold start: healthy backoff, fastest adaptive cadence, no data yet. `claudeActive` defaults
    /// to `true` so the very first interval is the responsive adaptive one until the first probe.
    public init(
        backoff: PollingBackoff = PollingBackoff(),
        adaptive: AdaptiveCadence = AdaptiveCadence(),
        claudeActive: Bool = true,
        lastSuccess: Date? = nil,
        failingSince: Date? = nil,
        lastSnapshot: UsageSnapshot? = nil,
        reason: FailureReason? = nil,
        refreshGate: RefreshGate = RefreshGate()
    ) {
        self.backoff = backoff
        self.adaptive = adaptive
        self.claudeActive = claudeActive
        self.lastSuccess = lastSuccess
        self.failingSince = failingSince
        self.lastSnapshot = lastSnapshot
        self.reason = reason
        self.refreshGate = refreshGate
    }

    /// The `UsageHealth` view-model input derived from this state.
    public var health: UsageHealth {
        UsageHealth(lastSuccess: lastSuccess, failingSince: failingSince, reason: reason)
    }
}

// MARK: - Interval decision (for logging)

/// Why the effective interval changed between two polls — the payload of the **one log line per
/// interval change** the user asked for. Computed by ``PollingEngine/intervalDecision(previous:next:)``,
/// which returns `nil` when the interval did not move (so the loop logs only real changes, never spam —
/// the same "only on change" discipline as `StatusItemView.layout`, ADR-0009).
public struct IntervalDecision: Sendable, Equatable {
    public enum Cause: Sendable, Equatable {
        /// No Claude Code session running → the 30-min idle override took effect.
        case claudeInactive
        /// A Claude Code session reappeared → back to the adaptive cadence.
        case claudeActiveResumed
        /// The snapshot moved → adaptive snapped to the 3-min floor.
        case contentChanged
        /// Two adjacent snapshots matched → adaptive doubled the interval.
        case contentUnchanged
        /// HTTP 429 → the server backoff took over (overrides adaptive/idle).
        case rateLimited
        /// A 200 cleared an active 429 backoff → back to adaptive/idle.
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
        case .claudeActiveResumed: return "Claude Code session active — resuming adaptive cadence"
        case .contentChanged:      return "usage changed — tracking closely"
        case .contentUnchanged:    return "usage unchanged — backing off"
        case .rateLimited:         return "rate-limited (HTTP 429) — server backoff"
        case .rateLimitCleared:    return "rate-limit cleared — resuming adaptive cadence"
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
/// ## Interval model — two independent dimensions plus an override
/// ``effectiveInterval(_:)`` combines them with a fixed priority:
/// 1. **429 backoff** (``PollingBackoff``) — if escalating, it wins outright (server told us to slow
///    down; honour it above any optimisation).
/// 2. **Claude-inactive 30-min override** — no session → poll rarely, regardless of adaptive state.
/// 3. **Adaptive cadence** (``AdaptiveCadence``) — otherwise, 3–15 min by whether the data is moving.
public struct PollingEngine: Sendable {

    /// The interval used when no Claude Code session is running — a hard override above the adaptive
    /// cadence. 30 min (user decision).
    public static let inactiveInterval: TimeInterval = 30 * 60

    /// The **hard floor** on the gap between any two polls — a safety rail independent of the
    /// scheduler. Even if a scheduler returned instantly (a bug we shipped once: a broken signal
    /// iterator made `waitForNextPoll` return with no delay, hammering the API ~50×/s and tripping a
    /// 429), the loop sleeps at least this long between requests. 60 s is comfortably below the
    /// 180 s base cadence, so it never slows normal operation; it only caps the worst case.
    /// Enforced twice: `effectiveInterval` never returns less, and `run()` re-checks elapsed wall
    /// time after every wait. `minIntervalNeverBelowFloor` and `loopNeverPollsFasterThanFloor` guard
    /// both rails in tests.
    public static let minInterval: TimeInterval = 60

    let transport: UsageTransport
    let tokenProvider: TokenProviding
    let refresher: DelegatedRefresher?
    let scheduler: PollScheduler
    let probe: ClaudeActivityProbe
    let now: @Sendable () -> Date

    public init(
        transport: UsageTransport,
        tokenProvider: TokenProviding = KeychainTokenProvider(),
        refresher: DelegatedRefresher? = nil,
        scheduler: PollScheduler,
        probe: ClaudeActivityProbe,
        now: @escaping @Sendable () -> Date
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.refresher = refresher
        self.scheduler = scheduler
        self.probe = probe
        self.now = now
    }

    // MARK: Pure transitions

    /// Fold one poll outcome into the next state. No clock, no I/O — `now` is injected. The single
    /// source of the engine's behaviour, exhaustively table-tested.
    ///
    /// - `success`: reset the 429 backoff, mark `lastSuccess = now`, clear the failure; compare the
    ///   new snapshot's 5h/7d utilisation against the previous one to step the adaptive cadence
    ///   (changed → floor, unchanged → double); keep the snapshot as the new `lastSnapshot`.
    /// - `usageError(.rateLimited)`: escalate the 429 backoff (honouring `Retry-After`); leave the
    ///   adaptive cadence untouched; begin/continue the failure run; **keep** `lastSnapshot` (stale).
    /// - other `usageError`: same as above but **do not** escalate the backoff (offline/timeout/5xx
    ///   are not a 429 — staying at the current cadence lets recovery happen promptly).
    /// - `tokenError`: the loop skipped the network entirely; record the failure, touch neither
    ///   interval dimension, keep the snapshot.
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
            next.adaptive = changed(previous.lastSnapshot, snapshot)
                ? previous.adaptive.changed()
                : previous.adaptive.unchanged()
            next.lastSuccess = now
            next.failingSince = nil
            next.reason = nil
            next.lastSnapshot = snapshot

        case let .usageError(error):
            if case let .rateLimited(retryAfter) = error {
                next.backoff = previous.backoff.escalated(retryAfter: retryAfter)
            }
            // adaptive cadence is content-driven; a failed poll observes no new content → unchanged.
            recordFailure(into: &next, previous: previous, reason: FailureReason(error), now: now)

        case let .tokenError(error):
            recordFailure(into: &next, previous: previous, reason: FailureReason(error), now: now)
        }

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

    /// Whether the 5h/7d utilisation moved between two successful snapshots (the user's definition of
    /// "change"). The first success (no previous snapshot) counts as a change, so the cadence starts
    /// at the responsive floor rather than immediately doubling.
    static func changed(_ previous: UsageSnapshot?, _ current: UsageSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.fiveHour.utilization != current.fiveHour.utilization
            || previous.sevenDay.utilization != current.sevenDay.utilization
    }

    /// The interval to wait before the next poll, combining the two dimensions with the priority:
    /// 429 backoff > Claude-inactive 30-min override > adaptive cadence. Never returns below
    /// ``minInterval`` — the first of two rails that make a tight request loop impossible.
    public static func effectiveInterval(_ state: PollState) -> TimeInterval {
        max(minInterval, rawInterval(state))
    }

    /// The interval before the ``minInterval`` floor is applied — the pure dimension combination.
    private static func rawInterval(_ state: PollState) -> TimeInterval {
        if state.backoff.level != nil {           // an active 429 backoff overrides everything
            return state.backoff.interval
        }
        if !state.claudeActive {                  // no Claude Code session → hard 30-min override
            return inactiveInterval
        }
        return state.adaptive.interval            // otherwise: content-driven 3–15 min
    }

    /// Why the effective interval changed from `previous` to `next`, or `nil` if it did not move.
    /// The loop logs exactly the non-nil results, one line per real change.
    public static func intervalDecision(previous: PollState, next: PollState) -> IntervalDecision? {
        let from = effectiveInterval(previous)
        let to = effectiveInterval(next)
        guard from != to else { return nil }
        return IntervalDecision(from: from, to: to, cause: cause(previous: previous, next: next))
    }

    /// Attribute an interval change to the dimension that drove it, checked in priority order so the
    /// reported cause matches which dimension actually owns the new interval.
    private static func cause(previous: PollState, next: PollState) -> IntervalDecision.Cause {
        let wasRateLimited = previous.backoff.level != nil
        let isRateLimited = next.backoff.level != nil
        if isRateLimited { return .rateLimited }
        if wasRateLimited { return .rateLimitCleared }       // 429 just cleared on a 200

        if previous.claudeActive != next.claudeActive {
            return next.claudeActive ? .claudeActiveResumed : .claudeInactive
        }
        // Same activity, no 429 churn → the adaptive cadence moved.
        return next.adaptive.level <= previous.adaptive.level ? .contentChanged : .contentUnchanged
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

    // MARK: Live loop

    /// Run the polling loop, emitting one ``PollOutput`` per iteration. The stream ends only when the
    /// task is cancelled (the shell holds it for the process lifetime).
    public func run() -> AsyncStream<PollOutput> {
        AsyncStream { continuation in
            let task = Task {
                var state = PollState()
                while !Task.isCancelled {
                    let active = probe.isClaudeRunning()
                    let result = await pollOnce(state: state, claudeActive: active)
                    let previous = state
                    state = Self.advance(
                        previous: previous, outcome: result.outcome, refresh: result.refresh,
                        claudeActive: active, now: now())

                    if let decision = Self.intervalDecision(previous: previous, next: state) {
                        AppLogger.lifecycle.notice("\(decision.logMessage, privacy: .public)")
                    }

                    // Log the session-idle flip once per transition (#100), not the idle state every poll.
                    if let transition = Self.sessionIdleTransition(
                        previous: previous.lastSnapshot, current: state.lastSnapshot) {
                        AppLogger.network.notice("\(transition, privacy: .public)")
                    }

                    let interval = Self.effectiveInterval(state)
                    continuation.yield(PollOutput(
                        snapshot: state.lastSnapshot, health: state.health, interval: interval,
                        diagnostics: result.diagnostics))

                    let reason = await scheduler.waitForNextPoll(interval: interval)
                    if case .interrupted(.sleep) = reason {
                        await scheduler.waitWhileAsleep()   // park: no fetch while asleep
                    }
                    if case .interrupted(.manualRefresh) = reason {
                        // A user-requested refresh clears any active 429 backoff, so the immediate
                        // poll below runs at the base interval rather than deep in a 15-min hold.
                        state.backoff = state.backoff.reset()
                    }
                    // .elapsed → scheduled poll; .interrupted(.wake/.networkRestored/.manualRefresh) →
                    // immediate poll (manualRefresh also cleared the backoff, just above).
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
        token = TokenDiagnostics(readAt: now(), expiresAt: creds.expiresAt)

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
            token = TokenDiagnostics(readAt: now(), expiresAt: reread.expiresAt)
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
