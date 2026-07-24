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
final class SignalHub: Sendable {
    let stream: AsyncStream<PollSignal>
    private let continuation: AsyncStream<PollSignal>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(
            of: PollSignal.self, bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ signal: PollSignal) {
        continuation.yield(signal)
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

    /// Begin monitoring; `onRestored` fires on each connectivity restoration.
    func start(onRestored: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
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
    /// the 30-min override, which is the conservative cadence).
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
    ///  • `.optimisticReset` (`=optimistic-reset`) — the reset-boundary frame (#36): the first poll's 5h
    ///    window resets in ~20 s at 60 % util, so the coordinator's one-shot timer fires shortly after
    ///    launch — the 5h bar flips 60 % → 0 % with a fresh ~5 h countdown (no ⏰) and a forced refresh
    ///    follows. Every later poll returns a freshly-reset window (0 %, now + 5h).
    /// The climbing/screenshot data modes also carry two `weekly_scoped` per-model entries in `limits[]`
    /// (#65) — Fable / Mythos — so the scoped-model popup rows are exercised end-to-end, and their
    /// utilisations (plus the 7-day window) show a couple of the ahead-of-pace gap colours.
    enum Mode: Equatable {
        case climbing, screenshot, authError, idle
        /// The optimistic-reset frame (#36): the first poll returns an **active** 5h window whose reset
        /// is only ~20 s out (utilisation 60 %), so the coordinator's one-shot timer fires shortly after
        /// launch. On fire the 5h bar flips 60 % → 0 % with a fresh ~5 h countdown (the optimistic
        /// overlay, no ⏰), then the forced refresh lands: from the second poll on the stub returns a
        /// freshly-reset window (0 %, `now + 5h`), mirroring what the real API would report post-reset.
        case optimisticReset
        /// A fixed 5h×7d severity frame for verifying the reset-countdown selection table (#103).
        case pacing(PacingFrame)
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
        /// 5h **calm** (usage 10 vs elapsed ~20 → green) + 7d **orange** ahead-of-pace (usage 55 vs
        /// elapsed ~29 → ahead ~26 pts) with a **distant** reset (5 d ≥ 24 h). The only frame where the
        /// "Display reset countdown" checkbox toggles a visible difference: `showDistant7d` shows the
        /// 7d countdown, `hideDistant7d` hides it (the "lone distant 7d orange" cell, #103/ADR-0029).
        case calmFiveOrangeSeven

        /// (fiveUtil, sevenUtil, fiveResetSeconds, sevenResetSeconds).
        var values: (five: Double, seven: Double, fiveIn: TimeInterval, sevenIn: TimeInterval) {
            switch self {
            case .fiveOrange:         return (50, 20, 4 * 3600, 5 * 24 * 3600)
            case .bothOrange:         return (50, 55, 4 * 3600, 5 * 24 * 3600)
            case .bothRed:            return (100, 100, 2 * 3600, 4 * 24 * 3600)
            case .redOrange:          return (100, 55, 2 * 3600, 5 * 24 * 3600)
            case .calmFiveOrangeSeven: return (10, 55, 4 * 3600, 5 * 24 * 3600)
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
            let codeStatus = failing ? "degraded_performance" : "operational"
            let webStatus = failing ? "partial_outage" : "operational"
            let coworkStatus = failing ? "degraded_performance" : "operational"
            let body = """
            {"status":{"indicator":"major","description":"Degraded"},\
            "components":[\
            {"name":"Claude Code","status":"\(codeStatus)"},\
            {"name":"Claude API (api.anthropic.com)","status":"degraded_performance"},\
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

        let n = calls
        calls += 1

        let five: Double
        let seven: Double
        // Two weekly_scoped per-model rows, chosen to show a couple of the ahead-of-pace gap colours
        // against the 7-day windows' shared ≈29 % elapsed (their **time** use is unchanged; only the
        // **token** utilisation moves): Fable ahead ~31 pts → ORANGE, Mythos exhausted → RED.
        // `PopupBarView.aheadColor` grades by `usage − time` (15-pt threshold).
        let fable: Double
        let mythos: Double
        let fiveReset: String
        let sevenReset: String
        let weeklyReset: String

        if case let .pacing(frame) = mode {
            // Fixed severity frame for reset-countdown verification (#103). Per-model rows kept as in
            // the climbing default so the popup still has content; only the top-level bars are pinned.
            let v = frame.values
            five = v.five
            seven = v.seven
            fable = 60.0
            mythos = 100.0
            fiveReset = Self.resetsAt(inSeconds: v.fiveIn)
            sevenReset = Self.resetsAt(inSeconds: v.sevenIn)
            weeklyReset = sevenReset
        } else if mode == .screenshot {
            // Hand-picked, frozen frame for the README screenshot. Pacing states on screen:
            //  • 5h: 10 % used vs ≈65 % elapsed (resets ~35 % of the window out, now + 1.75 h, snapped
            //    to a 10-minute mark) → wide GREEN gap, well behind pace.
            //  • 7d: 40 % used vs ≈29 % elapsed (resets ~5 d out on the hour) → ahead ~11 pts → AMBER.
            //  • Fable 70 % / Mythos 100 % (same ≈29 % elapsed) → ORANGE / RED.
            five = 10.0
            seven = 40.0
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
