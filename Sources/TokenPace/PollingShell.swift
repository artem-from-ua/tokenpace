import AppKit
import TokenPaceKit
import Darwin
import Network

// MARK: - SignalHub

/// Fan-in for `PollSignal`s from the platform observers (`WorkspaceSleepWake`, `NetworkMonitor`)
/// into the single stream the `LivePollScheduler` listens on. A thin wrapper over
/// `AsyncStream.makeStream` so the observers — which fire on arbitrary threads — can `send` without
/// touching the scheduler's state directly.
///
/// Bounded buffer (`bufferingPolicy: .bufferingNewest(1)`): a burst of path/power notifications
/// collapses to the most recent signal instead of queueing dozens that would each cut a wait short.
/// Only the latest matters — the loop reacts to "we are awake / online now", not to history.
///
/// A single `AsyncStream` is **single-consumer**: once one `PollingEngine` iterates it, a second
/// engine subscribing to the same stream would not receive signals. The live stub selector (#187)
/// rebuilds the engine at runtime, so the hub vends a **fresh** stream per engine via ``newStream()``,
/// finishing the previous one and routing subsequent `send`s to the new continuation under a lock.
/// The observers (`WorkspaceSleepWake`, `ScreenLockObserver`, `NetworkMonitor`) call `send` without
/// caring which engine is current — they always reach the active continuation.
final class SignalHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<PollSignal>.Continuation?

    /// Create a fresh stream, finish any previous one, and make its continuation the active target for
    /// `send`. Called once per engine build (launch + every live scenario swap). The old engine's
    /// iteration ends when its stream finishes.
    func newStream() -> AsyncStream<PollSignal> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PollSignal.self, bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        self.continuation?.finish()
        self.continuation = continuation
        lock.unlock()
        return stream
    }

    func send(_ signal: PollSignal) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(signal)
    }
}

// MARK: - WorkspaceSleepWake

/// Bridges `NSWorkspace` sleep/wake notifications to `PollSignal`s. Observers live on
/// **`NSWorkspace.shared.notificationCenter`** — workspace power notifications are posted there, not
/// on `NotificationCenter.default`.
@MainActor
final class WorkspaceSleepWake {
    private let onSignal: @Sendable (PollSignal) -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onSignal: @escaping @Sendable (PollSignal) -> Void) {
        self.onSignal = onSignal
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [onSignal] _ in
            AppLogger.lifecycle.notice("system will sleep, pausing polling")
            onSignal(.sleep)
        })
        tokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [onSignal] _ in
            AppLogger.lifecycle.notice("system did wake, polling immediately")
            onSignal(.wake)
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }
}

// MARK: - ScreenLockObserver

/// Pauses polling while the screen is **locked, asleep, or running a screensaver**, resuming with an
/// immediate poll when it comes back — reusing the same `.sleep`/`.wake` park path as
/// ``WorkspaceSleepWake`` (#114, ADR-0030). Screen-off is a strong "the user isn't looking" signal, so
/// there is no point spending usage-API quota on refreshes nobody sees.
///
/// **Config-gated, default-on.** Each handler reads ``PersistedConfig/pausePollingWhenScreenLocked``
/// *at fire time*, so toggling the Settings checkbox takes effect on the very next lock/unlock with no
/// restart. When the option is off, the handlers emit nothing and polling continues unaffected.
///
/// Distinct from ``WorkspaceSleepWake`` (whole-system sleep/wake), which stays **unconditional** — a
/// laptop that actually sleeps must always park regardless of this preference. The two observers feed
/// the same `.sleep`/`.wake` signals into the same hub; `SignalHub`'s newest-wins buffer collapses any
/// overlap (e.g. lock then system-sleep) harmlessly.
///
/// Events observed:
/// - **Lock/unlock** — `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` on
///   `DistributedNotificationCenter` (the system-wide bus these are posted on).
/// - **Screensaver** — `com.apple.screensaver.didstart` / `...willstop`, same bus.
/// - **Display sleep/wake** — `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`
///   on `NSWorkspace.shared.notificationCenter` (energy-saver display-off without a full system sleep).
@MainActor
final class ScreenLockObserver {
    private let onSignal: @Sendable (PollSignal) -> Void
    private var distributedTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    /// Whether the pause-on-screen-lock preference is currently on. Read live on each event so the
    /// Settings toggle needs no restart to take effect.
    private var isEnabled: Bool { PersistedConfig.pausePollingWhenScreenLocked }

    init(onSignal: @escaping @Sendable (PollSignal) -> Void) {
        self.onSignal = onSignal

        // Lock / unlock / screensaver ride the *distributed* notification center (cross-process bus).
        let distributed = DistributedNotificationCenter.default()
        let pausing: [(String, String)] = [
            ("com.apple.screenIsLocked", "screen locked"),
            ("com.apple.screensaver.didstart", "screensaver started"),
        ]
        let resuming: [(String, String)] = [
            ("com.apple.screenIsUnlocked", "screen unlocked"),
            ("com.apple.screensaver.willstop", "screensaver stopped"),
        ]
        for (name, label) in pausing {
            distributedTokens.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.pause(label) } })
        }
        for (name, label) in resuming {
            distributedTokens.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.resume(label) } })
        }

        // Display sleep/wake (energy saver turning the panel off) ride the workspace center.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.pause("display asleep") } })
        workspaceTokens.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resume("display awake") } })
    }

    /// Park the poll loop (via `.sleep`) if the preference is on; otherwise ignore the event.
    private func pause(_ reason: String) {
        guard isEnabled else { return }
        AppLogger.lifecycle.notice("screen-lock-pause: \(reason, privacy: .public), pausing polling")
        onSignal(.sleep)
    }

    /// Resume the poll loop with one immediate poll (via `.wake`) if the preference is on.
    private func resume(_ reason: String) {
        guard isEnabled else { return }
        AppLogger.lifecycle.notice("screen-lock-pause: \(reason, privacy: .public), polling immediately")
        onSignal(.wake)
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.forEach(distributed.removeObserver)
        distributedTokens.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(workspace.removeObserver)
        workspaceTokens.removeAll()
    }
}

// MARK: - NetworkMonitor

/// Wraps `NWPathMonitor`, emitting `.networkRestored` on each `.unsatisfied → .satisfied`
/// transition so the loop can poll immediately when connectivity returns (AC #2 "auto-recovery").
/// It does **not** build health or decide staleness — that stays sourced from the fetch result
/// (`UsageError.transport → FailureReason.network`), keeping one source of truth.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.artem-n.tokenpace.network-monitor")
    /// Whether the previous path was satisfied — to detect the down→up edge (and suppress the very
    /// first callback, which is just the initial reading, not a restoration).
    private var wasSatisfied: Bool?

    /// The last path's "metered" reading (`isExpensive || isConstrained`), cached under `meteredLock`
    /// so ``isMetered`` can be read synchronously from the main actor at auto-install decision time
    /// (#123). Updated on every `pathUpdateHandler` callback (which runs on `queue`).
    private let meteredLock = NSLock()
    private var _isMetered = false

    /// Whether the current network is metered — expensive (cellular / personal hotspot) or constrained
    /// (Low Data Mode). Used only to *defer* an auto-install download onto an unmetered link, never to
    /// gate the lightweight update *check*. Defaults to `false` until the first path callback arrives.
    var isMetered: Bool {
        meteredLock.lock(); defer { meteredLock.unlock() }
        return _isMetered
    }

    /// Begin monitoring; `onRestored` fires on each connectivity restoration.
    func start(onRestored: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.meteredLock.lock()
            self._isMetered = path.isExpensive || path.isConstrained
            self.meteredLock.unlock()

            let satisfied = path.status == .satisfied
            defer { self.wasSatisfied = satisfied }
            switch self.wasSatisfied {
            case .none:
                AppLogger.lifecycle.notice("network monitor started (satisfied=\(satisfied, privacy: .public))")
            case .some(false) where satisfied:
                AppLogger.lifecycle.notice("network restored, polling immediately")
                onRestored()
            case .some(true) where !satisfied:
                AppLogger.lifecycle.notice("network lost, showing stale data")
            default:
                break
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

// MARK: - ProcessClaudeActivityProbe

/// Production `ClaudeActivityProbe`: reports whether a **Claude Code** CLI session is running by
/// scanning the process table for an executable named exactly `claude`.
///
/// The match is on the **exact process name** (not a substring), so it tracks the CLI that consumes
/// the subscription limits and does **not** false-positive on the Claude Desktop app, whose helper
/// processes are named "Claude Helper" and only show up under a full `-f` command-line match.
struct ProcessClaudeActivityProbe: ClaudeActivityProbe {
    /// The exact executable name that marks a Claude Code session.
    static let processName = "claude"

    func isClaudeRunning() -> Bool {
        Self.runningProcessNames().contains(Self.processName)
    }

    /// All running process names via `sysctl(KERN_PROC_ALL)` — no subprocess spawn, no `pgrep` path
    /// dependency. Returns an empty set on any sysctl failure (fail-safe: treated as "inactive" →
    /// the 15-min override, which is the conservative cadence).
    private static func runningProcessNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        // sysctl may report fewer entries than the sized buffer; trust the returned `size`.
        let actual = size / MemoryLayout<kinfo_proc>.stride
        var names = Set<String>()
        for i in 0..<min(actual, procs.count) {
            var comm = procs[i].kp_proc.p_comm   // fixed-size CChar tuple (MAXCOMLEN+1)
            let commSize = MemoryLayout.size(ofValue: comm)
            let name = withUnsafePointer(to: &comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: commSize) {
                    String(cString: $0)
                }
            }
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }
}

// MARK: - StubUsageTransport (verification only — TOKENPACE_STUB)

/// A canned `UsageTransport` for end-to-end verification without hitting the usage API. **Never**
/// used on the default path — only when `TOKENPACE_STUB` is set; the value selects the ``Mode``.
///
/// `resets_at` is computed **relative to the current instant** (5 h / 7 d windows that are partway
/// elapsed), not hard-coded — otherwise the dates drift into the past and `elapsedFraction` pins to
/// `1.0`, making the pacing bar look broken (the time indicator stuck at the right edge).
actor StubUsageTransport: UsageTransport {
    private var calls = 0

    /// What the stub returns, selected by the `TOKENPACE_STUB` value:
    ///  • `.climbing` (`=1`)        — utilisation nudges upward every few polls, so the popup text,
    ///    the bars, and the adaptive cadence (changed → reset, unchanged → double) can all be seen.
    ///  • `.screenshot` (`=screenshot`) — frozen, hand-picked values; a stable frame for the README.
    ///    The pacing states still span green (5h, Fable) and red (7d); only the climbing is frozen.
    ///  • `.authError` (`=error`)   — usage returns **401** with a long body (→ `authHTTP`), and the
    ///    status endpoint reports **both** Claude services degraded, so the warning block, the
    ///    service-status dots, and the long-message wrapping can all be seen at once.
    ///  • `.idle` (`=idle`)         — the honest "no active 5h session" frame (#100, ADR-0027): the
    ///    `five_hour` window arrives with `resets_at: null` **and** no `session` entry in `limits[]`, so
    ///    the snapshot decodes `sessionIdle == true`. The 5h bar renders solid blue with no knob and the
    ///    menu-bar time falls back to the 7-day reset (set ~4.2 days out → "4d" live). The status
    ///    endpoint stays all-operational so the frame is clean.
    ///  • `.idleBlocked` (`=idle-blocked`) — the **blocked** idle frame (#158): the same idle 5h shape,
    ///    but `seven_day` is exhausted (100 %) and there is **no** `spend` block, so credits cannot cover
    ///    → `sessionIdle && idleBlocked`. The idle bar renders **grey** (menu bar + popup, both colour
    ///    modes), the popup status word is "waiting for limit reset", and the 7-day reset (the sole
    ///    exhausted candidate, ~4 days out) is drawn **red** as the blocking reset.
    ///  • `.activeBlocked` (`=active-blocked`) — the **active** blocked frame (#177): a live 5h window
    ///    with quota (48 %) while `seven_day` is exhausted (100 %, `weekly_all` critical) and there is
    ///    **no** `spend` block, so the weekly cap blocks despite 5h quota. Not idle → the 5h row is a
    ///    normal (non-grey) "on pace" row, but the popup's 7-day reset gets the **red** blocking-reset
    ///    badge. This is Артем's real bug: before the fix `isBlocked` was false and no badge showed.
    ///  • `.optimisticReset` (`=optimistic-reset`) — the reset-boundary frame (#36): the first poll's 5h
    ///    window resets in ~20 s at 60 % util, so the coordinator's one-shot timer fires shortly after
    ///    launch — the 5h bar flips 60 % → 0 % with a fresh ~5 h countdown (no ⏰) and a forced refresh
    ///    follows. Every later poll returns a freshly-reset window (0 %, now + 5h).
    /// The climbing/screenshot data modes also carry two `weekly_scoped` per-model entries in `limits[]`
    /// (#65) — Fable / Mythos — so the scoped-model popup rows are exercised end-to-end, and their
    /// utilisations (plus the 7-day window) show a couple of the ahead-of-pace gap colours.
    enum Mode: Equatable {
        case climbing, screenshot, authError, idle, idleBlocked, activeBlocked
        /// The **stale-while-erroring** frame (spacing bug): the first usage poll returns a full, valid
        /// snapshot (5h idle "ready to start", a 18 % 7-day window, a Fable per-model row, an on-pace
        /// "Extra usage" credits section), then **every later poll throws** `URLError(.timedOut)`. The
        /// coordinator keeps showing the last good snapshot's bars while the poll is failing, so the popup
        /// renders the ⚠️ error banner ("Claude API connectivity issue" / "Authentication API timeout")
        /// **above** the full set of limit rows — the exact state where the error block needs its
        /// trailing `sectionSpacing` gap so it doesn't sit glued to the "5-hour" row. The status endpoint
        /// reports API + Code as **major outage** (mirroring the reported screenshot).
        case staleError
        /// The optimistic-reset frame (#36): the first poll returns an **active** 5h window whose reset
        /// is only ~20 s out (utilisation 60 %), so the coordinator's one-shot timer fires shortly after
        /// launch. On fire the 5h bar flips 60 % → 0 % with a fresh ~5 h countdown (the optimistic
        /// overlay, no ⏰), then the forced refresh lands: from the second poll on the stub returns a
        /// freshly-reset window (0 %, `now + 5h`), mirroring what the real API would report post-reset.
        case optimisticReset
        /// The reset-boundary idle-grace frame (ADR-0041, ADR-0045): the first two polls return an
        /// **active** 5h window (mid-window, 40 %), then two polls return the post-reset **empty** body
        /// (`five_hour.resets_at: null`, no `session` limit → the decoder would report
        /// `sessionIdle == true`), then the window is **active again** (a fresh ~5 h window). The grace
        /// gate keeps the 5h bar **non-idle** across the two empty polls, and (ADR-0045) that held bar
        /// reads a calm 0 % "on pace" with a rolled-forward countdown — **never** "resetting…" or a
        /// full-width green bar. Watch the menu bar: it must not blink to "waiting for limit reset"
        /// between the active windows. Arming requires a live `claude` process (`claudeActive`); with
        /// none, the fix surfaces idle ("ready to start") immediately instead.
        case resetGrace
        /// The "Back to work!" edge frame (#160): the first poll returns a **blocked** body (7-day
        /// window at 100 %, no credits → `canWork == false`), so the persisted "was blocked" flag is
        /// set; every later poll returns a **workable** body (7-day back to 40 %), which is a genuine
        /// blocked→unblocked edge that fires the notification (subject to quiet hours + authorization).
        case justUnblocked
        /// The "Now using Extra Usage Credit" edge frame: the first poll returns a **not-on-credits**
        /// body (7-day at 40 %, so no main window is exhausted even though credits are enabled →
        /// `ExtraUsageOnset.isOnCredits == false`); every later poll pins the 7-day window at 100 % with
        /// the same enabled `spend`/`extra_usage` blocks, so work now overflows onto paid credit
        /// (`isOnCredits == true`). The not-spending→spending edge fires once, posting the banner with
        /// the spent amount + limit (subject to quiet hours + authorization). Reuses the `.active`
        /// credits blocks (€10.77 of €15.00).
        case creditsOnset
        /// A fixed 5h×7d severity frame for verifying the reset-countdown selection table (#103).
        case pacing(PacingFrame)
        /// The broken-`resets_at` frame (#167, ADR-0043): a healthy poll whose 5h window is **noisy**
        /// (exhausted, 100 %) but carries `resets_at: null` — an API data error on the chosen window.
        /// `selectReset` returns `.dataError(.fiveHour)` and the menu bar promotes to the ⚠️ error state
        /// (glyph + last bars) instead of inventing a countdown — the same treatment as other API errors.
        case brokenReset
        /// Calm bars + a **degraded** (yellow) service dot (#…): the usage side mirrors
        /// `.pacing(.calmBoth)` (both bars calm) while the status side reports `Claude Code`
        /// `degraded_performance`, so the menu bar shows the lone calm 5h bar *and* a yellow service
        /// dot. The one frame that verifies calm colours muting the yellow service dot to white.
        case calmDegraded
        /// A money-credits ("extra usage") frame for the trailing ¤ icon (#144). Each `CreditsFrame`
        /// pins the 7-day window at 100 % (so `anyBaseLimitExhausted` holds and the icon shows) and
        /// carries a `spend` + `extra_usage` block covering one credits state (paced / limit-reached /
        /// unlimited). The bodies reuse the exact shapes from `CreditsModelTests`.
        case credits(CreditsFrame)
    }

    /// A money-credits state for the `=credits-*` verification stubs (#144). Each supplies the raw
    /// `spend` + `extra_usage` JSON blocks and drives the trailing ¤ icon's colour:
    ///  • `.active`       — enabled, €15.00 limit, €10.77 spent (~72 %): a **paced** icon (green while
    ///    behind the month's time-fraction, amber/orange when ahead) — the healthy "within limit".
    ///  • `.limitReached` — €5.00 limit below €10.77 spent: `enabled: false` + `spend_limit_reached:
    ///    true` → the icon forces to **red** (the cap is hit).
    ///  • `.noLimit`      — enabled, `limit: null` (unlimited): no cap to pace → a **neutral**
    ///    (foreground-coloured) icon, no pacing tint.
    enum CreditsFrame: Equatable {
        case active, limitReached, noLimit

        /// The `spend` + `extra_usage` block pair for this frame, as raw JSON fragments (no braces) to
        /// splice into the usage body. Verbatim from `CreditsModelTests` fixtures so the stub exercises
        /// the same shapes the decoder is tested against — EUR money objects, the `used_credits`
        /// scalar, and the `spend_limit_reached`/`enabled` pairing.
        var blocks: String {
            switch self {
            case .active:
                return """
                "extra_usage":{"is_enabled":true,"monthly_limit":1500,"used_credits":1077.0,\
                "utilization":71.8,"currency":"EUR","decimal_places":2,"disabled_reason":null,\
                "user_disabled":false,"spend_limit_reached":false,"credits_ever_enabled":true,\
                "daily":null,"weekly":null},\
                "spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},\
                "limit":{"amount_minor":1500,"currency":"EUR","exponent":2},"percent":72,\
                "severity":"normal","enabled":true,"disabled_reason":null,"balance":null,\
                "auto_reload":null}
                """
            case .limitReached:
                return """
                "extra_usage":{"is_enabled":false,"monthly_limit":500,"used_credits":1077.0,\
                "utilization":100.0,"currency":"EUR","decimal_places":2,\
                "disabled_reason":"org_level_disabled_until","user_disabled":false,\
                "spend_limit_reached":true,"credits_ever_enabled":true,"daily":null,"weekly":null},\
                "spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},\
                "limit":{"amount_minor":500,"currency":"EUR","exponent":2},"percent":100,\
                "severity":"critical","enabled":false,\
                "disabled_reason":"org_level_disabled_until","balance":null,"auto_reload":null}
                """
            case .noLimit:
                return """
                "extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":1077.0,\
                "utilization":null,"currency":"EUR","decimal_places":2,"disabled_reason":null,\
                "user_disabled":false,"spend_limit_reached":false,"credits_ever_enabled":true,\
                "daily":null,"weekly":null},\
                "spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},"limit":null,\
                "percent":0,"severity":"normal","enabled":true,"disabled_reason":null,\
                "balance":null,"auto_reload":null}
                """
            }
        }
    }

    /// Hand-picked top-level 5h/7d frames covering the reset-countdown cells the other stubs miss
    /// (no red bar, no both-noisy, no lone-noisy-5h). Numbers are chosen against the 5h (18000 s) and
    /// 7d (604800 s) windows so each bar lands in the intended severity.
    enum PacingFrame: Equatable {
        /// 5h orange (usage 50 vs elapsed ~20), 7d green (usage 20 vs elapsed ~29).
        case fiveOrange
        /// Both orange: 5h as `fiveOrange`, 7d usage 55 vs elapsed ~29 → ahead ~26 pts.
        case bothOrange
        /// Both red (usage 100): 5h resets in 2 h, 7d in 4 d — the later reset is the 7d one.
        case bothRed
        /// 5h red (usage 100) + 7d orange (usage 55) — the red bar (5h) drives the countdown.
        case redOrange
        /// 5h **red** (usage 100) + 7d **green** on-pace (usage 20 vs elapsed ~29) — one red stroke and
        /// one green stroke side by side, for comparing the lightened menu-bar pacing colours (#158).
        case redGreen
        /// 5h **calm** (usage 10 vs elapsed ~20 → green) + 7d **orange** ahead-of-pace (usage 55 vs
        /// elapsed ~29 → ahead ~26 pts) with a days-away reset (5 d ≥ 24 h). The frame where the
        /// reset-countdown mode changes what's shown: `smart` shows the 7d countdown here, `never`
        /// hides it (the lone days-away 7d-orange cell, #103/ADR-0029).
        case calmFiveOrangeSeven
        /// Both bars **calm**: 5h green (usage 10 vs elapsed ~20) + 7d green (usage 20 vs elapsed ~29).
        /// Exercises "Hide 7-day bar when calm" (#94): with the toggle on (default) the 7-day bar is
        /// dropped and a lone green 5h bar sits centred; both calm → no reset countdown either.
        case calmBoth

        /// **20-min override** frame (ADR-0044): 5h ahead by only ~2 pts (usage 98 vs elapsed ~96 %)
        /// but the 5h window resets in **12 min**. Under a static/dynamic threshold a 2-pt lead is
        /// yellow (calm); the ≤ 20-min override forces it **orange**, so the countdown appears. 7d
        /// stays green. Use this to see the override flip a would-be-calm bar to noisy.
        case nearResetFiveHour

        /// **Far behind** frame (ADR-0061): both base bars deep behind pace with a big surplus, past the
        /// 20-min start override — 5h (usage 5 vs elapsed ~60 % → surplus ~0.55) and 7d (usage 10 vs
        /// elapsed ~71 % → surplus ~0.61), both far above the behind-threshold → **blue**. Use this to
        /// see the far-behind blue zone and the "Work harder" toggle (blue stays coloured under Calm).
        case farBehind

        /// **Near-zero** frame: tiny usage on a *fresh* window (barely any time elapsed), so the pacing
        /// gap is a hairline — the case that exercises the min-strip "pill" geometry. Both usage and
        /// `timeFraction` are ≈ 0 (5h resets ~17 950 s out of an 18 000 s window; 7d ~596 000 s out of
        /// 604 800 s), so the coloured span shrinks to near-zero and must render as a rounded pill that
        /// sits flush inside the rounded track — not a sliver overhanging the cap. Per-model rows are
        /// pinned near-zero too (see the stub body) so Fable/Mythos show the same pill.
        case nearZero

        /// (fiveUtil, sevenUtil, fiveResetSeconds, sevenResetSeconds).
        var values: (five: Double, seven: Double, fiveIn: TimeInterval, sevenIn: TimeInterval) {
            switch self {
            case .fiveOrange:         return (50, 20, 4 * 3600, 5 * 24 * 3600)
            case .bothOrange:         return (50, 55, 4 * 3600, 5 * 24 * 3600)
            case .bothRed:            return (100, 100, 2 * 3600, 4 * 24 * 3600)
            case .redOrange:          return (100, 55, 2 * 3600, 5 * 24 * 3600)
            case .redGreen:           return (100, 20, 2 * 3600, 5 * 24 * 3600)
            case .calmFiveOrangeSeven: return (10, 55, 4 * 3600, 5 * 24 * 3600)
            case .calmBoth:           return (10, 20, 4 * 3600, 5 * 24 * 3600)
            case .nearResetFiveHour:  return (98, 20, 12 * 60, 5 * 24 * 3600)
            case .farBehind:          return (5, 10, 2 * 3600, 2 * 24 * 3600)
            // Fresh windows: reset is almost a full window away → timeFraction ≈ 0 → hairline gap.
            case .nearZero:           return (0, 4, 17_950, 596_000)
            }
        }
    }

    private let mode: Mode

    init(mode: Mode = .climbing) {
        self.mode = mode
    }

    /// ISO-8601 string for a `Date`, matching the API's `+00:00` offset form.
    private static func isoString(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        return iso.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    /// ISO-8601 string for `now + seconds`, matching the API's `+00:00` offset form.
    private static func resetsAt(inSeconds seconds: TimeInterval) -> String {
        isoString(Date().addingTimeInterval(seconds))
    }

    /// `now + seconds`, rounded to the nearest 10-minute mark, as a UTC ISO string — gives the
    /// screenshot a clean absolute reset (`…:x0`) while keeping the elapsed fraction ≈ the target.
    private static func resetsAtRounded10(inSeconds seconds: TimeInterval) -> String {
        let raw = Date().addingTimeInterval(seconds).timeIntervalSince1970
        let rounded = (raw / 600).rounded() * 600
        return isoString(Date(timeIntervalSince1970: rounded))
    }

    /// `daysFromNow` days ahead, snapped to the next top-of-the-hour, as a UTC ISO string — a clean
    /// `…:00` absolute reset shared by the 7-day window and its Sonnet sub-window in the screenshot.
    private static func hourBoundary(daysFromNow days: Int) -> Date {
        let cal = Calendar.current
        let target = Date().addingTimeInterval(Double(days) * 86_400)
        let nextHour = cal.nextDate(after: target, matching: DateComponents(minute: 0, second: 0),
                                    matchingPolicy: .nextTime) ?? target
        return nextHour
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // Status endpoint (#31, #89): a canned summary covering every component the configurable
        // logical services can monitor (`Claude Code`, `Claude API`, `claude.ai`, `Claude Cowork` —
        // ADR-0024). In `.authError` mode the API, Code, and Cowork are degraded and `claude.ai` has a
        // partial outage (the failure frame) — so with Cowork monitoring on, the popup shows a row per
        // component (`API`, `Code`, `WEB/Desktop`, `Cowork`), each with its own status. Otherwise only
        // the API is degraded, everything else operational. The incident is *ignored* (all lines still
        // come from component.status). Lets the status lines be seen end-to-end without the live page.
        if request.url == StatusClient.endpoint {
            let failing = mode == .authError
            // Calm-degraded frame (#…): exactly one component degraded (the soft yellow state), the
            // rest operational — so `worstProblem` is `.degraded` and the menu bar draws a **yellow**
            // service dot, which calm colours then mute to white.
            let calmDegraded = mode == .calmDegraded
            // Stale-error frame (spacing bug): API + Code both **major outage** (the red dots from the
            // reported screenshot), everything else operational.
            let staleError = mode == .staleError
            let codeStatus = staleError ? "major_outage"
                : (failing || calmDegraded) ? "degraded_performance" : "operational"
            let apiStatus = staleError ? "major_outage"
                : calmDegraded ? "operational" : "degraded_performance"
            let webStatus = failing ? "partial_outage" : "operational"
            let coworkStatus = failing ? "degraded_performance" : "operational"
            let body = """
            {"status":{"indicator":"major","description":"Degraded"},\
            "components":[\
            {"name":"Claude Code","status":"\(codeStatus)"},\
            {"name":"Claude API (api.anthropic.com)","status":"\(apiStatus)"},\
            {"name":"claude.ai","status":"\(webStatus)"},\
            {"name":"Claude Cowork","status":"\(coworkStatus)"}],\
            "incidents":[{"name":"Stubbed incident","status":"monitoring","impact":"major",\
            "components":[{"name":"Claude Code"},{"name":"Claude API (api.anthropic.com)"}]}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: StatusClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Idle frame (#100, ADR-0027): `five_hour` with `resets_at: null` and **no** `session` entry in
        // `limits[]` → the decoder reports `sessionIdle == true` (no synthesized phantom reset). The
        // `seven_day` window is set ~4.2 days out so the menu-bar fallback shows "4d" live; a Fable
        // `weekly_scoped` row keeps a normal per-model section on screen. Mirrors the live "no active
        // session" body shape (Body A) verbatim.
        if mode == .idle {
            let sevenReset = Self.resetsAt(inSeconds: 4.2 * 24 * 3600)   // ≥ 24 h → "4d" via timeToResetCompactDays
            let body = """
            {"five_hour":{"utilization":0.0,"resets_at":null},\
            "seven_day":{"utilization":31.0,"resets_at":"\(sevenReset)"},\
            "limits":[\
            {"kind":"weekly_scoped","group":"weekly","percent":15,"severity":"normal",\
            "resets_at":"\(sevenReset)","scope":{"model":{"id":null,"display_name":"Fable"},\
            "surface":null},"is_active":false}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Idle-blocked frame (#158): same idle 5h shape as `.idle`, but the `seven_day` window is
        // **exhausted** (100 %) and there is **no** `spend` block, so credits cannot cover — the
        // snapshot is `sessionIdle && idleBlocked`. Verifies the grey idle bar (menu bar + popup), the
        // "waiting for limit reset" status word, and the red blocking-reset badge on the 7-day row (its
        // reset is ~4 days out, the only exhausted candidate → the blocking reset).
        if mode == .idleBlocked {
            let sevenReset = Self.resetsAt(inSeconds: 4.2 * 24 * 3600)   // ≥ 24 h → "4d"
            let body = """
            {"five_hour":{"utilization":0.0,"resets_at":null},\
            "seven_day":{"utilization":100.0,"resets_at":"\(sevenReset)"},\
            "limits":[]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Active-blocked frame (#177): a live 5h window (48 %) while `seven_day` is exhausted (100 %) and
        // there is no `spend` block, so the weekly cap blocks despite 5h quota. The `limits[]` carries the
        // server's real shape — a `weekly_all` entry at 100 % / critical / is_active — mirroring Артем's
        // captured payload. Not idle → the 5h row stays a normal "on pace" row, but the popup's 7-day
        // reset (the sole exhausted candidate, ~4 days out) is drawn **red** as the blocking reset. Before
        // the fix `isBlocked` returned false (it required 5h exhausted too) → no badge.
        if mode == .activeBlocked {
            let fiveReset = Self.resetsAt(inSeconds: 2 * 3600)          // active 5h, resets in ~2 h
            let sevenReset = Self.resetsAt(inSeconds: 4.2 * 24 * 3600)  // ≥ 24 h → "4d"
            let body = """
            {"five_hour":{"utilization":48.0,"resets_at":"\(fiveReset)"},\
            "seven_day":{"utilization":100.0,"resets_at":"\(sevenReset)"},\
            "limits":[\
            {"kind":"session","group":"session","percent":48,"severity":"normal",\
            "resets_at":"\(fiveReset)","is_active":false},\
            {"kind":"weekly_all","group":"weekly","percent":100,"severity":"critical",\
            "resets_at":"\(sevenReset)","is_active":true}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Broken-`resets_at` frame (#167, ADR-0043): a healthy 200 whose **noisy** 5h window (100 %)
        // carries `resets_at: null`. `selectReset` chooses the noisy 5h, finds no valid instant →
        // `.dataError(.fiveHour)`, so `make(...)` promotes the layout to the ⚠️ error state (glyph +
        // the last bars) rather than a fabricated "<1m". The 7-day window is calm with a valid reset,
        // so it is not the data-error source — the error comes purely from the chosen 5h.
        if mode == .brokenReset {
            let sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            // A **non-empty but unparseable** `resets_at` — NOT `null`. A null/empty 5h date decodes to
            // the honest `sessionIdle` state (ADR-0027), not a data error; a malformed *present* string
            // keeps the window active (`hasResetsAt == true`) while `ResetClock.parse` returns nil, which
            // is the real case-B path: an active window with a broken reset → ⚠️ (#167, ADR-0043).
            let body = """
            {"five_hour":{"utilization":100.0,"resets_at":"not-a-date"},\
            "seven_day":{"utilization":20.0,"resets_at":"\(sevenReset)"},\
            "limits":[]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Stale-while-erroring frame (spacing bug): the first usage poll returns a full valid snapshot,
        // then every later poll **throws** `URLError(.timedOut)`. The coordinator holds the last good
        // snapshot's bars while the poll fails, so the popup shows the ⚠️ "connectivity issue" /
        // "Authentication API timeout" banner **above** the full limit rows — the state where the error
        // block needs its trailing `sectionSpacing` gap. Body mirrors the reported screenshot: 5h idle
        // ("ready to start"), a 18 % 7-day window, a 0 % Fable per-model row, and an on-pace "Extra usage"
        // credits section (€11.68 / €15.00).
        if mode == .staleError {
            let first = calls == 0
            calls += 1
            guard first else { throw URLError(.timedOut) }
            let sevenReset = Self.resetsAt(inSeconds: 4.2 * 24 * 3600)   // ≥ 24 h → "5d"
            let body = """
            {"five_hour":{"utilization":0.0,"resets_at":null},\
            "seven_day":{"utilization":18.0,"resets_at":"\(sevenReset)"},\
            "limits":[\
            {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal",\
            "resets_at":"\(sevenReset)","scope":{"model":{"id":null,"display_name":"Fable"},\
            "surface":null},"is_active":false}],\
            "extra_usage":{"is_enabled":true,"monthly_limit":1500,"used_credits":1168.0,\
            "utilization":77.9,"currency":"EUR","decimal_places":2,"disabled_reason":null,\
            "user_disabled":false,"spend_limit_reached":false,"credits_ever_enabled":true,\
            "daily":null,"weekly":null},\
            "spend":{"used":{"amount_minor":1168,"currency":"EUR","exponent":2},\
            "limit":{"amount_minor":1500,"currency":"EUR","exponent":2},"percent":78,\
            "severity":"normal","enabled":true,"disabled_reason":null,"balance":null,\
            "auto_reload":null}}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Auth-failure frame: a 401 with a long, server-style body. UsageClient maps this to
        // `UsageError.http(401, body)` → `FailureReason.authHTTP`, exercising the popup's warning
        // block and the word-wrapping of a long error detail.
        if mode == .authError {
            let body = """
            Your OAuth token was rejected by the usage API (HTTP 401 Unauthorized). \
            The credentials in your macOS Keychain may have expired or been revoked — \
            sign in to Claude Code again so a fresh token is issued, then reopen this popup.
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Optimistic-reset frame (#36): first poll = active 5h resetting in ~20 s (60 %); every later
        // poll = a freshly-reset window (0 %, now + 5h), as the real API would report post-reset. Lets
        // the whole flow be watched: live countdown → optimistic 0 % flip (no ⏰) → forced refresh.
        if mode == .optimisticReset {
            let first = calls == 0
            calls += 1
            let fiveUtil = first ? 60.0 : 0.0
            let fiveReset = Self.resetsAt(inSeconds: first ? 20 : 5 * 3600)
            let sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            let body = """
            {"five_hour":{"utilization":\(fiveUtil),"resets_at":"\(fiveReset)"},\
            "seven_day":{"utilization":40.0,"resets_at":"\(sevenReset)"},\
            "limits":[]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Reset-boundary idle-grace frame (ADR-0041, ADR-0045): active window (polls 0–1) → post-reset
        // **empty** body (polls 2–3, `five_hour.resets_at: null`, no `session` limit → would decode
        // `sessionIdle == true`) → active again (polls 4+). The grace gate holds the 5h bar non-idle
        // across the two empty polls, so the menu bar must NOT blink to "waiting for limit reset"
        // between the active windows. Per ADR-0045 the held bar must read a calm 0% "on pace" with a
        // rolled-forward countdown (`Nh at …`) — NEVER "resetting…" or a full-width green bar. Note
        // the grace only arms when `claudeActive` is true (a live `claude` process) AND utilization
        // rose recently; the active polls 0–1 (util 40) satisfy the freshness clock, so with `claude`
        // running the grace holds. With no `claude` process the fix instead surfaces idle immediately
        // ("ready to start") — the genuine-pause path.
        if mode == .resetGrace {
            let n = calls
            calls += 1
            let empty = (n == 2 || n == 3)
            let sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            let fiveBody: String
            if empty {
                // Post-reset gap: server has no 5h window yet (created by the first token spend).
                fiveBody = #""five_hour":{"utilization":0.0,"resets_at":null}"#
            } else {
                // Active window, mid-window (n<2) or freshly reset (n>3).
                let fiveReset = Self.resetsAt(inSeconds: 3 * 3600)
                let fiveUtil = n < 2 ? 40.0 : 5.0
                fiveBody = #""five_hour":{"utilization":\#(fiveUtil),"resets_at":"\#(fiveReset)"}"#
            }
            let body = """
            {\(fiveBody),\
            "seven_day":{"utilization":40.0,"resets_at":"\(sevenReset)"},\
            "limits":[]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Back-to-work frame (#160): first poll = blocked (7-day at 100 %, no credits → canWork false),
        // so the persisted "was blocked" flag is set; every later poll = workable (7-day at 40 %). The
        // blocked→unblocked edge fires once, posting the "Back to work!" banner (if enabled + in the
        // allowed hours + not a suppressed day + authorized).
        if mode == .justUnblocked {
            let blocked = calls == 0
            calls += 1
            let sevenUtil = blocked ? 100.0 : 40.0
            let fiveReset = Self.resetsAt(inSeconds: 3 * 3600)
            let sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            let body = """
            {"five_hour":{"utilization":18.0,"resets_at":"\(fiveReset)"},\
            "seven_day":{"utilization":\(sevenUtil),"resets_at":"\(sevenReset)"},\
            "limits":[]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Extra-usage onset frame: first poll = not on credits (7-day 40 %, so no main window is
        // exhausted → `isOnCredits` false even with credits enabled), every later poll = 7-day at 100 %
        // with the same enabled credits blocks (`isOnCredits` true). The not-spending→spending edge
        // fires once, posting the "Now using Extra Usage Credit" banner with the spent amount + limit.
        if mode == .creditsOnset {
            let onCredits = calls > 0
            calls += 1
            let sevenUtil = onCredits ? 100.0 : 40.0
            let fiveReset = Self.resetsAt(inSeconds: 3 * 3600)
            let sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            // A `weekly_all` critical limit only once the 7-day window is actually exhausted.
            let weeklyLimit = onCredits
                ? #""limits":[{"kind":"weekly_all","group":"weekly","percent":100,"severity":"critical","resets_at":"\#(sevenReset)","scope":null,"is_active":true}],"#
                : #""limits":[],"#
            let body = """
            {"five_hour":{"utilization":18.0,"resets_at":"\(fiveReset)"},\
            "seven_day":{"utilization":\(sevenUtil),"resets_at":"\(sevenReset)"},\
            \(weeklyLimit)\
            \(CreditsFrame.active.blocks)}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        // Money-credits frame (#144): a healthy 5h bar plus a **7-day window pinned at 100 %** so a
        // base limit is exhausted and the credits icon's show-trigger fires (`anyBaseLimitExhausted`).
        // The `spend` + `extra_usage` blocks come from the frame; the icon colour then follows the
        // month-elapsed pacing (`CreditsPacing.barLayout`). Status endpoint stays all-operational so the
        // frame reads clean (handled in the status branch above).
        if case let .credits(frame) = mode {
            let fiveReset = Self.resetsAt(inSeconds: 3 * 3600)          // active 5h, mid-window
            let sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)    // weekly limit hit, resets in 5 d
            let body = """
            {"five_hour":{"utilization":18.0,"resets_at":"\(fiveReset)"},\
            "seven_day":{"utilization":100.0,"resets_at":"\(sevenReset)"},\
            "limits":[{"kind":"weekly_all","group":"weekly","percent":100,"severity":"critical",\
            "resets_at":"\(sevenReset)","scope":null,"is_active":true}],\
            \(frame.blocks)}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        let n = calls
        calls += 1

        let five: Double
        let seven: Double
        // Two weekly_scoped per-model rows, chosen to show a couple of the ahead-of-pace gap colours
        // against the 7-day windows' shared ≈29 % elapsed (their **time** use is unchanged; only the
        // **token** utilisation moves): Fable ahead ~31 pts → ORANGE, Mythos exhausted → RED.
        // `PopupBarView.aheadColor` grades by `usage − time` against a dynamic threshold that shrinks
        // as the window drains (`0.16·(1−timeFraction)`), plus a ≤20-min-to-reset orange override.
        let fable: Double
        let mythos: Double
        let fiveReset: String
        let sevenReset: String
        let weeklyReset: String

        // `.calmDegraded` reuses the calm-both bar frame for its usage side — only its service dot
        // differs (handled in the status branch above) — so resolve both to a `PacingFrame`.
        let pacingFrame: PacingFrame? = switch mode {
        case let .pacing(frame): frame
        case .calmDegraded:      .calmBoth
        default:                 nil
        }
        if let frame = pacingFrame {
            // Fixed severity frame for reset-countdown verification (#103). Per-model rows kept as in
            // the climbing default so the popup still has content; only the top-level bars are pinned.
            let v = frame.values
            five = v.five
            seven = v.seven
            // Per-model rows are otherwise pinned to the climbing default (60/100) so the popup has
            // content; the near-zero frame instead pins them near-zero too, so every row exercises the
            // min-strip pill geometry at once.
            if frame == .nearZero {
                fable = 4.0
                mythos = 1.5
            } else {
                fable = 60.0
                mythos = 100.0
            }
            fiveReset = Self.resetsAt(inSeconds: v.fiveIn)
            sevenReset = Self.resetsAt(inSeconds: v.sevenIn)
            weeklyReset = sevenReset
        } else if mode == .screenshot {
            // Hand-picked, frozen frame for the README screenshot. Pacing states on screen:
            //  • 5h: 10 % used vs ≈65 % elapsed (resets ~35 % of the window out, now + 1.75 h, snapped
            //    to a 10-minute mark) → wide GREEN gap, well behind pace.
            //  • 7d: 36 % used vs ≈29 % elapsed (resets ~5 d out on the hour) → ahead ~7 pts, which is
            //    comfortably below the ≈11-pt yellow→orange threshold (0.16·(1−time)) → YELLOW, not on
            //    the amber/orange edge the old 40 % sat on.
            //  • Fable 70 % / Mythos 100 % (same ≈29 % elapsed) → ORANGE / RED.
            five = 10.0
            seven = 36.0
            fable = 70.0
            mythos = 100.0
            // 5h window = 18000 s; reset at ≈ now + 6300 s ⇒ elapsed ≈ 65 %, snapped to :x0.
            fiveReset = Self.resetsAtRounded10(inSeconds: 6300)
            weeklyReset = Self.isoString(Self.hourBoundary(daysFromNow: 5))
            sevenReset = weeklyReset                    // 7d and every per-model row end at the same boundary
        } else {
            // Step utilisation every 3rd poll so some adjacent polls are "unchanged" (cadence
            // doubles) and some "changed" (cadence resets) — exercising the live interval logic.
            five = 20.0 + Double((n / 3) * 5)
            seven = 55.0 + Double((n / 3) * 3)
            fable = 60.0
            mythos = 100.0
            // Windows anchored to "now", chosen to show one of each pacing state on screen:
            //  • 5h resets in ~2 h → ≈60 % elapsed > 20 % used → behind pace → GREEN gap.
            //  • 7d resets in ~5 d → only ≈29 % elapsed < 55 % used → ahead of pace → ORANGE gap.
            //  • Per-model rows share the 7d reset (≈29 % elapsed) → ORANGE / RED (#65).
            fiveReset = Self.resetsAt(inSeconds: 2 * 3600)
            sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            weeklyReset = sevenReset
        }
        // These models have NO top-level window in the live API — each exists only as a `weekly_scoped`
        // entry of `limits[]` (#65), so the stub mirrors that exact shape. Order = Fable, Mythos.
        func scopedLimit(_ name: String, _ percent: Double) -> String {
            """
            {"kind":"weekly_scoped","group":"weekly","percent":\(percent),"severity":"normal",\
            "resets_at":"\(weeklyReset)","scope":{"model":{"id":null,"display_name":"\(name)"},\
            "surface":null},"is_active":false}
            """
        }
        let scoped = [scopedLimit("Fable", fable), scopedLimit("Mythos", mythos)]
            .joined(separator: ",")
        let body = """
        {"five_hour":{"utilization":\(five),"resets_at":"\(fiveReset)"},\
        "seven_day":{"utilization":\(seven),"resets_at":"\(sevenReset)"},\
        "limits":[\(scoped)]}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (body, response)
    }
}

// MARK: - StubTokenProvider (verification only — paired with TOKENPACE_STUB)

/// A `TokenProviding` that returns a literal placeholder token without touching the Keychain. Used
/// only under `TOKENPACE_STUB`: the stub transport answers canned responses and never validates the
/// bearer, so reading the real Keychain would be pointless — and would pop the system's Keychain
/// access prompt for an unsigned `swift run` / dev build. Skipping it keeps the stub run silent.
struct StubTokenProvider: TokenProviding {
    func currentCredentials(now: Date) throws -> TokenCredentials {
        // A far-future expiry so the engine treats the stub token as valid and the Troubleshoot
        // window's token section shows a live read/expires pair end-to-end (ADR-0020).
        TokenCredentials(accessToken: "stub-token", expiresAt: now.addingTimeInterval(8 * 3600))
    }
}

// MARK: - ExpiredStubTokenProvider (verification only — paired with TOKENPACE_FORCE_REFRESH)

/// A `TokenProviding` that always reports an *expired* token, so the polling engine takes its
/// `.expired` branch and triggers the delegated refresh. Used only under `TOKENPACE_FORCE_REFRESH=1`
/// (with no `TOKENPACE_STUB`), which keeps the *real* `ClaudeCLIRefresher` wired in — the point is to
/// exercise the on-demand `claude --safe-mode …` spawn (and verify no TCC prompt is attributed to
/// TokenPace, #183) without waiting for a natural token expiry. The engine still re-reads the real
/// Keychain after the spawn to judge success, so a real refresh can genuinely succeed.
struct ExpiredStubTokenProvider: TokenProviding {
    func currentCredentials(now: Date) throws -> TokenCredentials {
        // One second in the past → `isExpired(now:)` (expiresAt <= now) is true every poll.
        TokenCredentials(accessToken: "expired-stub-token", expiresAt: now.addingTimeInterval(-1))
    }
}
