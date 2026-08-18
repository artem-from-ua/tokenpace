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
        /// Lines whose weekly `resets_at` was a `now + 7d` estimate and has been rolled back onto the
        /// real grid, with `timePct` recomputed (ADR-0106). Counted separately from `migrated`
        /// because it is the one part of the pass that recovers *data* rather than reshaping it.
        public let resetsRepaired: Int

        public init(migrated: Int, passedThrough: Int, skipped: Int, outOfOrder: Int,
                    resetsRepaired: Int = 0) {
            self.migrated = migrated
            self.passedThrough = passedThrough
            self.skipped = skipped
            self.outOfOrder = outOfOrder
            self.resetsRepaired = resetsRepaired
        }

        /// Whether the pass changed anything — `false` means the file is already current and the
        /// caller can skip the rewrite (and the backup) entirely.
        public var changedAnything: Bool { migrated > 0 }

        /// A `.public`-safe one-liner for the migration log.
        public var logMessage: String {
            var out = "journal migrated: \(migrated) rewritten, \(passedThrough) unchanged"
            if resetsRepaired > 0 { out += ", \(resetsRepaired) weekly resets repaired" }
            if skipped > 0 { out += ", \(skipped) unparseable" }
            if outOfOrder > 0 { out += ", \(outOfOrder) out of order" }
            return out
        }
    }

    /// Whether a journal file belongs to this build — the pure half of picking which files to migrate.
    ///
    /// The trap this exists for: `usage-journal-` is also a prefix of `usage-journal-dev-…`, so a
    /// naive `hasPrefix` lets a **release** build adopt the dev journals and rewrite files that are
    /// not its own. (Caught before the first live run, on a machine where the dev file happened to
    /// already be current — so the damage would have been invisible rather than absent.)
    ///
    /// A release file's name continues with the year; a dev file's with `dev`.
    public static func belongsToBuild(fileName: String, isRelease: Bool) -> Bool {
        guard fileName.hasSuffix(".jsonl") else { return false }
        let devPrefix = "usage-journal-dev-"
        if isRelease {
            return fileName.hasPrefix("usage-journal-") && !fileName.hasPrefix(devPrefix)
        }
        return fileName.hasPrefix(devPrefix)
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
        var migrated = 0, passedThrough = 0, skipped = 0, outOfOrder = 0, resetsRepaired = 0
        var out: [String] = []
        // The last **server-supplied** weekly reset seen so far, used to repair the lines that
        // followed it during a blackout. Same anchor discipline as the live path: only a real date
        // may become one, or a repair would build on a repair.
        var weeklyAnchor: Date?

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

            // Repair a weekly reset that was written as a `now + 7d` estimate (ADR-0106). Those lines
            // are identifiable by their signature and recoverable from the anchor that preceded them;
            // `timePct` is recomputed with them, because it is derived from the date and was pinned
            // to 0 for the whole blackout.
            let repaired = repairWeeklyReset(sample.d7, at: at, anchor: weeklyAnchor)
            if repaired.source == .reconstructed { resetsRepaired += 1 }
            if !repaired.wasEstimated, let real = ResetClock.parse(sample.d7.reset), !goesBackwards {
                weeklyAnchor = real          // a genuine server date: the anchor for what follows
            }

            let rewritten = UsageSample(
                v: UsageSample.currentVersion,
                t: sample.t, ms: sample.ms, plan: sample.plan, tier: sample.tier,
                h5: sample.h5,
                d7: WindowSample(
                    util: weekly.effective, raw: weekly.raw,
                    utilSrc: weekly.source.rawValue, resetSrc: repaired.source.rawValue,
                    n: weekly.ratio,
                    reset: repaired.reset, timePct: repaired.timePct, sev: sample.d7.sev,
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
                        skipped: skipped, outOfOrder: outOfOrder, resetsRepaired: resetsRepaired))
    }

    /// What a repaired weekly window carries: the date, its recomputed elapsed fraction, where it
    /// came from, and whether the original had to be repaired at all.
    private struct RepairedReset {
        let reset: String
        let timePct: Double
        let source: ResetSource
        let wasEstimated: Bool
    }

    /// Whether a journalled `resets_at` is one of the old `now + 7d` estimates rather than a date the
    /// server sent.
    ///
    /// The signature is exact and needs no heuristics: the estimate was ceilinged to a 10-minute
    /// boundary (`ResetClock.ceilTo10Minutes`), while every real weekly reset the API sends carries
    /// **fractional seconds** — measured across 5 029 samples on one journal and 862 on another, with
    /// zero overlap.
    ///
    /// Tested on the **raw string**, not the parsed instant: `ResetClock.parse` deliberately strips
    /// the fractional part, so by the time a date exists the two are indistinguishable. Both halves
    /// must hold — a fractional-second value is always the server's, and a whole-second one still has
    /// to land on the 10-minute grid to be ours.
    private static func isEstimatedReset(_ raw: String, instant: Date) -> Bool {
        let hasFractionalSeconds = raw.range(
            of: #"\.\d+(?=([+-]\d{2}:?\d{2})$|Z$)"#, options: .regularExpression) != nil
        guard !hasFractionalSeconds else { return false }
        let epoch = instant.timeIntervalSince1970
        return epoch == epoch.rounded(.down) && Int(epoch) % 600 == 0
    }

    /// Repair one weekly window, rolling the anchor forward when the stored date was an estimate.
    ///
    /// Lines with no anchor before them are left exactly as they were: a repair needs something real
    /// to roll from, and inventing a different wrong answer would be worse than keeping the honest
    /// record of what the app showed. In practice this is rare — on both journals measured, every one
    /// of the 199 and 56 affected lines had an anchor earlier in the same file.
    private static func repairWeeklyReset(
        _ sample: WindowSample, at: Date?, anchor: Date?
    ) -> RepairedReset {
        guard let instant = ResetClock.parse(sample.reset) else {
            // No parseable date at all — nothing to repair, and nothing to claim about its source.
            return RepairedReset(reset: sample.reset, timePct: sample.timePct,
                                 source: .unknown, wasEstimated: false)
        }
        guard isEstimatedReset(sample.reset, instant: instant) else {
            return RepairedReset(reset: sample.reset, timePct: sample.timePct,
                                 source: .server, wasEstimated: false)
        }
        // An estimate. Roll the last real reset forward to the line's own timestamp — the same
        // arithmetic, including the same tolerance, the live decoder uses.
        guard let at, let anchor,
              let projected = ResetClock.rollForward(anchor: anchor, by: .sevenDay, until: at) else {
            return RepairedReset(reset: sample.reset, timePct: sample.timePct,
                                 source: .unknown, wasEstimated: true)
        }
        return RepairedReset(
            reset: ResetClock.isoString(from: projected),
            // Recomputed, not carried: the stored value was 0 for the whole blackout precisely
            // because the estimate kept the window looking un-started.
            timePct: PacingModel.elapsedFraction(resetsAt: projected, now: at, window: .sevenDay),
            source: .reconstructed,
            wasEstimated: true)
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
