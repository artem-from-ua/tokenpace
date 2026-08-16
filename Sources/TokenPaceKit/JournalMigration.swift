import Foundation

// MARK: - JournalMigration

/// Rewrites an existing usage journal into the current sample format (#386) — the pure, I/O-free half
/// of the migration. The shell owns the files, the locking and the atomic swap; this owns the
/// decision of what each line becomes.
///
/// ## Why a rewrite rather than a tolerant reader
///
/// v2 does not just *add* fields — it changes what `util` means (the value the app acted on, not the
/// API's) and drops `gap`. A reader could branch on `v`, but then every consumer downstream carries
/// that branch forever, and the first one to forget it silently mixes two different quantities into
/// one series. One rewrite, once, and the history is uniform.
///
/// ## Why the values are recomputed rather than copied across
///
/// Every v1 line already carries `h5.util`, `d7.util` and a timestamp — verified across the live
/// journals, **100 % of records** have all three. That is exactly the input the reconstruction needs,
/// so the migrated `util` is produced by the **same algorithm that runs live**, replayed over the
/// history in order. Nothing is invented: had the feature existed then, those are the numbers it
/// would have written.
///
/// The migrated lines therefore carry ordinary ``WeeklyUtilization/Source`` values, with no separate
/// "backfilled" marker — the algorithm and the result are the same, so a distinction would suggest a
/// difference that does not exist.
///
/// ## What the migration must survive
///
/// - **Lines that are not usage samples** (`status`, `error`, `resume`) pass through verbatim.
/// - **Unparseable lines** pass through verbatim too, and are counted. A corrupt tail from a crash
///   mid-append must not cost the whole file.
/// - **Out-of-order timestamps.** Found in a real journal: one line at 11:03 sitting before one at
///   10:37 (two processes writing under `flock`). Sorting the stream would silently reorder the
///   file; feeding it to the interpolator unsorted would invent a `util` drop that never happened.
///   So the reconstruction is driven by a **monotonic clock filter** — a line whose timestamp goes
///   backwards is written through with its own values and does not advance the estimator.
public enum JournalMigration {

    /// What one migration pass did — enough for a log line and for the caller to decide whether the
    /// swap is worth doing at all.
    public struct Outcome: Sendable, Equatable {
        /// Lines rewritten into the current format.
        public let migrated: Int
        /// Lines carried across untouched (other record kinds, already-current lines).
        public let passedThrough: Int
        /// Lines that could not be parsed and were preserved verbatim.
        public let skipped: Int
        /// Lines whose timestamp went backwards relative to the line before it.
        public let outOfOrder: Int

        public init(migrated: Int, passedThrough: Int, skipped: Int, outOfOrder: Int) {
            self.migrated = migrated
            self.passedThrough = passedThrough
            self.skipped = skipped
            self.outOfOrder = outOfOrder
        }

        /// Whether the pass changed anything — `false` means the file is already current and the
        /// caller can skip the rewrite (and the backup) entirely.
        public var changedAnything: Bool { migrated > 0 }

        /// A `.public`-safe one-liner for the migration log.
        public var logMessage: String {
            var out = "journal migrated: \(migrated) rewritten, \(passedThrough) unchanged"
            if skipped > 0 { out += ", \(skipped) unparseable" }
            if outOfOrder > 0 { out += ", \(outOfOrder) out of order" }
            return out
        }
    }

    /// Migrate one file's contents, returning the new contents and what happened.
    ///
    /// - Parameters:
    ///   - contents: the whole file, as written.
    ///   - state: the reconstruction state carried in from the previous file — the journal is split
    ///     by month, and starting each month cold would leave every January line on an inherited
    ///     anchor for no reason. Pass the returned state into the next file, in chronological order.
    /// - Returns: the rewritten contents, the state to carry forward, and the outcome.
    public static func migrate(
        contents: String,
        state: WeeklyInterpolator = WeeklyInterpolator()
    ) -> (contents: String, state: WeeklyInterpolator, outcome: Outcome) {
        var interpolator = state
        var lastAccepted: Date?
        var migrated = 0, passedThrough = 0, skipped = 0, outOfOrder = 0
        var out: [String] = []

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(line); continue }

            guard let data = trimmed.data(using: .utf8),
                  let record = try? decoder.decode(JournalRecord.self, from: data),
                  case let .usage(sample) = record else {
                // Not a usage line, or not parseable at all: keep the original bytes. A file that
                // cannot be fully understood is still a file worth preserving exactly.
                out.append(line)
                if (try? decoder.decode(JournalRecord.self, from: Data(trimmed.utf8))) == nil {
                    skipped += 1
                } else {
                    passedThrough += 1
                }
                continue
            }

            guard sample.v < UsageSample.currentVersion else {
                out.append(line)                 // already current
                passedThrough += 1
                continue
            }

            // Drive the estimator only with lines that move time forward. An out-of-order line is
            // rewritten from its own values but must not teach the estimator anything, or it would
            // register a spend "drop" that never occurred.
            let at = ResetClock.parse(sample.t)
            let goesBackwards = at == nil || (lastAccepted.map { at! < $0 } ?? false)
            if goesBackwards { outOfOrder += 1 }

            let weekly: WeeklyUtilization
            if let at, !goesBackwards {
                interpolator = interpolator.advanced(
                    with: snapshot(from: sample), now: at)
                lastAccepted = at
                weekly = interpolator.value(forRaw: sample.d7.raw)
            } else {
                weekly = .passthrough(sample.d7.raw)
            }

            let rewritten = UsageSample(
                v: UsageSample.currentVersion,
                t: sample.t, ms: sample.ms, plan: sample.plan, tier: sample.tier,
                h5: sample.h5,
                d7: WindowSample(
                    util: weekly.effective, raw: weekly.raw,
                    src: weekly.source.rawValue, n: weekly.ratio,
                    reset: sample.d7.reset, timePct: sample.d7.timePct, sev: sample.d7.sev,
                    windowSeconds: LimitWindow.sevenDay.durationSeconds),
                opus: sample.opus, sonnet: sample.sonnet, scoped: sample.scoped,
                sessionIdle: sample.sessionIdle, spend: sample.spend,
                blocked: sample.blocked, credits: sample.credits,
                brokenReset: sample.brokenReset, blockingReset: sample.blockingReset)

            guard let encoded = try? encoder.encode(JournalRecord.usage(rewritten)),
                  let text = String(data: encoded, encoding: .utf8) else {
                out.append(line)                 // encoding failed: never lose the original
                skipped += 1
                continue
            }
            out.append(text)
            migrated += 1
        }

        return (out.joined(separator: "\n"), interpolator,
                Outcome(migrated: migrated, passedThrough: passedThrough,
                        skipped: skipped, outOfOrder: outOfOrder))
    }

    /// The two counters the reconstruction reads, rebuilt from a journalled sample.
    ///
    /// `resetsAt` is carried across so a weekly reset is visible to the estimator as the drop it is;
    /// nothing else in the snapshot affects the reconstruction.
    private static func snapshot(from sample: UsageSample) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: sample.h5.raw, resetsAt: sample.h5.reset),
            sevenDay: UsageWindow(utilization: sample.d7.raw, resetsAt: sample.d7.reset))
    }
}
