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
/// ## Why `status` lines are rewritten too (#456)
///
/// They were pass-through until a second status provider became possible (#454). A `status` line
/// records one page's components and one derived `worst`, and nothing in it said *whose* page — with
/// one provider the answer was always Claude, so the absence cost nothing. It becomes ambiguous
/// retroactively the moment a second page writes the same `kind`, and "absent means Claude" is exactly
/// the downstream branch the first section of this docblock argues against. So the provider is
/// backfilled onto every archived line, under a `v` counter of the status shape's own.
///
/// The pass is a **relabelling, not a recomputation**: `t`, `svc` and `worst` are carried across
/// verbatim. Unlike `util` (replayable through the algorithm that should have produced it) or `sev`
/// (re-judgeable under the current model), nothing about a historical status poll can be recomputed —
/// its inputs were the page's response at that instant, which is gone. The provider is the one fact
/// that is knowable in retrospect, precisely because there was only ever one it could have been.
///
/// ## What the migration must survive
///
/// - **Lines that are not usage or status samples** (`error`, `resume`) pass through verbatim.
///   `status` lines did too until #456; now they are rewritten when their format is behind, and pass
///   through untouched once current.
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
        /// `status` lines rewritten to carry their provider explicitly (#456).
        ///
        /// Its **own** counter rather than a share of ``migrated``, and the reason is the same one that
        /// gave `status` a `v` of its own: the two count different kinds. ``migrated`` is read as
        /// "usage samples reshaped" by every caller and by ``migratedFromVersion``, which names the
        /// backup after a *usage* generation; folding status lines into it would make a file whose only
        /// change was a relabelling claim its usage history had been rewritten.
        public let statusTagged: Int
        /// `error` lines folded into runs — the number of collapsed lines **written**.
        public let errorsCollapsed: Int
        /// Attempts folded away (`sum(n) - lines written`) — how much the file shrank.
        public let errorLinesRemoved: Int
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
                    statusTagged: Int = 0,
                    errorsCollapsed: Int = 0, errorLinesRemoved: Int = 0,
                    migratedFromVersion: Int? = nil) {
            self.migrated = migrated
            self.passedThrough = passedThrough
            self.skipped = skipped
            self.outOfOrder = outOfOrder
            self.resetsRepaired = resetsRepaired
            self.severitiesRecomputed = severitiesRecomputed
            self.statusTagged = statusTagged
            self.errorsCollapsed = errorsCollapsed
            self.errorLinesRemoved = errorLinesRemoved
            self.migratedFromVersion = migratedFromVersion
        }

        /// Whether the pass changed anything — `false` means the file is already current and the
        /// caller can skip the rewrite (and the backup) entirely.
        ///
        /// Keyed on `migrated` **or** `statusTagged` — every counter that corresponds to a rewritten
        /// line. `migrated` counts usage samples rewritten for any reason (a stale format, a stale
        /// colour model, or both); `statusTagged` counts status lines relabelled with their provider
        /// (#456).
        ///
        /// The `||` is load-bearing rather than defensive. An August journal can hold thousands of
        /// status lines and not a single stale usage line, and while this read `migrated > 0` such a
        /// file computed a correct rewrite and was then silently declined by the shell — the pass would
        /// have reported success and changed nothing on disk. **Any future counter that marks a
        /// rewritten line must be added here too**, or it will fail the same way.
        public var changedAnything: Bool { migrated > 0 || statusTagged > 0 || errorsCollapsed > 0 }

        /// A `.public`-safe one-liner for the migration log.
        public var logMessage: String {
            var out = "journal migrated: \(migrated) rewritten, \(passedThrough) unchanged"
            if resetsRepaired > 0 { out += ", \(resetsRepaired) weekly resets repaired" }
            if severitiesRecomputed > 0 { out += ", \(severitiesRecomputed) severities recomputed" }
            if statusTagged > 0 { out += ", \(statusTagged) status lines tagged" }
            if errorsCollapsed > 0 {
                out += ", \(errorsCollapsed) error runs collapsed (\(errorLinesRemoved) lines folded)"
            }
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
        var severitiesRecomputed = 0, statusTagged = 0
        var errorsCollapsed = 0, errorLinesRemoved = 0
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

        // The error run being accumulated. Adjacency in the file is the grouping key, not a time
        // window: real journals hold genuinely out-of-order timestamps (two processes under `flock`),
        // and a window would behave erratically across those inversions.
        var openRun: ErrorRun?
        // The original bytes of a run of one, so a line with nothing to collapse is passed through
        // untouched rather than re-encoded: a pass that rewrites what it cannot improve makes every
        // journal a changed file and every launch a rewrite.
        var openRunLine: String?
        // Close the run and emit its line. Must be called at the top of **every** branch that appends
        // something else, and once after the loop — a missed call silently drops attempts.
        func flushRun() {
            guard let run = openRun else { return }
            openRun = nil
            defer { openRunLine = nil }
            guard run.count > 1 else {
                if let line = openRunLine { out.append(line); passedThrough += 1 }
                return
            }
            guard let sample = ErrorRunCollapse.close(run),
                  let encoded = try? encoder.encode(JournalRecord.error(sample)),
                  let text = String(data: encoded, encoding: .utf8) else {
                if let line = openRunLine { out.append(line); skipped += 1 }
                return
            }
            out.append(text)
            errorsCollapsed += 1
            errorLinesRemoved += run.count - 1
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushRun(); out.append(line); continue }

            let parsed = trimmed.data(using: .utf8).flatMap {
                try? decoder.decode(JournalRecord.self, from: $0)
            }

            // `error` lines fold into runs: consecutive identical failures say one thing, and writing
            // each attempt made 98% of a real journal a single Keychain outage repeating (ADR-0123).
            if case let .error(sample) = parsed {
                guard let at = ResetClock.parse(sample.t) else {
                    flushRun()                       // an undatable line cannot join a run
                    out.append(line)
                    passedThrough += 1
                    continue
                }
                // An already-collapsed line is finished work: pass its bytes through and let it end
                // whatever run preceded it. Re-encoding it would make every launch rewrite the file.
                guard sample.n == nil else {
                    flushRun()
                    out.append(line)
                    passedThrough += 1
                    continue
                }
                switch ErrorRunCollapse.admit(openRun, sample: sample, at: at) {
                case let .extend(run):
                    openRun = run
                    if run.count == 1 { openRunLine = line }
                case let .flush(closed, next):
                    openRun = closed
                    flushRun()
                    openRun = next
                    openRunLine = next.count == 1 ? line : nil
                }
                continue
            }

            // `status` lines are rewritten in place when their format is behind (#456) — a relabelling,
            // not a recomputation, so it is handled here rather than in the usage pipeline below, which
            // would have nothing to offer it.
            if case let .status(sample) = parsed {
                flushRun()
                guard sample.v < StatusSample.currentVersion else {
                    out.append(line)                 // already tagged
                    passedThrough += 1
                    continue
                }
                // Backfilled, not defaulted. A v1 status line predates the second provider entirely, so
                // Claude is the only page it can have come from — the fact is recoverable *because* of
                // the very ambiguity that made the tag necessary. `t`, `svc` and `worst` carry across
                // untouched: their inputs are gone and nothing about them is re-derivable.
                let tagged = StatusSample(
                    v: StatusSample.currentVersion,
                    t: sample.t,
                    provider: ProviderID.claude.rawValue,
                    svc: sample.svc,
                    worst: sample.worst)
                guard let encoded = try? encoder.encode(JournalRecord.status(tagged)),
                      let text = String(data: encoded, encoding: .utf8) else {
                    out.append(line)                 // encoding failed: never lose the original
                    skipped += 1
                    continue
                }
                out.append(text)
                statusTagged += 1
                continue
            }

            guard case let .usage(sample) = parsed else {
                // Not a usage or status line, or not parseable at all: keep the original bytes. A file
                // that cannot be fully understood is still a file worth preserving exactly.
                flushRun()
                out.append(line)
                if parsed == nil { skipped += 1 } else { passedThrough += 1 }
                continue
            }

            flushRun()   // a usage line ends any run: the failure stopped when this poll succeeded

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
        // A run still open at end of input: without this the file's final storm vanishes.
        flushRun()

        return (out.joined(separator: "\n"), interpolator,
                Outcome(migrated: migrated, passedThrough: passedThrough,
                        skipped: skipped, outOfOrder: outOfOrder, resetsRepaired: resetsRepaired,
                        severitiesRecomputed: severitiesRecomputed,
                        statusTagged: statusTagged,
                        errorsCollapsed: errorsCollapsed, errorLinesRemoved: errorLinesRemoved,
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
