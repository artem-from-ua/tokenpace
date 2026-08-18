import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Live-journal migration check (opt-in)

/// Runs the real migration over the maintainer's own journals and reports what it recovered.
///
/// **Opt-in and read-only.** Skipped unless `TOKENPACE_LIVE_JOURNALS` names a directory, so CI and
/// everyday `swift test` never touch personal data. The files are read, never written — the pass is
/// pure, and the copy on disk is left exactly as it was.
///
/// It exists because the fixtures in `JournalMigrationTests` are hand-built from three lines, while
/// the thing being repaired is a 5 000-line file with real polling gaps, out-of-order timestamps and
/// two plans' worth of differing reset grids. A pass that works on both of those is evidence the
/// fixtures cannot give.
@Suite("Live journal migration", .enabled(if: ProcessInfo.processInfo.environment["TOKENPACE_LIVE_JOURNALS"] != nil))
struct LiveJournalMigrationCheck {

    private static var directory: String {
        ProcessInfo.processInfo.environment["TOKENPACE_LIVE_JOURNALS"] ?? ""
    }

    private static func journals() -> [(name: String, contents: String)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return files
            .filter { $0.hasSuffix(".jsonl") && $0.contains("usage-journal") }
            .sorted()
            .compactMap { name in
                guard let text = try? String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8)
                else { return nil }
                return (name, text)
            }
    }

    /// Migrate each journal found and print a summary: how many lines were rewritten, how many weekly
    /// resets were repaired, and — the number that matters — how far each repaired date lands from the
    /// value the server itself reported once the blackout ended.
    @Test func migratesEveryLiveJournalAndReportsAccuracy() throws {
        let journals = Self.journals()
        #expect(!journals.isEmpty, "no journals found in \(Self.directory)")

        for (name, contents) in journals {
            let (migrated, _, outcome) = JournalMigration.migrate(contents: contents)

            // Every line must survive: a migration that loses records is worse than one that does
            // nothing, whatever else it improves.
            let before = contents.split(separator: "\n", omittingEmptySubsequences: false).count
            let after = migrated.split(separator: "\n", omittingEmptySubsequences: false).count
            #expect(before == after, "\(name): line count changed \(before) → \(after)")

            // Re-running must be a no-op — the pass is one-off by construction.
            let again = JournalMigration.migrate(contents: migrated, state: .init())
            #expect(again.outcome.migrated == 0, "\(name): second pass rewrote lines")
            #expect(again.outcome.resetsRepaired == 0, "\(name): second pass repaired resets")

            let samples = migrated
                .split(separator: "\n")
                .compactMap { line -> UsageSample? in
                    guard let data = line.data(using: .utf8),
                          let record = try? JSONDecoder().decode(JournalRecord.self, from: data),
                          case let .usage(sample) = record else { return nil }
                    return sample
                }

            // Accuracy: for each repaired line, compare against the next genuinely server-supplied
            // reset in the file — the answer the app eventually received.
            var worstError: TimeInterval = 0
            var repairedSeen = 0
            for (index, sample) in samples.enumerated() where sample.d7.resetSrc == "reconstructed" {
                repairedSeen += 1
                guard let repaired = ResetClock.parse(sample.d7.reset) else { continue }
                let truth = samples[index...]
                    .first { $0.d7.resetSrc == "server" }
                    .flatMap { ResetClock.parse($0.d7.reset) }
                guard let truth else { continue }
                worstError = max(worstError, abs(repaired.timeIntervalSince(truth)))
            }

            // A repaired line may legitimately read 0 — the first poll of a blackout fires in the
            // very second of the reset, when the window genuinely has not started. What must never
            // survive is a *run* of zeros: that is the old estimate holding the marker at the left
            // edge for hours, which is the defect being repaired. Measured on both journals, exactly
            // one such line exists per blackout.
            var longestZeroRun = 0, currentZeroRun = 0
            for sample in samples where sample.d7.resetSrc == "reconstructed" {
                currentZeroRun = sample.d7.timePct == 0 ? currentZeroRun + 1 : 0
                longestZeroRun = max(longestZeroRun, currentZeroRun)
            }

            print("""

            ── \(name)
               lines            : \(before)
               usage samples    : \(samples.count)
               rewritten        : \(outcome.migrated)
               resets repaired  : \(outcome.resetsRepaired)
               out of order     : \(outcome.outOfOrder)
               unparseable      : \(outcome.skipped)
               worst error      : \(String(format: "%.3f", worstError)) s
               longest 0 run    : \(longestZeroRun)
            """)

            #expect(repairedSeen == outcome.resetsRepaired,
                    "\(name): counter disagrees with the rewritten lines")
            // The repaired dates must land on the real grid, not near it.
            #expect(worstError < 1, "\(name): worst repair error \(worstError) s")
            // And the whole point: the marker moves again instead of sitting at zero for hours.
            #expect(longestZeroRun <= 1, "\(name): \(longestZeroRun) consecutive repaired zeros")
        }
    }
}
