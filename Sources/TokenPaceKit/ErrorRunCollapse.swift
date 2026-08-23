import Foundation

// MARK: - ErrorRun

/// A run of consecutive identical failures, accumulated but not yet written.
///
/// The journal records one line per run rather than one per attempt: a Keychain that cannot be read
/// fails on every poll, and writing each one produced 122 408 identical lines from a single outage —
/// 98% of a real user's journal, all of it saying the same thing (ADR-0123).
public struct ErrorRun: Sendable, Equatable {
    public let code: ErrorCode
    public let reason: String
    public let detail: String?
    /// `Retry-After` from the **first** attempt. Part of the identity: two 429s holding different
    /// hints are different failures, and merging them would invent a hold neither server asked for.
    public let retryAfter: TimeInterval?
    /// Latency of the first attempt. Not part of the identity — a measurement of one attempt, not a
    /// property of the class of failure.
    public let ms: Int?
    public let first: Date
    public let last: Date
    public let count: Int

    public init(
        code: ErrorCode, reason: String, detail: String?, retryAfter: TimeInterval?, ms: Int?,
        first: Date, last: Date, count: Int
    ) {
        self.code = code
        self.reason = reason
        self.detail = detail
        self.retryAfter = retryAfter
        self.ms = ms
        self.first = first
        self.last = last
        self.count = count
    }
}

// MARK: - ErrorRunCollapse

/// Decides when consecutive failures are the same failure repeating, and when the run has to be
/// written out. Pure and clock-free in the shape of ``JournalGap``: the caller passes the open run,
/// the sample, and the instant.
///
/// The writer owns only the open slot and the I/O; the decision lives here because the executable
/// target has no test target of its own, and a rule this consequential must be unit-testable.
public enum ErrorRunCollapse {

    /// The widest a closed run may be — 3 minutes, the poll cadence.
    ///
    /// A **width** bound, not a gap that breaks the run. Bounding by the gap since the last attempt
    /// would let a 16 Hz storm accumulate for hours behind a single line, which is the opposite of
    /// what the journal is for: a 14-hour outage in the real incident would have left no trace at all
    /// until it ended, and none whatever if the app was killed first. Bounded by width, the same
    /// outage leaves one line every 3 minutes, each carrying its own `n`.
    public static let maxRunWidth: TimeInterval = 180

    /// What the writer should do with an incoming failure.
    public enum Decision: Sendable, Equatable {
        /// Same failure, still inside the window — keep accumulating, write nothing.
        case extend(ErrorRun)
        /// The run ended: write `closed`, then start accumulating `next`.
        case flush(closed: ErrorRun, next: ErrorRun)
    }

    /// Fold `sample` into `run`, or close it and start a new one.
    ///
    /// A sample extends the run when the code, reason, detail and `retryAfter` all match **and** the
    /// run would stay within ``maxRunWidth``. A sample that already carries `n` is a closed run in
    /// its own right and never extends anything — that is what makes a second migration pass a
    /// no-op rather than a slow merge of everything into one line.
    public static func admit(_ run: ErrorRun?, sample: ErrorSample, at instant: Date) -> Decision {
        // An already-collapsed sample carries its own end; taking `instant` for both would shrink the
        // run to its first attempt every time it passed through, so a second migration pass would
        // quietly rewrite `tEnd` and the pass would not be idempotent.
        let fresh = ErrorRun(
            code: sample.code, reason: sample.reason, detail: sample.detail,
            retryAfter: sample.retryAfter, ms: sample.ms,
            first: instant,
            last: sample.tEnd.flatMap(ResetClock.parse) ?? instant,
            count: sample.n ?? 1)

        guard let run else { return .extend(fresh) }   // nothing open yet

        let matches = sample.n == nil
            && run.code == sample.code
            && run.reason == sample.reason
            && run.detail == sample.detail
            && run.retryAfter == sample.retryAfter
            && instant.timeIntervalSince(run.first) <= maxRunWidth
        guard matches else { return .flush(closed: run, next: fresh) }

        return .extend(ErrorRun(
            code: run.code, reason: run.reason, detail: run.detail,
            retryAfter: run.retryAfter, ms: run.ms,
            first: run.first, last: instant, count: run.count + 1))
    }

    /// The line to write for a closed run, or `nil` when there is nothing open.
    ///
    /// A run of one is written as an ordinary error line: `n`/`tEnd` stay absent so a lone failure —
    /// the overwhelmingly common case — gains no noise.
    public static func close(_ run: ErrorRun?) -> ErrorSample? {
        guard let run else { return nil }
        let collapsed = run.count > 1
        return ErrorSample(
            t: ResetClock.isoString(from: run.first),
            code: run.code,
            reason: run.reason,
            detail: run.detail,
            retryAfter: run.retryAfter,
            ms: run.ms,
            n: collapsed ? run.count : nil,
            tEnd: collapsed ? ResetClock.isoString(from: run.last) : nil)
    }
}
