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
        #expect(last.d7.src != nil)                      // and it says how it got there
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
            d7: WindowSample(util: 50.25, raw: 50, src: "interpolated", n: 9.8,
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
