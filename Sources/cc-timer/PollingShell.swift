import AppKit
import CCTimerKit
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
    private let queue = DispatchQueue(label: "com.artem-n.cc-timer.network-monitor")
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

// MARK: - StubUsageTransport (verification only — CC_TIMER_STUB=1)

/// A canned `UsageTransport` for end-to-end verification without hitting the usage API. Returns a
/// 200 whose utilisation nudges upward every few polls, so the popup text, the bars, and the
/// adaptive cadence (changed → reset, unchanged → double) can all be seen by eye. **Never** used on
/// the default path — only when `CC_TIMER_STUB=1` is set.
///
/// `resets_at` is computed **relative to the current instant** (5 h / 7 d windows that are partway
/// elapsed), not hard-coded — otherwise the dates drift into the past and `elapsedFraction` pins to
/// `1.0`, making the pacing bar look broken (the time indicator stuck at the right edge).
actor StubUsageTransport: UsageTransport {
    private var calls = 0

    /// When `true`, utilisation stays at a fixed, hand-picked set of values instead of stepping up
    /// every few polls — a stable frame for the README screenshot (`CC_TIMER_STUB=screenshot`). The
    /// pacing states are still one-of-each (green / red / no-gap); only the climbing is frozen.
    private let fixed: Bool

    init(fixed: Bool = false) {
        self.fixed = fixed
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
        // Status endpoint (#31): a canned summary where Claude API is degraded and an active major
        // incident lists both components — so the popup shows a green Code dot + a yellow API dot,
        // and the incident is *ignored* (both lines still come from component.status). Lets the
        // status line be seen end-to-end without the live status page.
        if request.url == StatusClient.endpoint {
            let body = """
            {"status":{"indicator":"major","description":"Degraded"},\
            "components":[\
            {"name":"Claude Code","status":"operational"},\
            {"name":"Claude API (api.anthropic.com)","status":"degraded_performance"},\
            {"name":"claude.ai","status":"operational"}],\
            "incidents":[{"name":"Stubbed incident","status":"monitoring","impact":"major",\
            "components":[{"name":"Claude Code"},{"name":"Claude API (api.anthropic.com)"}]}]}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: StatusClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, response)
        }

        let n = calls
        calls += 1

        let five: Double
        let seven: Double
        let sonnet: Double
        let fiveReset: String
        let sevenReset: String
        let sonnetReset: String

        if fixed {
            // Hand-picked, frozen frame for the README screenshot. Pacing states on screen:
            //  • 5h: 40 % used vs ≈65 % elapsed (resets ~35 % of the window out, now + 1.75 h, snapped
            //    to a 10-minute mark) → GREEN gap, time indicator past the bar's two-thirds point.
            //  • 7d: 60 % used vs ≈29 % elapsed (resets ~5 d out on the hour) → ahead → RED gap (wide).
            //  • Sonnet: 2 % used, the SAME reset as 7d (so they end together) → behind pace → GREEN.
            five = 40.0
            seven = 60.0
            sonnet = 2.0
            // 5h window = 18000 s; reset at ≈ now + 6300 s ⇒ elapsed ≈ 65 %, snapped to :x0.
            fiveReset = Self.resetsAtRounded10(inSeconds: 6300)
            let weekly = Self.isoString(Self.hourBoundary(daysFromNow: 5))
            sevenReset = weekly
            sonnetReset = weekly                       // 7d and Sonnet end at the same hour boundary
        } else {
            // Step utilisation every 3rd poll so some adjacent polls are "unchanged" (cadence
            // doubles) and some "changed" (cadence resets) — exercising the live interval logic.
            five = 20.0 + Double((n / 3) * 5)
            seven = 55.0 + Double((n / 3) * 3)
            sonnet = 2.0
            // Windows anchored to "now", chosen to show one of each pacing state on screen:
            //  • 5h resets in ~2 h → ≈60 % elapsed > 20 % used → behind pace → GREEN gap.
            //  • 7d resets in ~5 d → only ≈29 % elapsed < 55 % used → ahead of pace → RED gap.
            //  • Sonnet resets so that elapsed ≈ 2 % == 2 % used → NO gap (indicator on the used
            //    edge). 7d window = 604800 s, so elapsed 2 % ⇒ remaining ≈ 0.98·604800 ≈ 592704 s.
            fiveReset = Self.resetsAt(inSeconds: 2 * 3600)
            sevenReset = Self.resetsAt(inSeconds: 5 * 24 * 3600)
            sonnetReset = Self.resetsAt(inSeconds: 0.98 * 604_800)
        }
        let body = """
        {"five_hour":{"utilization":\(five),"resets_at":"\(fiveReset)"},\
        "seven_day":{"utilization":\(seven),"resets_at":"\(sevenReset)"},\
        "seven_day_sonnet":{"utilization":\(sonnet),"resets_at":"\(sonnetReset)"},"limits":[]}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: UsageClient.endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (body, response)
    }
}
