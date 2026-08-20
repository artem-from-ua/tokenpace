import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

/// A v1 usage line: no `v`, `util` is the API's value, `gap` is a stored field.
private func v1Line(t: String, h5: Double, d7: Double, gap: Double = 0) -> String {
    """
    {"kind":"usage","t":"\(t)","h5":{"util":\(h5),"reset":"","timePct":0.5,"gap":\(gap),"sev":"green"},\
    "d7":{"util":\(d7),"reset":"","timePct":0.5,"gap":\(gap),"sev":"green"},\
    "scoped":[],"sessionIdle":false,"blocked":false,\
    "credits":{"active":false,"showIcon":false,"onCredits":false},"brokenReset":false}
    """
}

private func decodeUsage(_ line: String) -> UsageSample? {
    guard let data = line.data(using: .utf8),
          let record = try? JSONDecoder().decode(JournalRecord.self, from: data),
          case let .usage(sample) = record else { return nil }
    return sample
}

private func iso(_ minutesFromNoon: Int) -> String {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    return ResetClock.isoString(from: base.addingTimeInterval(Double(minutesFromNoon) * 60))
}

// MARK: - Migration

@Suite("JournalMigration")
struct JournalMigrationTests {

    @Test func rewritesV1LinesAndStampsTheVersion() {
        let input = [
            v1Line(t: iso(0), h5: 10, d7: 50),
            v1Line(t: iso(3), h5: 20, d7: 50),
            v1Line(t: iso(6), h5: 30, d7: 51),
        ].joined(separator: "\n")

        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.migrated == 3)
        #expect(outcome.skipped == 0)

        let lines = out.split(separator: "\n").map(String.init)
        for line in lines {
            let sample = decodeUsage(line)
            #expect(sample?.v == UsageSample.currentVersion)
            #expect(sample?.d7.raw != nil)          // the API's number is preserved beside `util`
        }
        // `gap` is gone from the wire — it is derived now.
        #expect(!out.contains("\"gap\""))
    }

    @Test func recomputesUtilWithTheLiveAlgorithm() {
        // A bump at line 3 makes the anchor firm, so later lines carry a reconstructed value strictly
        // inside the bucket — exactly what the running app would have written.
        var lines: [String] = []
        for i in 0..<12 {
            lines.append(v1Line(t: iso(i * 3), h5: Double(i * 5), d7: i < 3 ? 50 : 51))
        }
        let (out, _, _) = JournalMigration.migrate(contents: lines.joined(separator: "\n"))
        let samples = out.split(separator: "\n").compactMap { decodeUsage(String($0)) }

        #expect(samples.count == 12)
        let last = samples[samples.count - 1]
        #expect(last.d7.raw == 51)                       // the API's value, untouched
        #expect(last.d7.util > 50.5)                     // reconstructed above the bucket floor
        #expect(last.d7.util <= 51.5)
        #expect(last.d7.utilSrc != nil)                  // and it says how it got there
    }

    @Test func passesThroughOtherRecordKinds() {
        let input = [
            #"{"kind":"status","t":"2026-08-03T12:00:00Z","svc":[],"worst":"operational"}"#,
            #"{"kind":"resume","t":"2026-08-03T12:05:00Z","gap":900}"#,
            #"{"kind":"error","t":"2026-08-03T12:10:00Z","code":429,"reason":"clientProblem"}"#,
        ].joined(separator: "\n")

        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.migrated == 0)
        #expect(outcome.passedThrough == 3)
        #expect(out == input)                            // byte-identical
    }

    @Test func preservesUnparseableLinesVerbatim() {
        // The classic hazard: a torn last line from a crash mid-append. It must survive untouched.
        let torn = #"{"kind":"usage","t":"2026-08-03T12:00:00Z","h5":{"util":1"#
        let input = [v1Line(t: iso(0), h5: 10, d7: 50), torn].joined(separator: "\n")

        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.skipped == 1)
        #expect(out.hasSuffix(torn))
    }

    @Test func alreadyCurrentLinesAreLeftAlone() {
        let current = UsageSample(
            t: iso(0),
            h5: WindowSample(util: 10, reset: "", timePct: 0.5, sev: .green),
            d7: WindowSample(util: 50.25, raw: 50, utilSrc: "interpolated", n: 9.8,
                             reset: "", timePct: 0.5, sev: .green),
            credits: CreditsFlags(active: false, showIcon: false, onCredits: false))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let line = String(data: try! encoder.encode(JournalRecord.usage(current)), encoding: .utf8)!

        let (out, _, outcome) = JournalMigration.migrate(contents: line)
        #expect(outcome.migrated == 0)
        #expect(outcome.passedThrough == 1)
        #expect(out == line)
        #expect(!outcome.changedAnything)                // so the caller can skip the swap entirely
    }

    @Test func anOutOfOrderLineDoesNotTeachTheEstimator() {
        // Found in a real journal: 11:03 sitting before 10:37. Fed to the interpolator in file order
        // it would look like the counters went backwards — a spend "drop" that never happened.
        let input = [
            v1Line(t: iso(0), h5: 10, d7: 50),
            v1Line(t: iso(30), h5: 40, d7: 50),      // 11:03
            v1Line(t: iso(4), h5: 20, d7: 50),       // 10:37 — arrives late, out of order
            v1Line(t: iso(33), h5: 45, d7: 50),
        ].joined(separator: "\n")

        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.outOfOrder == 1)
        #expect(outcome.migrated == 4)               // still rewritten, just not trusted as input

        let samples = out.split(separator: "\n").compactMap { decodeUsage(String($0)) }
        // Every line keeps its own raw value; nothing was reordered or dropped.
        #expect(samples.map(\.t) == [iso(0), iso(30), iso(4), iso(33)])
    }

    @Test func stateCarriesAcrossFiles() {
        // The journal is split by month. Starting each file cold would leave every line of the new
        // month on an inherited anchor for no reason.
        let january = (0..<12).map { v1Line(t: iso($0 * 3), h5: Double($0 * 5), d7: $0 < 3 ? 50 : 51) }
            .joined(separator: "\n")
        let (_, carried, _) = JournalMigration.migrate(contents: january)
        #expect(carried.ratio.sampleCount > 0, "the January pass learned nothing to carry")

        let february = v1Line(t: iso(100), h5: 5, d7: 52)
        let (out, _, _) = JournalMigration.migrate(contents: february, state: carried)
        let sample = decodeUsage(out)
        #expect(sample?.d7.n == carried.ratio.estimate.rounded(toPlaces: 2),
                "the carried exchange rate should be the one journalled")
    }

    @Test func aReleaseBuildDoesNotAdoptTheDevJournals() {
        // `usage-journal-` is also a prefix of `usage-journal-dev-…`, so a naive `hasPrefix` lets a
        // release run migrate files that are not its own. Caught before the first live migration.
        #expect(JournalMigration.belongsToBuild(fileName: "usage-journal-2026-08.jsonl", isRelease: true))
        #expect(!JournalMigration.belongsToBuild(fileName: "usage-journal-dev-2026-08.jsonl", isRelease: true))

        #expect(JournalMigration.belongsToBuild(fileName: "usage-journal-dev-2026-08.jsonl", isRelease: false))
        #expect(!JournalMigration.belongsToBuild(fileName: "usage-journal-2026-08.jsonl", isRelease: false))

        // Neither build touches the backups it just made, nor anything else in the directory.
        #expect(!JournalMigration.belongsToBuild(fileName: "usage-journal-2026-08.jsonl.v1.bak", isRelease: true))
        #expect(!JournalMigration.belongsToBuild(fileName: "status-payloads-2026-08.jsonl", isRelease: true))
        #expect(!JournalMigration.belongsToBuild(fileName: "usage-journal-2026-08.jsonl.migrating", isRelease: true))
    }

    @Test func anEmptyFileIsUnchanged() {
        let (out, _, outcome) = JournalMigration.migrate(contents: "")
        #expect(out == "")
        #expect(!outcome.changedAnything)
    }

    @Test func trailingNewlineSurvives() {
        // The journal is append-only and every line ends in "\n"; losing the trailing one would make
        // the next append land on the same line as the last record.
        let input = v1Line(t: iso(0), h5: 10, d7: 50) + "\n"
        let (out, _, _) = JournalMigration.migrate(contents: input)
        #expect(out.hasSuffix("\n"))
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}

// MARK: - Weekly reset repair (v2 → v3, ADR-0107)

/// The archived counterpart of the live fix: lines written during a weekly API blackout carry a
/// `now + 7d` estimate that crept forward every poll, with `timePct` pinned at 0 throughout. The
/// migration rolls them back onto the real grid and recomputes the fraction.
@Suite("JournalMigration — weekly reset repair")
struct WeeklyResetRepairTests {

    /// A blackout replayed from the maintainer's journal: the last real reset before it, and the
    /// first one the server sent after it ended.
    private static let realReset = "2026-08-18T07:00:00.306761+00:00"
    private static let truthAfter = "2026-08-25T07:00:00.058036+00:00"

    /// A v2 line. `reset` is written verbatim so a fixture can carry either a real microsecond
    /// instant or one of the old 10-minute estimates.
    private static func v2Line(t: String, reset: String, timePct: Double, d7: Double = 0) -> String {
        """
        {"kind":"usage","v":2,"t":"\(t)","h5":{"util":0,"raw":0,"reset":"","timePct":0,"sev":"green"},\
        "d7":{"util":\(d7),"raw":\(d7),"src":"interpolated","n":10,"reset":"\(reset)",\
        "timePct":\(timePct),"sev":"green"},\
        "scoped":[],"sessionIdle":false,"blocked":false,\
        "credits":{"active":false,"showIcon":false,"onCredits":false},"brokenReset":false}
        """
    }

    private static func at(_ offsetHours: Double) -> String {
        let anchor = ResetClock.parse(realReset)!
        return ResetClock.isoString(from: anchor.addingTimeInterval(offsetHours * 3600))
    }

    /// The whole point: an estimated reset preceded by a real one is rolled onto the true grid, and
    /// `timePct` stops being a flat zero.
    @Test func anEstimateAfterARealResetIsRepaired() throws {
        let input = [
            // The last healthy poll, six seconds before the reset.
            Self.v2Line(t: Self.at(-0.0017), reset: Self.realReset, timePct: 0.99999, d7: 94),
            // Then the blackout: 10-minute estimates, timePct pinned at zero.
            Self.v2Line(t: Self.at(0.5), reset: "2026-08-25T07:30:00Z", timePct: 0),
            Self.v2Line(t: Self.at(3.0), reset: "2026-08-25T10:00:00Z", timePct: 0),
        ].joined(separator: "\n")

        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.resetsRepaired == 2)

        let samples = out.split(separator: "\n").compactMap { decodeUsage(String($0)) }
        let truth = try #require(ResetClock.parse(Self.truthAfter))

        // Both repaired lines now name the instant the server itself reported, within a second.
        for sample in samples.dropFirst() {
            let repaired = try #require(ResetClock.parse(sample.d7.reset))
            #expect(abs(repaired.timeIntervalSince(truth)) < 1)
            #expect(sample.d7.resetSrc == "reconstructed")
            #expect(sample.d7.timePct > 0)          // no longer a flat zero
        }
        // And the elapsed fraction now advances between the two, as time actually did.
        #expect(samples[2].d7.timePct > samples[1].d7.timePct)
    }

    /// **The `resetGrace` regression, in the archive.** The first poll of a blackout lands in the
    /// same second as the reset, leaving the anchor a fraction of a second ahead. Without the
    /// tolerance the roll is skipped and the line reads as ~100 % elapsed — worse than the zero it
    /// replaced.
    @Test func theFirstLineOfABlackoutDoesNotLandAtFullElapsed() throws {
        let anchor = try #require(ResetClock.parse(Self.realReset))
        let input = [
            Self.v2Line(t: Self.at(-0.0017), reset: Self.realReset, timePct: 0.99999, d7: 94),
            // Polled at 07:00:00.000 — 0.31 s *before* the anchor instant.
            Self.v2Line(t: ResetClock.isoString(from: anchor.addingTimeInterval(-0.306761)),
                        reset: "2026-08-25T07:10:00Z", timePct: 0),
        ].joined(separator: "\n")

        let samples = JournalMigration.migrate(contents: input).contents
            .split(separator: "\n").compactMap { decodeUsage(String($0)) }
        #expect(samples[1].d7.timePct < 0.01)       // start of the window, not the end of it
    }

    /// A real (microsecond) reset is never mistaken for an estimate.
    @Test func realResetsAreLeftAlone() throws {
        let input = Self.v2Line(t: Self.at(-1), reset: Self.realReset, timePct: 0.9, d7: 94)
        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.resetsRepaired == 0)
        let sample = try #require(decodeUsage(out))
        #expect(sample.d7.reset == Self.realReset)
        #expect(sample.d7.resetSrc == "server")
    }

    /// With no anchor before it, the line is left exactly as it was: a repair needs something real to
    /// roll from, and a different wrong answer is not an improvement.
    @Test func anEstimateWithNoPrecedingAnchorIsKept() throws {
        let input = Self.v2Line(t: Self.at(0.5), reset: "2026-08-25T07:30:00Z", timePct: 0)
        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(outcome.resetsRepaired == 0)
        let sample = try #require(decodeUsage(out))
        #expect(sample.d7.reset == "2026-08-25T07:30:00Z")
        #expect(sample.d7.resetSrc == "unknown")
    }

    /// Running the migration twice must not change anything the second time — the pass is a one-off,
    /// and a v3 file has to be recognised as current.
    @Test func theMigrationIsIdempotent() {
        let input = [
            Self.v2Line(t: Self.at(-0.0017), reset: Self.realReset, timePct: 0.99999, d7: 94),
            Self.v2Line(t: Self.at(0.5), reset: "2026-08-25T07:30:00Z", timePct: 0),
        ].joined(separator: "\n")

        let first = JournalMigration.migrate(contents: input)
        let second = JournalMigration.migrate(contents: first.contents, state: first.state)
        #expect(second.outcome.migrated == 0)
        #expect(second.outcome.resetsRepaired == 0)
        #expect(second.contents == first.contents)
    }

    /// The v2 spelling still decodes after the rename, so a `.v2.bak` or a hand-copied line reports
    /// its source instead of reading as "nothing was reconstructed".
    @Test func theLegacySrcKeyStillDecodes() throws {
        let sample = try #require(decodeUsage(
            Self.v2Line(t: Self.at(-1), reset: Self.realReset, timePct: 0.9, d7: 94)))
        #expect(sample.d7.utilSrc == "interpolated")
    }
}

// MARK: - Which generation the backup is named after (#401)

/// The backup keeps the format version it **contains**, so every migration leaves its own — a file
/// taken v1 → v2 → v3 ends up with both `.v1.bak` and `.v2.bak`.
///
/// The bug this pins down: with a fixed `.v1.bak`, the second migration found that name already
/// taken, correctly refused to overwrite the older evidence, and deleted the v2 file instead. The
/// archive then jumped v1 → v3 with the middle generation gone — which is what happened on the
/// maintainer's live journal.
@Suite("JournalMigration — backup generation")
struct BackupGenerationTests {

    private static func at(_ minutes: Int) -> String {
        ResetClock.isoString(from: Date(timeIntervalSince1970: 1_800_000_000)
            .addingTimeInterval(Double(minutes) * 60))
    }

    /// A v1 file (no `v` key at all) reports generation 1.
    @Test func aV1FileReportsVersionOne() {
        let input = [v1Line(t: Self.at(0), h5: 10, d7: 50),
                     v1Line(t: Self.at(3), h5: 20, d7: 50)].joined(separator: "\n")
        let outcome = JournalMigration.migrate(contents: input).outcome
        #expect(outcome.migrated == 2)
        #expect(outcome.migratedFromVersion == 1)
    }

    /// A v2 file reports generation 2 — the case the live journal hit, and the one a fixed suffix
    /// mislabelled.
    @Test func aV2FileReportsVersionTwo() {
        let line = """
        {"kind":"usage","v":2,"t":"\(Self.at(0))",\
        "h5":{"util":10,"raw":10,"reset":"","timePct":0.5,"sev":"green"},\
        "d7":{"util":50,"raw":50,"src":"interpolated","n":10,"reset":"","timePct":0.5,"sev":"green"},\
        "scoped":[],"sessionIdle":false,"blocked":false,\
        "credits":{"active":false,"showIcon":false,"onCredits":false},"brokenReset":false}
        """
        let outcome = JournalMigration.migrate(contents: line).outcome
        #expect(outcome.migrated == 1)
        #expect(outcome.migratedFromVersion == 2)
    }

    /// A file spanning an upgrade holds several generations at once — the journal is append-only and
    /// outlives app versions. The backup must be named after the **oldest** thing in it, or the label
    /// claims the archive is more recent than it is.
    @Test func aMixedFileReportsTheOldestGeneration() {
        let v2 = """
        {"kind":"usage","v":2,"t":"\(Self.at(3))",\
        "h5":{"util":10,"raw":10,"reset":"","timePct":0.5,"sev":"green"},\
        "d7":{"util":50,"raw":50,"src":"interpolated","n":10,"reset":"","timePct":0.5,"sev":"green"},\
        "scoped":[],"sessionIdle":false,"blocked":false,\
        "credits":{"active":false,"showIcon":false,"onCredits":false},"brokenReset":false}
        """
        let input = [v1Line(t: Self.at(0), h5: 10, d7: 50), v2].joined(separator: "\n")
        let outcome = JournalMigration.migrate(contents: input).outcome
        #expect(outcome.migratedFromVersion == 1)      // not 2
    }

    /// Nothing rewritten → nothing to name a backup after, and `changedAnything` keeps the shell from
    /// writing one at all.
    @Test func anAlreadyCurrentFileReportsNoVersion() {
        let current = UsageSample(
            t: Self.at(0),
            h5: WindowSample(util: 10, reset: "", timePct: 0.5, sev: .green),
            d7: WindowSample(util: 50, raw: 50, utilSrc: "interpolated", n: 9.8,
                             reset: "", timePct: 0.5, sev: .green),
            credits: CreditsFlags(active: false, showIcon: false, onCredits: false))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let line = String(data: try! encoder.encode(JournalRecord.usage(current)), encoding: .utf8)!

        let outcome = JournalMigration.migrate(contents: line).outcome
        #expect(!outcome.changedAnything)
        #expect(outcome.migratedFromVersion == nil)
    }

    /// A backup must never be picked up as a journal to migrate — it is the evidence, not an input.
    /// Guarded by the `.jsonl` suffix check, which a `.bak` name fails.
    @Test func backupsAreNotMigrated() {
        for name in ["usage-journal-2026-08.jsonl.v1.bak", "usage-journal-2026-08.jsonl.v2.bak"] {
            #expect(!JournalMigration.belongsToBuild(fileName: name, isRelease: true))
            #expect(!JournalMigration.belongsToBuild(fileName: name, isRelease: false))
        }
        // The live file itself still is, in both build flavours.
        #expect(JournalMigration.belongsToBuild(fileName: "usage-journal-2026-08.jsonl", isRelease: true))
        #expect(JournalMigration.belongsToBuild(fileName: "usage-journal-dev-2026-08.jsonl", isRelease: false))
    }
}

// MARK: - Severity recomputation (v3 → v4, #426)

/// The archived counterpart of the model fix: every window's `sev` is re-judged by the current colour
/// model, the superseded verdict survives as `sevRaw` where the two differ, and `sevV` stamps which
/// model decided. Most of the real-world effect is per-model rows losing a blue they only ever had in
/// the file — the popup was already painting them green.
@Suite("JournalMigration — severity recomputation")
struct SeverityRecomputationTests {

    /// A v3 line, written verbatim so a fixture can carry verdicts the current model disagrees with.
    private static func v3Line(
        t: String, reset: String,
        h5: (util: Double, timePct: Double, sev: String),
        d7: (util: Double, timePct: Double, sev: String),
        scoped: (pct: Double, timePct: Double, sev: String)? = nil
    ) -> String {
        let scopedJSON = scoped.map {
            "{\"name\":\"Fable\",\"pct\":\($0.pct),\"reset\":\"\(reset)\","
                + "\"timePct\":\($0.timePct),\"sev\":\"\($0.sev)\"}"
        } ?? ""
        // The 5-hour window needs its **own** reset, placed to match its `timePct`: the recomputation
        // derives `remainingSeconds` from `reset − t`, and borrowing the weekly date would put the
        // window hours past its own length — landing every fixture in the 20-minute start override.
        let h5Reset = ResetClock.isoString(
            from: ResetClock.parse(t)!.addingTimeInterval(
                Double(LimitWindow.fiveHour.durationSeconds) * (1 - h5.timePct)))
        return """
        {"kind":"usage","v":3,"t":"\(t)",\
        "h5":{"util":\(h5.util),"raw":\(h5.util),"reset":"\(h5Reset)","timePct":\(h5.timePct),"sev":"\(h5.sev)"},\
        "d7":{"util":\(d7.util),"raw":\(d7.util),"utilSrc":"interpolated","resetSrc":"server","n":10,\
        "reset":"\(reset)","timePct":\(d7.timePct),"sev":"\(d7.sev)"},\
        "scoped":[\(scopedJSON)],"sessionIdle":false,"blocked":false,\
        "credits":{"active":false,"showIcon":false,"onCredits":false},"brokenReset":false}
        """
    }

    /// A real weekly reset (microsecond precision, so `repairWeeklyReset` leaves it alone) and a poll
    /// two days before it — clear of either 20-minute override on both scales.
    private static let reset = "2026-08-25T07:00:00.058036+00:00"
    private static var pollTime: String {
        ResetClock.isoString(from: ResetClock.parse(reset)!.addingTimeInterval(-2 * 24 * 3600))
    }

    private static func migrated(_ line: String) -> UsageSample? {
        decodeUsage(JournalMigration.migrate(contents: line).contents)
    }

    /// The headline case: a scoped row recorded blue becomes green, and keeps what it was.
    @Test func aScopedBlueBecomesGreenAndKeepsItsOriginal() throws {
        let line = Self.v3Line(
            t: Self.pollTime, reset: Self.reset,
            h5: (util: 20, timePct: 0.5, sev: "green"),
            d7: (util: 10, timePct: 0.714, sev: "green"),
            scoped: (pct: 1, timePct: 0.714, sev: "blue"))
        let s = try #require(Self.migrated(line))
        #expect(s.scoped.first?.sev == .green)
        #expect(s.scoped.first?.sevRaw == .blue)
        #expect(s.v == UsageSample.currentVersion)
        #expect(s.sevV == UsageSample.currentColorVersion)
    }

    /// …and the marker appears **only** where the verdict moved: an unchanged window writes no
    /// `sevRaw` at all, which is what keeps every remaining marker meaningful.
    @Test func anUnchangedVerdictWritesNoMarker() {
        let line = Self.v3Line(
            t: Self.pollTime, reset: Self.reset,
            h5: (util: 45, timePct: 0.5, sev: "green"),
            d7: (util: 60, timePct: 0.714, sev: "green"))
        let result = JournalMigration.migrate(contents: line)
        #expect(!result.contents.contains("sevRaw"))
        #expect(result.outcome.severitiesRecomputed == 0)
    }

    /// The 5-hour bar keeps taking the weekly gate — from **this line's** `d7`, which is the one input
    /// a window cannot supply for itself.
    @Test func theFiveHourBarStillTakesTheWeeklyGate() throws {
        func h5Sev(weeklyUtil: Double) throws -> PacingBucket {
            let line = Self.v3Line(
                t: Self.pollTime, reset: Self.reset,
                h5: (util: 0, timePct: 0.6, sev: "green"),      // surplus 0.60 > the 0.40 threshold
                d7: (util: weeklyUtil, timePct: 0.714, sev: "green"))
            return try #require(Self.migrated(line)).h5.sev
        }
        #expect(try h5Sev(weeklyUtil: 10) == .blue)    // week calm with room → gate open
        #expect(try h5Sev(weeklyUtil: 90) == .green)   // week ahead of pace → gate shut
    }

    /// The 7-day window never gates on itself: a deep-behind week stays blue.
    @Test func theSevenDayWindowIsUngated() throws {
        let line = Self.v3Line(
            t: Self.pollTime, reset: Self.reset,
            h5: (util: 20, timePct: 0.5, sev: "green"),
            d7: (util: 1, timePct: 0.714, sev: "green"))
        #expect(try #require(Self.migrated(line)).d7.sev == .blue)
    }

    /// An idle window (empty `reset`) has no pacing geometry, so the verdict comes from utilisation
    /// alone — it must not go through the bar arithmetic, and must not crash the pass. On the live
    /// journals this is over a quarter of all five-hour windows.
    @Test func anIdleWindowIsColouredFromUtilisationAlone() throws {
        let line = """
        {"kind":"usage","v":3,"t":"\(Self.pollTime)",\
        "h5":{"util":0,"raw":0,"reset":"","timePct":0,"sev":"green"},\
        "d7":{"util":100,"raw":100,"reset":"","timePct":0,"sev":"green"},\
        "scoped":[],"sessionIdle":true,"blocked":false,\
        "credits":{"active":false,"showIcon":false,"onCredits":false},"brokenReset":false}
        """
        let s = try #require(Self.migrated(line))
        #expect(s.h5.sev == .green)     // idle, nothing spent
        #expect(s.d7.sev == .red)       // exhausted reads red even with no window geometry
        #expect(s.d7.sevRaw == .green)  // and that is a change from what was recorded
    }

    /// Re-running must be a no-op: after one pass every line is current on both axes.
    @Test func theRecomputationIsIdempotent() {
        let line = Self.v3Line(
            t: Self.pollTime, reset: Self.reset,
            h5: (util: 20, timePct: 0.5, sev: "green"),
            d7: (util: 10, timePct: 0.714, sev: "green"),
            scoped: (pct: 1, timePct: 0.714, sev: "blue"))
        let once = JournalMigration.migrate(contents: line).contents
        let twice = JournalMigration.migrate(contents: once)
        #expect(twice.outcome.migrated == 0)
        #expect(twice.outcome.severitiesRecomputed == 0)
        #expect(twice.contents == once)
    }

    /// A colour-only pass must still be written, but names no older generation — its backup would
    /// otherwise be labelled after a format the file never held.
    @Test func aColourOnlyPassIsWrittenAndNamesNoOlderGeneration() {
        let line = Self.v3Line(
            t: Self.pollTime, reset: Self.reset,
            h5: (util: 20, timePct: 0.5, sev: "green"),
            d7: (util: 10, timePct: 0.714, sev: "green"),
            scoped: (pct: 1, timePct: 0.714, sev: "blue"))
        let once = JournalMigration.migrate(contents: line)
        #expect(once.outcome.migratedFromVersion == 3)    // a real format bump names its generation

        // The same file at the current format, but judged by a superseded colour model.
        let stale = once.contents.replacingOccurrences(
            of: "\"sevV\":\(UsageSample.currentColorVersion)", with: "\"sevV\":0")
        let second = JournalMigration.migrate(contents: stale)
        #expect(second.outcome.changedAnything)               // it must still be rewritten…
        #expect(second.outcome.migratedFromVersion == nil)    // …but claims no older format
    }

    /// `sevRaw` always names what the **poll** wrote, however many times the model moves afterwards: a
    /// later pass must not overwrite the original verdict with an intermediate one.
    @Test func aSecondRecomputationKeepsTheOriginalVerdict() {
        let line = Self.v3Line(
            t: Self.pollTime, reset: Self.reset,
            h5: (util: 20, timePct: 0.5, sev: "green"),
            d7: (util: 10, timePct: 0.714, sev: "green"),
            scoped: (pct: 1, timePct: 0.714, sev: "blue"))
        let once = JournalMigration.migrate(contents: line).contents
        // What a future `currentColorVersion` bump looks like to the pass.
        let stale = once.replacingOccurrences(
            of: "\"sevV\":\(UsageSample.currentColorVersion)", with: "\"sevV\":0")
        let again = decodeUsage(JournalMigration.migrate(contents: stale).contents)
        #expect(again?.scoped.first?.sevRaw == .blue)   // the poll's verdict, not the migrated green
    }
}
