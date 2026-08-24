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
/// ## Why `usage`, `error` and `resume` carry a provider too (#502)
///
/// Same argument as `status`, one ticket later and on the three kinds a second **usage** provider
/// makes ambiguous. Two facts follow from it that a reader of the branches below would otherwise
/// find surprising:
///
/// - **A stale `error` line must lose its byte-passthrough.** The collapse path deliberately reuses
///   the original bytes for a run of one, so a file with nothing to fold is not rewritten. Left
///   alone, an untagged run-of-one would stay untagged forever, so a line behind
///   ``ErrorSample/currentVersion`` drops `openRunLine` and is re-encoded through
///   ``ErrorRunCollapse/close(_:)``.
/// - **`provider` is part of a run's identity**, so two providers failing identically never fold
///   into one line carrying one of their names — the very merge this tag exists to prevent, one
///   layer down.
///
/// ## Why the windows move into an array, and the old keys go (#508)
///
/// `h5`/`d7` were fixed keys, so a provider reporting one window had to invent the other — a drawn
/// bar for a limit the server does not report, under a fabricated reset. The v6 pass moves each
/// window into `windows[]` stamped with its own `secs`, which is what identifies it: Codex names a
/// window's duration and nothing else, and it left its weekly window in the slot called `primary`
/// while its five-hour limit was absent, so position names nothing.
///
/// **The old keys are removed rather than written beside the array.** Duplicated fields in an
/// append-only file are permanent, and a reader that accepts either spelling is a branch every
/// consumer carries forever — the argument the first section of this docblock makes.
///
/// The move is a **reshaping**, not a recomputation: every window keeps its `util`, its `sevRaw`
/// history, and its reconstruction state (`utilSrc`/`resetSrc`/`n`). `sevV` does not move, because
/// the colour model has not.
///
/// ## What the migration must survive
///
/// - **Every kind is rewritten while its own `v` is behind, and passes through untouched once
///   current.** The four counters are independent, so a file can be entirely current on one kind and
///   entirely stale on another.
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
        /// Windows, not lines: one sample holds several of them, and a line where only the scoped row
        /// moved is a different event from one where both limit windows did. Distinct from
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
        /// `error` lines rewritten to carry their ``ErrorSample/provider``.
        ///
        /// Its own counter beside ``errorsCollapsed``, which counts a different act: a stale line
        /// with nothing adjacent to fold into is tagged without collapsing anything.
        public let errorTagged: Int
        /// `resume` markers rewritten to carry their ``ResumeMarker/provider``.
        public let resumeTagged: Int
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
                    errorTagged: Int = 0, resumeTagged: Int = 0,
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
            self.errorTagged = errorTagged
            self.resumeTagged = resumeTagged
            self.migratedFromVersion = migratedFromVersion
        }

        /// Whether the pass changed anything — `false` means the file is already current and the
        /// caller can skip the rewrite (and the backup) entirely.
        ///
        /// Keyed on **every** counter that corresponds to a rewritten line. `migrated` counts usage
        /// samples rewritten for any reason (a stale format, a stale colour model, or both) — which
        /// is why moving the windows into an array added no counter of its own: that is a format
        /// bump, and a second counter would describe the same rewrite twice;
        /// `statusTagged`, `errorTagged` and `resumeTagged` count lines of the other three kinds
        /// relabelled with their provider; `errorsCollapsed` counts runs folded.
        ///
        /// The `||` chain is load-bearing rather than defensive. A journal whose only stale lines are
        /// `resume` markers is ordinary — a laptop that sleeps a lot with usage polling off — and a
        /// counter missing here means the pass computes a correct rewrite, the shell silently declines
        /// to write it, and the log reports success. **Any future counter that marks a rewritten line
        /// must be added here too**, or it will fail the same way.
        public var changedAnything: Bool {
            migrated > 0 || statusTagged > 0 || errorsCollapsed > 0
                || errorTagged > 0 || resumeTagged > 0
        }

        /// A `.public`-safe one-liner for the migration log.
        public var logMessage: String {
            var out = "journal migrated: \(migrated) rewritten, \(passedThrough) unchanged"
            if resetsRepaired > 0 { out += ", \(resetsRepaired) weekly resets repaired" }
            if severitiesRecomputed > 0 { out += ", \(severitiesRecomputed) severities recomputed" }
            if statusTagged > 0 { out += ", \(statusTagged) status lines tagged" }
            if errorsCollapsed > 0 {
                out += ", \(errorsCollapsed) error runs collapsed (\(errorLinesRemoved) lines folded)"
            }
            if errorTagged > 0 { out += ", \(errorTagged) error lines tagged" }
            if resumeTagged > 0 { out += ", \(resumeTagged) resume markers tagged" }
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
        var errorTagged = 0, resumeTagged = 0
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
        // Whether the open run's first line was behind ``ErrorSample/currentVersion``. It overrides the
        // passthrough above exactly once: without it a stale run of one keeps its untagged bytes and
        // stays untagged forever, since nothing else ever revisits it.
        var openRunStale = false
        // Close the run and emit its line. Must be called at the top of **every** branch that appends
        // something else, and once after the loop — a missed call silently drops attempts.
        func flushRun() {
            guard let run = openRun else { return }
            openRun = nil
            let wasStale = openRunStale
            defer { openRunLine = nil; openRunStale = false }
            guard run.count > 1 || wasStale else {
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
            // A run of one only reaches here because its format was behind: it is a relabelling, and
            // counting it as a collapse would claim attempts were folded that never existed.
            if run.count > 1 {
                errorsCollapsed += 1
                errorLinesRemoved += run.count - 1
            } else {
                errorTagged += 1
            }
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
                let stale = sample.v < ErrorSample.currentVersion
                // An already-collapsed line is finished work: pass its bytes through and let it end
                // whatever run preceded it. Re-encoding it would make every launch rewrite the file —
                // unless its format is behind, in which case it is re-encoded once for the tag.
                guard sample.n == nil else {
                    flushRun()
                    guard stale, let tagged = try? encoder.encode(JournalRecord.error(retagged(sample))),
                          let text = String(data: tagged, encoding: .utf8) else {
                        out.append(line)
                        passedThrough += 1
                        continue
                    }
                    out.append(text)
                    errorTagged += 1
                    continue
                }
                switch ErrorRunCollapse.admit(openRun, sample: sample, at: at) {
                case let .extend(run):
                    openRun = run
                    if run.count == 1 { openRunLine = line; openRunStale = stale }
                case let .flush(closed, next):
                    openRun = closed
                    flushRun()
                    openRun = next
                    openRunLine = next.count == 1 ? line : nil
                    openRunStale = next.count == 1 && stale
                }
                continue
            }

            // `resume` markers get the same relabelling as `status`: a marker predates the second usage
            // provider entirely, so Claude is the only clock its gap can have come from.
            if case let .resume(marker) = parsed {
                flushRun()
                guard marker.v < ResumeMarker.currentVersion else {
                    out.append(line)                 // already tagged
                    passedThrough += 1
                    continue
                }
                let tagged = ResumeMarker(
                    t: marker.t, gap: marker.gap,
                    v: ResumeMarker.currentVersion,
                    provider: ProviderID.claude.rawValue)
                guard let encoded = try? encoder.encode(JournalRecord.resume(tagged)),
                      let text = String(data: encoded, encoding: .utf8) else {
                    out.append(line)                 // encoding failed: never lose the original
                    skipped += 1
                    continue
                }
                out.append(text)
                resumeTagged += 1
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

            // The seven-day window is the only one the reconstruction and the blackout repair have
            // anything to say about, and it is the one input the five-hour window cannot supply for
            // itself — so it is settled first, and the rest of the array follows.
            //
            // Optional since v6: a provider may report no weekly window at all, and every step below
            // is then skipped rather than run against a fabricated one.
            if let at, !goesBackwards {
                // Advanced on every line that moves time forward, weekly window or not: skipping it
                // would leave the next line with one reading as out of order.
                interpolator = interpolator.advanced(with: snapshot(from: sample), now: at)
                lastAccepted = at
            }

            var d7: WindowSample?
            if let original = sample.d7 {
                let weekly: WeeklyUtilization = at != nil && !goesBackwards
                    ? interpolator.value(forRaw: original.raw)
                    : .passthrough(original.raw)

                // Repair a weekly reset that was written as a `now + 7d` estimate (ADR-0107). Those
                // lines are identifiable by their signature and recoverable from the anchor that
                // preceded them; `timePct` is recomputed with them, because it is derived from the
                // date and was pinned to 0 for the whole blackout.
                let repaired = repairWeeklyReset(original, at: at, anchor: weeklyAnchor)
                if repaired.source == .reconstructed { resetsRepaired += 1 }
                if !repaired.wasEstimated, let real = ResetClock.parse(original.reset), !goesBackwards {
                    weeklyAnchor = real      // a genuine server date: the anchor for what follows
                }

                // `util` and `reset`/`timePct` are settled before the colour is judged — the v2 → v3
                // pass rewrote the date and kept the old `sev`, which left blackout lines carrying a
                // verdict reached against a `timePct` that had since been corrected.
                d7 = WindowSample(
                    util: weekly.effective, raw: weekly.raw,
                    utilSrc: weekly.source.rawValue, resetSrc: repaired.source.rawValue,
                    n: weekly.ratio,
                    reset: repaired.reset, timePct: repaired.timePct,
                    sev: recomputedSeverity(
                        util: weekly.effective, timePct: repaired.timePct, reset: repaired.reset,
                        at: at, windowSeconds: original.secs,
                        // The 7-day bar never gates on itself.
                        blueAllowed: true),
                    // The verdict the poll wrote, which on a line migrated once already is the
                    // `sevRaw` it carries and not its current `sev` — the marker always names the
                    // value being replaced. Taking `sev` here instead overwrites the original with
                    // an intermediate one, and where the two now agree it drops the marker
                    // altogether: 102 of them on the maintainer's August journal. Same rule, and the
                    // same reason, as `recoloured(_:at:blueAllowed:)`.
                    sevRaw: original.sevRaw ?? original.sev,
                    windowSeconds: original.secs)
            }
            // The weekly gate for the 5-hour bar, from this same line's final weekly values. Closed by
            // default: without a weekly window, or without a usable date on it, there is no trustworthy
            // weekly clock, and the advice is withheld rather than guessed
            // (`PacingModel.weeklyHasHeadroom`).
            let weeklyHeadroom = d7.map { w in
                ResetClock.parse(w.reset) == nil ? false
                    : PacingModel.weeklyHasHeadroom(
                        weeklyTimeFraction: w.timePct,
                        weeklyUsageFraction: min(1, max(0, w.util / 100)))
            } ?? false

            // Every other window keeps its place in the array and is re-judged under its own length.
            // Only the five-hour one takes the weekly gate: it is the bar that asks the week whether
            // there is room to push.
            let windows = sample.windows.map { w -> WindowSample in
                if w.secs == LimitWindow.sevenDay.durationSeconds, let d7 { return d7 }
                return recoloured(
                    w, at: at,
                    blueAllowed: w.secs == LimitWindow.fiveHour.durationSeconds
                        ? weeklyHeadroom
                        // A window that is neither of Claude's two gates on nothing: Codex's windows
                        // are not slices of one another, so there is no cross-window advice to fund.
                        : true)
            }
            // Per-model windows never take the weekly gate — they are slices of that same week
            // (reason 2 on `BarLayout.blueAllowed`). This is where the bulk of the v4 changes land.
            let opus = sample.opus.map { recoloured($0, at: at, blueAllowed: false) }
            let sonnet = sample.sonnet.map { recoloured($0, at: at, blueAllowed: false) }
            let scoped = sample.scoped.map { recoloured($0, at: at) }

            severitiesRecomputed += windows.compactMap { $0.sevRaw }.count
                + [opus?.sevRaw, sonnet?.sevRaw].compactMap { $0 }.count
                + scoped.filter { $0.sevRaw != nil }.count

            let rewritten = UsageSample(
                v: UsageSample.currentVersion,
                sevV: UsageSample.currentColorVersion,
                // Claude on a v4 line for the same reason the status backfill is knowable: it predates
                // the second usage provider. A v5 line already carries its own and keeps it.
                provider: sample.provider,
                t: sample.t, ms: sample.ms, plan: sample.plan, tier: sample.tier,
                windows: windows,
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
                        errorTagged: errorTagged, resumeTagged: resumeTagged,
                        migratedFromVersion: lowestVersion))
    }

    /// An already-collapsed `error` line at the current format, with everything else carried across.
    /// Its `n`/`tEnd` are finished work — re-deriving them would need the attempts, which are gone.
    private static func retagged(_ sample: ErrorSample) -> ErrorSample {
        ErrorSample(
            t: sample.t, code: sample.code, reason: sample.reason, detail: sample.detail,
            retryAfter: sample.retryAfter, ms: sample.ms, n: sample.n, tEnd: sample.tEnd,
            v: ErrorSample.currentVersion, provider: sample.provider)
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
        windowSeconds: Int, blueAllowed: Bool
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
            windowDurationSeconds: windowSeconds,
            blueAllowed: blueAllowed)
        return PacingBucket.of(layout)
    }

    /// A window sample with its colour re-judged and the original kept as `sevRaw` where it moved.
    ///
    /// The length comes from the sample's own ``WindowSample/secs`` rather than a caller-supplied
    /// case: a window in the array names its own duration, and a `LimitWindow` parameter could only
    /// describe the two lengths Claude reports.
    private static func recoloured(
        _ w: WindowSample, at: Date?, blueAllowed: Bool
    ) -> WindowSample {
        let sev = recomputedSeverity(util: w.util, timePct: w.timePct, reset: w.reset,
                                     at: at, windowSeconds: w.secs, blueAllowed: blueAllowed)
        return WindowSample(
            util: w.util, raw: w.raw, utilSrc: w.utilSrc, resetSrc: w.resetSrc, n: w.n,
            reset: w.reset, timePct: w.timePct, sev: sev,
            // The verdict the poll wrote. Where a line had already been migrated once, that is its
            // *current* `sev`, not the `sevRaw` it happens to carry — the marker always names the value
            // being replaced, so a second pass never overwrites the original with an intermediate one.
            sevRaw: w.sevRaw ?? w.sev,
            windowSeconds: w.secs)
    }

    /// The scoped counterpart of ``recoloured(_:at:blueAllowed:)``. Always `blueAllowed: false`:
    /// a scoped limit is part of the weekly window blue talks about.
    private static func recoloured(_ s: ScopedSample, at: Date?) -> ScopedSample {
        let sev = recomputedSeverity(
            util: s.pct, timePct: s.timePct, reset: s.reset, at: at,
            windowSeconds: LimitWindow.sevenDay.durationSeconds, blueAllowed: false)
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
    /// A line with neither window contributes an idle snapshot — the estimator learns nothing from
    /// it, which is what a provider Claude's five-hour counter does not describe should teach it.
    private static func snapshot(from sample: UsageSample) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: sample.h5?.raw ?? 0,
                                  resetsAt: sample.h5?.reset ?? ""),
            sevenDay: UsageWindow(utilization: sample.d7?.raw ?? 0,
                                  resetsAt: sample.d7?.reset ?? ""))
    }
}
