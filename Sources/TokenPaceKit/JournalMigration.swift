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
/// ## Why `sev` is the opposite case (#426)
///
/// The v4 pass recomputes each window's colour bucket and **does** leave a marker — `sevRaw` on every
/// window whose verdict changed, plus ``UsageSample/sevV`` naming the model that decided it. That is
/// not an inconsistency with the paragraph above; it is the same rule applied to a different fact.
/// `util` is replayed through the algorithm that was always meant to produce it, so old and new agree
/// by construction. `sev` is replayed through a **different** algorithm from the one that wrote it —
/// thresholds moved, and per-model windows stopped being eligible for blue — so old and new genuinely
/// disagree, on 2 398 windows of the maintainer's August journal. Here a distinction records a
/// difference that exists, and dropping it would erase the only evidence of what the user was shown.
///
/// The two version counters follow from the same split: `v` says how to read a line, `sevV` says which
/// colour model judged it, and a future threshold change bumps only the second.
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
        /// real grid, with `timePct` recomputed (ADR-0107). Counted separately from `migrated` because
        /// it recovers *data* rather than reshaping it.
        public let resetsRepaired: Int
        /// Individual **windows** whose colour bucket changed when the current model was replayed over
        /// them (#426) — each one now carries a `sevRaw` with its original verdict.
        ///
        /// Windows, not lines: one sample holds up to six of them, and a line where only the scoped row
        /// moved is a different event from one where `h5` and `d7` both did. Distinct from
        /// ``resetsRepaired`` in kind as well as in count — that one restores a fact the app got wrong,
        /// this one re-judges a fact it recorded correctly under rules that have since changed.
        public let severitiesRecomputed: Int
        /// The **lowest** format version found among the lines this pass rewrote, or `nil` when it
        /// rewrote nothing.
        ///
        /// Exists so the shell can name the backup after what it actually contains
        /// (`.v2.bak` for a file that was v2) rather than after whichever migration existed when the
        /// suffix was first written (#401). The *lowest* rather than the highest, because a file
        /// that spans an upgrade legitimately holds several generations — the journal is append-only
        /// and outlives app versions — and the backup has to be labelled by the oldest thing in it,
        /// or the label overstates how recent the archive is.
        ///
        /// **`nil` when the pass rewrote lines that were already at the current format** — which
        /// happens when only the colour model moved (`sevV` behind ``UsageSample/currentColorVersion``,
        /// `v` already current). There is no older format in the file to name a backup after, and
        /// calling it `.v4.bak` when the contents are still v4 would make the suffix lie. The shell
        /// falls back to the current version in that case, which is the honest description.
        public let migratedFromVersion: Int?

        public init(migrated: Int, passedThrough: Int, skipped: Int, outOfOrder: Int,
                    resetsRepaired: Int = 0, severitiesRecomputed: Int = 0,
                    migratedFromVersion: Int? = nil) {
            self.migrated = migrated
            self.passedThrough = passedThrough
            self.skipped = skipped
            self.outOfOrder = outOfOrder
            self.resetsRepaired = resetsRepaired
            self.severitiesRecomputed = severitiesRecomputed
            self.migratedFromVersion = migratedFromVersion
        }

        /// Whether the pass changed anything — `false` means the file is already current and the
        /// caller can skip the rewrite (and the backup) entirely.
        ///
        /// Keyed on `migrated`, which counts every line the pass rewrote **for any reason**: a stale
        /// format, a stale colour model, or both. A future pass that only re-judges colours must keep
        /// incrementing it, or the shell would compute a new file and then silently decline to write
        /// it.
        public var changedAnything: Bool { migrated > 0 }

        /// A `.public`-safe one-liner for the migration log.
        public var logMessage: String {
            var out = "journal migrated: \(migrated) rewritten, \(passedThrough) unchanged"
            if resetsRepaired > 0 { out += ", \(resetsRepaired) weekly resets repaired" }
            if severitiesRecomputed > 0 { out += ", \(severitiesRecomputed) severities recomputed" }
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
        var severitiesRecomputed = 0
        var out: [String] = []
        // The oldest generation this pass had to rewrite — what the file *was*, which is what its
        // backup should be named after (#401).
        var lowestVersion: Int?
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

            // Two independent reasons to rewrite, either sufficient: the line's *format* is behind, or
            // its *colour model* is (#426). The second can be true on its own — a v4 line judged by a
            // superseded set of thresholds — which is precisely what `sevV` exists to make askable.
            let formatIsStale = sample.v < UsageSample.currentVersion
            let coloursAreStale = sample.sevV < UsageSample.currentColorVersion
            guard formatIsStale || coloursAreStale else {
                out.append(line)                 // already current on both axes
                passedThrough += 1
                continue
            }
            // Only a stale *format* names a backup: a colour-only pass leaves the file at its current
            // version, and labelling its backup `.v4.bak` would describe contents that are still v4.
            if formatIsStale { lowestVersion = min(lowestVersion ?? sample.v, sample.v) }

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

            // Repair a weekly reset that was written as a `now + 7d` estimate (ADR-0107). Those lines
            // are identifiable by their signature and recoverable from the anchor that preceded them;
            // `timePct` is recomputed with them, because it is derived from the date and was pinned
            // to 0 for the whole blackout.
            let repaired = repairWeeklyReset(sample.d7, at: at, anchor: weeklyAnchor)
            if repaired.source == .reconstructed { resetsRepaired += 1 }
            if !repaired.wasEstimated, let real = ResetClock.parse(sample.d7.reset), !goesBackwards {
                weeklyAnchor = real          // a genuine server date: the anchor for what follows
            }

            // The seven-day window, rebuilt first: everything below needs its final values. `util` and
            // `reset`/`timePct` are settled here, and only then is the colour judged — the v2 → v3 pass
            // rewrote the date and kept the old `sev`, which left blackout lines carrying a verdict
            // reached against a `timePct` that had since been corrected.
            let d7Util = weekly.effective
            let d7Sev = recomputedSeverity(
                util: d7Util, timePct: repaired.timePct, reset: repaired.reset,
                at: at, window: .sevenDay,
                // The 7-day bar never gates on itself.
                blueAllowed: true)
            // The weekly gate for the 5-hour bar, from this same line's final weekly values — the one
            // input a window cannot supply for itself. Closed by default: without a usable date there
            // is no trustworthy weekly clock, and the advice is withheld rather than guessed
            // (`PacingModel.weeklyHasHeadroom`).
            let weeklyHeadroom = ResetClock.parse(repaired.reset) == nil ? false
                : PacingModel.weeklyHasHeadroom(weeklyTimeFraction: repaired.timePct,
                                                weeklyUsageFraction: min(1, max(0, d7Util / 100)))

            let d7 = WindowSample(
                util: d7Util, raw: weekly.raw,
                utilSrc: weekly.source.rawValue, resetSrc: repaired.source.rawValue,
                n: weekly.ratio,
                reset: repaired.reset, timePct: repaired.timePct,
                sev: d7Sev, sevRaw: sample.d7.sev,
                windowSeconds: LimitWindow.sevenDay.durationSeconds)
            let h5 = recoloured(sample.h5, window: .fiveHour, at: at, blueAllowed: weeklyHeadroom)
            // Per-model windows never take the weekly gate — they are slices of that same week
            // (reason 2 on `BarLayout.blueAllowed`). This is where the bulk of the v4 changes land.
            let opus = sample.opus.map { recoloured($0, window: .sevenDay, at: at, blueAllowed: false) }
            let sonnet = sample.sonnet.map { recoloured($0, window: .sevenDay, at: at, blueAllowed: false) }
            let scoped = sample.scoped.map { recoloured($0, at: at) }

            severitiesRecomputed += [d7.sevRaw, h5.sevRaw, opus?.sevRaw, sonnet?.sevRaw]
                .compactMap { $0 }.count
                + scoped.filter { $0.sevRaw != nil }.count

            let rewritten = UsageSample(
                v: UsageSample.currentVersion,
                sevV: UsageSample.currentColorVersion,
                t: sample.t, ms: sample.ms, plan: sample.plan, tier: sample.tier,
                h5: h5,
                d7: d7,
                opus: opus, sonnet: sonnet, scoped: scoped,
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
                        skipped: skipped, outOfOrder: outOfOrder, resetsRepaired: resetsRepaired,
                        severitiesRecomputed: severitiesRecomputed,
                        migratedFromVersion: lowestVersion))
    }

    // MARK: - Severity recomputation (#426)

    /// Re-judge one window's colour with the **current** model, from the values the line carries.
    ///
    /// Mirrors ``JournalRecord`` 's live `window(...)` factory branch for branch, including the idle
    /// one: when the reset does not parse there is no pacing geometry to colour, and the verdict falls
    /// back to exhausted-or-green from utilisation alone. That branch is not an edge case in the
    /// archive — 1 551 of 5 789 five-hour windows on the maintainer's journal are idle — so a pass that
    /// skipped it, or pushed it through `barLayout` anyway, would corrupt more lines than it fixed.
    ///
    /// - Parameter at: the line's own timestamp. `nil` (unparseable) leaves the window uncoloured by
    ///   geometry for the same reason a missing reset does: `remainingSeconds` cannot be derived.
    private static func recomputedSeverity(
        util: Double, timePct: Double, reset: String, at: Date?,
        window: LimitWindow, blueAllowed: Bool
    ) -> PacingBucket {
        guard let at, let resetsAt = ResetClock.parse(reset) else {
            return util >= 100 ? .red : .green
        }
        // Built from the stored fields rather than re-derived: `timePct` is what the app acted on, and
        // recomputing it from the dates here could disagree with it in the last decimal.
        let layout = BarLayout(
            usageFraction: min(1, max(0, util / 100)),
            timeFraction: timePct,
            pacing: timePct >= min(1, max(0, util / 100)) ? .onPaceOrBehind : .ahead,
            remainingSeconds: resetsAt.timeIntervalSince(at),
            windowDurationSeconds: window.durationSeconds,
            blueAllowed: blueAllowed)
        return PacingBucket.of(layout)
    }

    /// A window sample with its colour re-judged and the original kept as `sevRaw` where it moved.
    private static func recoloured(
        _ w: WindowSample, window: LimitWindow, at: Date?, blueAllowed: Bool
    ) -> WindowSample {
        let sev = recomputedSeverity(util: w.util, timePct: w.timePct, reset: w.reset,
                                     at: at, window: window, blueAllowed: blueAllowed)
        return WindowSample(
            util: w.util, raw: w.raw, utilSrc: w.utilSrc, resetSrc: w.resetSrc, n: w.n,
            reset: w.reset, timePct: w.timePct, sev: sev,
            // The verdict the poll wrote. Where a line had already been migrated once, that is its
            // *current* `sev`, not the `sevRaw` it happens to carry — the marker always names the value
            // being replaced, so a second pass never overwrites the original with an intermediate one.
            sevRaw: w.sevRaw ?? w.sev,
            windowSeconds: window.durationSeconds)
    }

    /// The scoped counterpart of ``recoloured(_:window:at:blueAllowed:)``. Always `blueAllowed: false`:
    /// a scoped limit is part of the weekly window blue talks about.
    private static func recoloured(_ s: ScopedSample, at: Date?) -> ScopedSample {
        let sev = recomputedSeverity(util: s.pct, timePct: s.timePct, reset: s.reset,
                                     at: at, window: .sevenDay, blueAllowed: false)
        return ScopedSample(name: s.name, pct: s.pct, reset: s.reset, timePct: s.timePct,
                            sev: sev, sevRaw: s.sevRaw ?? s.sev)
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
