import Foundation

/// Production `PollScheduler`. **The wait always elapses in full unless a real signal arrives** —
/// the single property that prevents a tight request loop.
///
/// `waitForNextPoll` asks the `SignalGate` for the next signal *with a deadline*: the gate returns
/// `.interrupted(signal)` if one arrives first, or `.elapsed` when the deadline passes. The deadline
/// sleep is **internal** to the gate and the waiter is resumed exactly once — there is no external
/// race between a `Task.sleep` and an un-cancellable `await`, which is what deadlocked an earlier
/// design. The earlier design before that returned `nil → .elapsed` instantly on a finished stream,
/// hammering the API ~50×/s; both regressions are covered by `LivePollSchedulerTests`.
///
/// Lives in `CCTimerKit` — not the app shell — precisely so it is unit-tested: it depends only on
/// `AsyncStream<PollSignal>` and `Task.sleep`, no AppKit/Network. The platform observers
/// (`NSWorkspace`, `NWPathMonitor`) that *feed* the stream stay in the shell.
public struct LivePollScheduler: PollScheduler {
    private let gate: SignalGate
    /// Multiplier from seconds to nanoseconds for the deadline. Injected only so tests exercise the
    /// real timing path without sleeping whole seconds; production uses 1e9.
    private let nanosPerSecond: Double

    public init(signals: AsyncStream<PollSignal>, nanosPerSecond: Double = 1_000_000_000) {
        self.gate = SignalGate(signals)
        self.nanosPerSecond = nanosPerSecond
    }

    public func waitForNextPoll(interval: TimeInterval) async -> PollWakeReason {
        let deadline = UInt64(max(0, interval) * nanosPerSecond)
        switch await gate.next(deadlineNanos: deadline) {
        case .some(let signal): return .interrupted(signal)
        case .none:             return .elapsed   // deadline passed with no signal
        }
    }

    public func waitWhileAsleep() async {
        // Block (no fetch while parked) until an awakening signal. A `.sleep` is ignored; a finished
        // stream blocks until the task is cancelled at terminate. No deadline → never wakes on a
        // timer, only on a real signal.
        while let signal = await gate.next(deadlineNanos: nil) {
            if signal == .wake || signal == .networkRestored { return }
        }
    }
}

/// Demultiplexes a single `AsyncStream<PollSignal>` and serves one `next(deadlineNanos:)` await at a
/// time. A single drain task is the stream's sole consumer (satisfying `AsyncIterator.next()`'s
/// `mutating` requirement); it hands each signal to a waiting caller or buffers the newest. The
/// optional deadline is implemented **inside** the actor by a child sleep task that resumes the
/// waiter with `nil` — so every waiter is resumed exactly once and nothing can deadlock a task group.
actor SignalGate {
    private var pending: PollSignal?
    private var waiter: CheckedContinuation<PollSignal?, Never>?
    private var finished = false

    init(_ signals: AsyncStream<PollSignal>) {
        Task { [weak self] in
            for await signal in signals {
                await self?.deliver(signal)
            }
            await self?.finish()
        }
    }

    /// The next signal, or `nil` if `deadlineNanos` elapses first (when given) or the stream is
    /// finished. A buffered signal returns immediately. Only one waiter is supported at a time, which
    /// matches the loop's strictly-sequential use.
    func next(deadlineNanos: UInt64?) async -> PollSignal? {
        if finished { return nil }
        if let signal = pending {
            pending = nil
            return signal
        }

        // Arm an optional deadline that resumes the waiter with `nil` if no signal arrives in time.
        let deadlineTask: Task<Void, Never>?
        if let deadlineNanos {
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: deadlineNanos)
                await self?.timeoutFired()
            }
        } else {
            deadlineTask = nil
        }

        let signal = await withCheckedContinuation { (continuation: CheckedContinuation<PollSignal?, Never>) in
            waiter = continuation
        }
        deadlineTask?.cancel()   // a signal (or finish) arrived first → stop the timer
        return signal
    }

    /// Deliver a signal to a waiter, or buffer the newest if none is waiting.
    private func deliver(_ signal: PollSignal) {
        if let continuation = waiter {
            waiter = nil
            continuation.resume(returning: signal)
        } else {
            pending = signal   // newest-wins; only the latest "we're awake/online" matters
        }
    }

    /// The deadline elapsed: resume the current waiter with `nil` (→ `.elapsed`). Idempotent — if a
    /// signal already resumed the waiter, `waiter` is nil and this is a no-op.
    private func timeoutFired() {
        if let continuation = waiter {
            waiter = nil
            continuation.resume(returning: nil)
        }
    }

    /// Stream finished: future `next` calls return `nil`, and any current waiter is resumed.
    private func finish() {
        finished = true
        if let continuation = waiter {
            waiter = nil
            continuation.resume(returning: nil)
        }
    }
}
