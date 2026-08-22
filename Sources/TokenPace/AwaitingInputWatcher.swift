import Foundation
import CoreServices
import TokenPaceKit

// MARK: - AwaitingInputWatcher

/// Keeps the "N sessions awaiting input" count fresh and pushes it to the UI, per
/// `docs/design/awaiting-input-refresh.md`. Thin platform glue over the pure
/// ``TokenPaceKit/AwaitingInputScanner`` (which owns the parsing and the liveness filter) — this
/// type only *drives* scans from two triggers and coalesces them.
///
/// **Triggers.**
/// - **FSEvents** on `~/.claude/sessions` and `~/.claude/jobs` (recursive, file-level). The OS wakes
///   us with a coalesced batch of changed paths; `latency` batches a burst of writes into one
///   callback (the "event-processing interval").
/// - **Safety poll**: a rare timer (``safetyPollInterval``) that also scans, to catch anything
///   FSEvents coalesced away or dropped across sleep/logout.
///
/// **Gating.** The whole watcher only runs while the feature is enabled **and** the screen is
/// available (unlocked, no screensaver, display and system awake — #275).
/// ``setActive(_:reason:)`` starts/stops the FSEvents stream and the safety timer wholesale — no work
/// while parked. On each (re)start we run one catch-up scan, so events missed while parked are
/// reconciled immediately rather than at the next safety tick.
///
/// There is deliberately **no "Claude is running" term**: with no `claude` alive nothing writes to
/// the watched trees, so FSEvents is already silent and the residual cost is one ~0.18 ms scan per
/// safety tick. Sessions left behind by a killed `claude` are filtered by
/// ``TokenPaceKit/AwaitingInputScanner``'s liveness check instead, which fixes the actual
/// user-visible bug (a hand that never goes down) rather than the cost.
///
/// **Quiet by default.** No per-event / per-tick logging on the steady-state path. We log only when
/// the count actually changes, when the stream starts/stops, or on an error the user could act on.
/// Development detail sits behind `.debug` / `TOKENPACE_DEVTOOLS`.
///
/// The callback fires **only when the count differs** from the last reported value (including the
/// initial 0 → N), so the render path re-runs only on a real change.
@MainActor
final class AwaitingInputWatcher {
    /// Rare backstop cadence — FSEvents is the primary trigger; this only catches missed/coalesced
    /// events (e.g. across a sleep the gate didn't cover). Deliberately coarse.
    static let safetyPollInterval: TimeInterval = 45

    /// FSEvents coalescing latency: a burst of writes within this window arrives as one batch.
    private static let fsEventsLatency: CFTimeInterval = 0.75

    private let scanner: AwaitingInputScanner
    private let watchedPaths: [String]
    private let devLoggingEnabled: Bool
    /// Fired on the main actor whenever the awaiting result changes (count, urgency, or breakdown).
    private let onResultChanged: @MainActor (AwaitingSessions) -> Void

    private var stream: FSEventStreamRef?
    private var safetyTimer: Timer?
    /// Last result pushed to the UI; `nil` until the first scan so the initial value always fires.
    private var lastResult: AwaitingSessions?
    /// A scan already scheduled for the next runloop turn — coalesces multiple triggers into one.
    private var scanScheduled = false

    /// - Parameters:
    ///   - claudeHome: the `~/.claude` directory (injectable for tests / dev).
    ///   - devLoggingEnabled: emit `.debug` per-batch detail (wired to `TOKENPACE_DEVTOOLS`).
    ///   - onResultChanged: called on the main actor with the new result on every change.
    init(
        claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
        devLoggingEnabled: Bool = ProcessInfo.processInfo.environment["TOKENPACE_DEVTOOLS"] != nil,
        onResultChanged: @escaping @MainActor (AwaitingSessions) -> Void
    ) {
        self.scanner = AwaitingInputScanner(claudeHome: claudeHome)
        self.watchedPaths = [
            claudeHome.appendingPathComponent("sessions").path,
            claudeHome.appendingPathComponent("jobs").path,
        ]
        self.devLoggingEnabled = devLoggingEnabled
        self.onResultChanged = onResultChanged
    }

    // MARK: Lifecycle gate

    /// Turn the watcher on or off wholesale. `true` starts the FSEvents stream + safety timer and
    /// runs one catch-up scan; `false` tears both down. Idempotent.
    ///
    /// Call with the AND of: feature-enabled and screen-available. The shell recomputes this whenever
    /// any input changes (Settings toggle, lock/unlock, system sleep/wake) — see
    /// `AppDelegate.updateAwaitingInputWatcher()`.
    ///
    /// - Parameter reason: what moved the gate, for the log line (e.g. `screen locked`).
    func setActive(_ active: Bool, reason: String) {
        if active {
            guard stream == nil else { return }   // already running
            startStream()
            startSafetyTimer()
            AppLogger.lifecycle.notice("awaiting-input: resumed (\(reason, privacy: .public))")
            scanNow()                             // catch-up scan on (re)start
        } else {
            guard stream != nil || safetyTimer != nil else { return }
            stopStream()
            safetyTimer?.invalidate(); safetyTimer = nil
            // Forget the last result so the next start re-reports. Note this does NOT clear what the
            // UI shows: on a screen-lock park the shell deliberately keeps the last count on screen
            // (nobody can see it anyway) and the catch-up scan re-reports on resume.
            lastResult = nil
            AppLogger.lifecycle.notice("awaiting-input: parked (\(reason, privacy: .public))")
        }
    }

    /// Force an immediate scan (e.g. the shell wants a value right after enabling the feature).
    func scanNow() { performScan() }

    // MARK: FSEvents

    private func startStream() {
        // `self` is handed to the C callback via the stream context. We balance the retain in
        // `stopStream()` by releasing there; the callback re-derives the instance from `info`.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagIgnoreSelf)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.fsEventsLatency,
            flags
        ) else {
            // Rare: watched dirs unresolvable. Fall back to the safety timer alone (already armed).
            AppLogger.lifecycle.error("awaiting-input: FSEventStreamCreate failed; safety poll only")
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called by the C trampoline on the main queue with a batch of changed paths. We don't inspect
    /// the paths (the mtime cache already skips unchanged files) — a batch just means "something in
    /// the watched trees moved", so coalesce into one scan.
    fileprivate func handleFSEventsBatch(count: Int) {
        if devLoggingEnabled {
            AppLogger.lifecycle.debug("awaiting-input: FSEvents batch of \(count, privacy: .public) path(s)")
        }
        scheduleCoalescedScan()
    }

    // MARK: Safety poll

    private func startSafetyTimer() {
        let timer = Timer(timeInterval: Self.safetyPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.performScan() }
        }
        // `.common` so it still fires while a menu / popup tracking runloop is active.
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    // MARK: Scan coalescing

    /// Coalesce multiple triggers in the same runloop turn into a single scan.
    private func scheduleCoalescedScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.performScan()
        }
    }

    private func performScan() {
        let result = scanner.scan(now: Date())
        guard result != lastResult else { return }   // steady state: silent, no render
        let previous = lastResult
        lastResult = result
        // Log only a real transition (rare). `previous == nil` is the first scan after start. Include
        // the urgency so the log is useful when the count is unchanged but a session crossed a bucket.
        AppLogger.lifecycle.notice(
            "awaiting-input \(previous?.count.description ?? "—", privacy: .public) → \(result.count, privacy: .public) (urgency \(result.urgency.rawValue, privacy: .public))")
        onResultChanged(result)
    }
}

// MARK: - FSEvents C trampoline

/// C-ABI callback for `FSEventStreamCreate`. Recovers the `AwaitingInputWatcher` from `info` and
/// forwards the batch. Runs on the stream's dispatch queue (main) — so hopping to the main actor is
/// a formality, but we assert it for Swift-concurrency correctness.
private let fsEventsCallback: FSEventStreamCallback = {
    (_ stream, _ info, _ numEvents, _ eventPaths, _ eventFlags, _ eventIds) in
    guard let info else { return }
    let watcher = Unmanaged<AwaitingInputWatcher>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated {
        watcher.handleFSEventsBatch(count: numEvents)
    }
}
