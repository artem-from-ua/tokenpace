import Testing
import Foundation
@testable import TokenPaceKit

/// The migration half of ADR-0123: an archive already full of one-line-per-attempt failures is
/// folded on the next launch. The live writer and this pass share `ErrorRunCollapse`, so they group
/// by identical rules by construction rather than by two implementations agreeing.
@Suite("JournalMigration — error run collapse")
struct JournalErrorCollapseMigrationTests {

    private static func errorLine(
        t: String, code: String = "\"notSent\"", reason: String = "notSent",
        detail: String? = "token expired", v: Int = 2
    ) -> String {
        let detailPart = detail.map { ",\"detail\":\"\($0)\"" } ?? ""
        return #"{"kind":"error","t":"\#(t)","code":\#(code),"reason":"\#(reason)"\#(detailPart),"v":\#(v)}"#
    }

    /// A lone failure at the current format — the shape that must survive a pass byte-for-byte.
    private static func currentErrorLine(t: String) -> String {
        #"{"kind":"error","t":"\#(t)","code":"notSent","reason":"notSent","detail":"token expired","v":\#(ErrorSample.currentVersion),"provider":"claude"}"#
    }

    private static func iso(_ offsetSeconds: Int) -> String {
        let base = Date(timeIntervalSince1970: 1_755_640_800)   // 2026-08-19T22:00:00Z
        return ResetClock.isoString(from: base.addingTimeInterval(Double(offsetSeconds)))
    }

    private static func decodeErrors(_ text: String) -> [ErrorSample] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let record = try? JSONDecoder().decode(JournalRecord.self, from: data),
                  case let .error(s) = record else { return nil }
            return s
        }
    }

    @Test func aRunOfIdenticalErrorsCollapses() {
        let input = (0..<5).map { Self.errorLine(t: Self.iso($0 * 10)) }.joined(separator: "\n")
        let (out, _, outcome) = JournalMigration.migrate(contents: input)

        let errors = Self.decodeErrors(out)
        #expect(errors.count == 1)
        #expect(errors.first?.n == 5)
        #expect(errors.first?.t == Self.iso(0))
        #expect(errors.first?.tEnd == Self.iso(40))
        #expect(errors.first?.detail == "token expired")
        #expect(outcome.errorsCollapsed == 1)
        #expect(outcome.errorLinesRemoved == 4)
        #expect(outcome.changedAnything)
    }

    @Test func aDifferentDetailSplitsTheRun() {
        let input = [
            Self.errorLine(t: Self.iso(0)),
            Self.errorLine(t: Self.iso(10)),
            Self.errorLine(t: Self.iso(20), detail: "keychain access denied"),
            Self.errorLine(t: Self.iso(30), detail: "keychain access denied"),
        ].joined(separator: "\n")

        let errors = Self.decodeErrors(JournalMigration.migrate(contents: input).contents)
        #expect(errors.count == 2)
        #expect(errors.map { $0.n } == [2, 2])
        #expect(errors.map { $0.detail } == ["token expired", "keychain access denied"])
    }

    @Test func aUsageLineBreaksTheRun() {
        // A success ends the failure: the two runs must stay on either side of it, in order.
        let input = [
            Self.errorLine(t: Self.iso(0)), Self.errorLine(t: Self.iso(10)),
            self.v4Usage(t: Self.iso(20)),
            Self.errorLine(t: Self.iso(30)), Self.errorLine(t: Self.iso(40)),
        ].joined(separator: "\n")

        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1].contains("\"kind\":\"usage\""))
        #expect(outcome.errorsCollapsed == 2)
    }

    @Test func aResumeMarkerBreaksTheRunAndSurvives() {
        // A reader leans on resume markers to tell "nothing happened" from "we weren't looking";
        // swallowing one inside a run would erase that distinction.
        let input = [
            Self.errorLine(t: Self.iso(0)), Self.errorLine(t: Self.iso(10)),
            #"{"kind":"resume","t":"2026-08-19T22:05:00Z","gap":900}"#,
            Self.errorLine(t: Self.iso(320)), Self.errorLine(t: Self.iso(330)),
        ].joined(separator: "\n")

        let out = JournalMigration.migrate(contents: input).contents
        #expect(out.contains("\"kind\":\"resume\""))
        #expect(Self.decodeErrors(out).count == 2)
    }

    @Test func anUnparseableLineBreaksTheRunAndSurvivesVerbatim() {
        let torn = #"{"kind":"error","t":"2026-08-1"#
        let input = [Self.errorLine(t: Self.iso(0)), Self.errorLine(t: Self.iso(10)), torn]
            .joined(separator: "\n")

        let out = JournalMigration.migrate(contents: input).contents
        #expect(out.hasSuffix(torn))
        #expect(Self.decodeErrors(out).first?.n == 2)
    }

    @Test func anIsolatedErrorAtTheCurrentFormatIsNotRewritten() {
        // The common case: a lone failure must not gain `n:1,tEnd:t` noise, and its bytes must not
        // even be rewritten — a pass that changes what it cannot improve rewrites every journal.
        let input = Self.currentErrorLine(t: Self.iso(0))
        let (out, _, outcome) = JournalMigration.migrate(contents: input)
        #expect(out == input)
        #expect(outcome.errorsCollapsed == 0)
        #expect(outcome.errorTagged == 0)
        #expect(!outcome.changedAnything)
    }

    /// The byte-passthrough above is overridden exactly once, for a stale line: left in place it would
    /// keep its untagged bytes forever, since nothing else revisits a run of one. Tagged, not
    /// collapsed — there were never two attempts to fold.
    @Test func anIsolatedStaleErrorIsTaggedRatherThanPassedThrough() {
        let (out, _, outcome) = JournalMigration.migrate(contents: Self.errorLine(t: Self.iso(0)))
        #expect(outcome.errorTagged == 1)
        #expect(outcome.errorsCollapsed == 0)
        #expect(outcome.changedAnything)

        let sample = Self.decodeErrors(out).first
        #expect(sample?.v == ErrorSample.currentVersion)
        #expect(sample?.provider == ProviderID.claude.rawValue)
        #expect(sample?.n == nil)                        // still one attempt, no collapse noise
        #expect(sample?.detail == "token expired")       // and its facts carry across
    }

    @Test func theCollapseIsIdempotent() {
        let input = (0..<40).map { Self.errorLine(t: Self.iso($0 * 2)) }.joined(separator: "\n")
        let first = JournalMigration.migrate(contents: input)
        #expect(first.outcome.errorsCollapsed > 0)

        let second = JournalMigration.migrate(contents: first.contents, state: .init())
        #expect(second.outcome.errorsCollapsed == 0)
        #expect(!second.outcome.changedAnything)
        #expect(second.contents == first.contents)
    }

    @Test func anErrorOnlyChangeIsDetectedAsChanged() {
        // The `changedAnything` trap: a counter missing from that `||` means the pass computes a
        // correct rewrite and the shell silently declines it (#456 shipped exactly that bug).
        let input = [Self.errorLine(t: Self.iso(0)), Self.errorLine(t: Self.iso(10))].joined(separator: "\n")
        let outcome = JournalMigration.migrate(contents: input).outcome
        #expect(outcome.migrated == 0)
        #expect(outcome.statusTagged == 0)
        #expect(outcome.changedAnything)
    }

    @Test func outOfOrderTimestampsStillCollapseByAdjacency() {
        // Real journals hold inverted timestamps (two processes under `flock`). Grouping is by file
        // adjacency, so the run survives; `t`/`tEnd` come from file order, not from sorting.
        let input = [Self.errorLine(t: Self.iso(60)), Self.errorLine(t: Self.iso(0))].joined(separator: "\n")
        let errors = Self.decodeErrors(JournalMigration.migrate(contents: input).contents)
        #expect(errors.count == 1)
        #expect(errors.first?.n == 2)
    }

    @Test func trailingNewlineSurvivesACollapse() {
        let input = (0..<4).map { Self.errorLine(t: Self.iso($0 * 10)) }.joined(separator: "\n") + "\n"
        let out = JournalMigration.migrate(contents: input).contents
        #expect(out.hasSuffix("\n"))
        #expect(Self.decodeErrors(out).first?.n == 4)
    }

    @Test func theStormFileCollapsesAndLosesNoAttempt() {
        // 1 000 attempts one second apart — the incident's shape at unit scale. The bound that
        // matters is not the line count but that every attempt is still represented.
        let input = (0..<1000).map { Self.errorLine(t: Self.iso($0)) }.joined(separator: "\n")
        let (out, _, outcome) = JournalMigration.migrate(contents: input)

        let errors = Self.decodeErrors(out)
        #expect(errors.count == 6)                                     // 1000 s / 180 s
        #expect(errors.map { $0.n ?? 1 }.reduce(0, +) == 1000)
        #expect(outcome.errorLinesRemoved == 1000 - 6)
    }

    /// A current-format usage line — enough shape for the migration to pass it through untouched.
    private func v4Usage(t: String) -> String {
        let h5 = #"{"util":10,"raw":10,"sev":"green","reset":"2026-08-20T02:00:00Z","timePct":0.5}"#
        let d7 = #"{"util":20,"raw":20,"sev":"green","reset":"2026-08-25T00:00:00Z","timePct":0.5}"#
        let head = #"{"kind":"usage","v":4,"sevV":1,"t":"\#(t)""#
        return head + #","h5":"# + h5 + #","d7":"# + d7 + "}"
    }
}
