import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ProcessLiveness

/// Answers "is process `pid` still running, and is it the *same* process that wrote this session
/// file?" — the seam ``AwaitingInputScanner`` uses to drop sessions whose `claude` is gone (#275).
///
/// A session file outlives its process: `claude` killed (or crashed) while a permission prompt was
/// on screen leaves `"status":"waiting"` on disk forever, and nothing ever rewrites it. Without a
/// liveness check the menu-bar hand would count that dead session for as long as the file survives
/// — up to `cleanupPeriodDays` (30 by default, ADR-0031).
///
/// Injectable so tests can drive the decision from a fixture table instead of the real process
/// table, mirroring how ``AwaitingInputScanner`` injects `claudeHome` / `fileManager`.
public protocol ProcessLiveness: Sendable {
    /// The kernel's start time for `pid` (epoch seconds), or `nil` when no such process exists.
    ///
    /// Returning the start time rather than a plain `Bool` is what makes **pid reuse** detectable:
    /// pids are recycled, so "a process with this pid exists" alone would let an unrelated new
    /// process resurrect a dead session. The caller compares this against the `procStart` the
    /// session file recorded.
    func startTime(ofPID pid: Int32) -> Double?
}

// MARK: - KernelProcessLiveness

/// Production ``ProcessLiveness``: reads `p_starttime` straight from the process table via
/// `sysctl(KERN_PROC_PID)` — no subprocess spawn, no `ps` parsing, and no signal sent to the target.
///
/// Verified against Claude Code v2.1.220: the kernel start time matches the session file's
/// `procStart` string exactly, modulo sub-second precision (the kernel carries microseconds; the
/// file is truncated to whole seconds).
public struct KernelProcessLiveness: ProcessLiveness {
    public init() {}

    public func startTime(ofPID pid: Int32) -> Double? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A dead pid returns size == 0 (sysctl still succeeds), so both checks are load-bearing.
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        #else
        return nil
        #endif
    }
}
