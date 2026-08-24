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

    /// Count what the two post-collapse invariants are stated over: lines that are not `error`
    /// records (which must be conserved exactly), and error *attempts* (`n ?? 1` summed, which must
    /// be conserved even though the lines carrying them are folded).
    private static func census(_ contents: String) -> (otherLines: Int, attempts: Int) {
        let decoder = JSONDecoder()
        var other = 0, attempts = 0
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { other += 1; continue }
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(JournalRecord.self, from: data),
                  case let .error(sample) = record else { other += 1; continue }
            attempts += sample.n ?? 1
        }
        return (other, attempts)
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

            // A migration that loses records is worse than one that does nothing, whatever else it
            // improves. Since ADR-0123 that is two invariants rather than a raw line count, and both
            // are stronger than the count they replace:
            //
            //  1. Every **non-error** line survives exactly. This is the protection the line count
            //     was actually buying — a dropped usage or status line is unrecoverable.
            //  2. Every error **attempt** survives, as itself or inside a run's `n`. A collapse folds
            //     lines on purpose; losing an attempt is still a bug, and `sum(n ?? 1)` catches a
            //     miscomputed count that a line count never could.
            let (beforeOther, beforeAttempts) = Self.census(contents)
            let (afterOther, afterAttempts) = Self.census(migrated)
            #expect(beforeOther == afterOther,
                    "\(name): non-error lines changed \(beforeOther) → \(afterOther)")
            #expect(beforeAttempts == afterAttempts,
                    "\(name): error attempts changed \(beforeAttempts) → \(afterAttempts)")

            let before = contents.split(separator: "\n", omittingEmptySubsequences: false).count
            let after = migrated.split(separator: "\n", omittingEmptySubsequences: false).count
            if before != after {
                print("\(name): \(before) → \(after) lines, \(beforeAttempts) error attempts preserved")
            }

            // Re-running must be a no-op — the pass is one-off by construction.
            let again = JournalMigration.migrate(contents: migrated, state: .init())
            #expect(again.outcome.migrated == 0, "\(name): second pass rewrote lines")
            #expect(again.outcome.resetsRepaired == 0, "\(name): second pass repaired resets")
            #expect(again.outcome.statusTagged == 0, "\(name): second pass re-tagged status lines")
            #expect(again.outcome.errorsCollapsed == 0, "\(name): second pass re-collapsed errors")
            #expect(again.outcome.errorTagged == 0, "\(name): second pass re-tagged error lines")
            #expect(again.outcome.resumeTagged == 0, "\(name): second pass re-tagged resume markers")
            #expect(!again.outcome.changedAnything, "\(name): second pass reports a change")

            // The #456 invariant: after the pass, no stored `status` line relies on "absent means
            // Claude". Read back from the migrated text, not from the counters — the counters describe
            // the pass, this describes the file.
            let statuses = migrated
                .split(separator: "\n")
                .compactMap { line -> StatusSample? in
                    guard let data = line.data(using: .utf8),
                          let record = try? JSONDecoder().decode(JournalRecord.self, from: data),
                          case let .status(sample) = record else { return nil }
                    return sample
                }
            let untagged = statuses.filter { $0.v < StatusSample.currentVersion }.count
            #expect(untagged == 0, "\(name): \(untagged) status lines still carry no provider")
            #expect(statuses.allSatisfy { $0.provider == ProviderID.claude.rawValue },
                    "\(name): a status line carries an unexpected provider")

            // The same invariant for the other three kinds (#502): after the pass, no stored line of
            // any kind relies on "absent means Claude".
            var staleOtherKinds = 0
            var foreignProvider = 0
            for line in migrated.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let record = try? JSONDecoder().decode(JournalRecord.self, from: data)
                else { continue }
                switch record {
                case let .usage(s):
                    if s.v < UsageSample.currentVersion { staleOtherKinds += 1 }
                    if s.provider != ProviderID.claude.rawValue { foreignProvider += 1 }
                case let .error(s):
                    if s.v < ErrorSample.currentVersion { staleOtherKinds += 1 }
                    if s.provider != ProviderID.claude.rawValue { foreignProvider += 1 }
                case let .resume(m):
                    if m.v < ResumeMarker.currentVersion { staleOtherKinds += 1 }
                    if m.provider != ProviderID.claude.rawValue { foreignProvider += 1 }
                case .status, .unknown:
                    continue
                }
            }
            #expect(staleOtherKinds == 0,
                    "\(name): \(staleOtherKinds) usage/error/resume lines still carry no provider")
            #expect(foreignProvider == 0,
                    "\(name): \(foreignProvider) lines carry a provider other than Claude")

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

            // Which verdicts the current colour model changed, and where (#426). Printed as a matrix
            // because the aggregate hides the shape: on the measured journals almost all of it is one
            // cell — scoped `blue → green`, the per-model blue that only ever existed in the file.
            var transitions: [String: Int] = [:]
            var blueLeftInPerModel = 0
            for sample in samples {
                for (label, w) in [("h5", sample.h5), ("d7", sample.d7)] + [
                    ("opus", sample.opus), ("sonnet", sample.sonnet),
                ].compactMap({ label, w in w.map { (label, $0) } }) {
                    if let was = w.sevRaw { transitions["\(label): \(was) → \(w.sev)", default: 0] += 1 }
                    if label != "h5", label != "d7", w.sev == .blue { blueLeftInPerModel += 1 }
                }
                for s in sample.scoped {
                    if let was = s.sevRaw { transitions["scoped: \(was) → \(s.sev)", default: 0] += 1 }
                    if s.sev == .blue { blueLeftInPerModel += 1 }
                }
            }
            let matrix = transitions.sorted { $0.value > $1.value }
                .map { "\n                  \($0.key.padding(toLength: 24, withPad: " ", startingAt: 0)) \($0.value)" }
                .joined()

            print("""

            ── \(name)
               lines            : \(before)
               usage samples    : \(samples.count)
               status samples   : \(statuses.count)
               rewritten        : \(outcome.migrated)
               status tagged    : \(outcome.statusTagged)
               error tagged     : \(outcome.errorTagged)
               resume tagged    : \(outcome.resumeTagged)
               resets repaired  : \(outcome.resetsRepaired)
               severities recomputed : \(outcome.severitiesRecomputed)\(matrix)
               out of order     : \(outcome.outOfOrder)
               unparseable      : \(outcome.skipped)
               worst error      : \(String(format: "%.3f", worstError)) s
               longest 0 run    : \(longestZeroRun)
            """)

            // The invariant the whole change exists for: after the pass, no per-model window claims a
            // colour the popup would never paint.
            #expect(blueLeftInPerModel == 0,
                    "\(name): \(blueLeftInPerModel) per-model windows still blue after migration")
            // The counters describe **this** pass; the markers in the file describe every pass ever run
            // over it. They only have to agree when this pass is the one that put them there — pointed
            // at an already-migrated journal (a re-run, or a copy someone migrated yesterday) the file
            // still carries its `sevRaw`/`resetSrc` while the pass correctly reports zero.
            //
            // Keyed on `migrated`, **not** on `changedAnything`: since #456 the latter also flips for a
            // pass whose only work was tagging status lines, and these two assertions are about usage
            // samples. A journal with stale status lines and current usage lines would otherwise be
            // asked to explain `sevRaw` markers this pass never wrote.
            if outcome.migrated > 0 {
                #expect(transitions.values.reduce(0, +) == outcome.severitiesRecomputed,
                        "\(name): transition matrix disagrees with the counter")
                #expect(repairedSeen == outcome.resetsRepaired,
                        "\(name): counter disagrees with the rewritten lines")
            } else {
                // Nothing to rewrite is a valid, meaningful outcome: it says the file is already current
                // on both axes. Pin that rather than skipping — a pass that reports zero while leaving
                // stale lines behind would otherwise look identical to success.
                #expect(outcome.severitiesRecomputed == 0 && outcome.resetsRepaired == 0,
                        "\(name): reported work without rewriting anything")
                #expect(samples.allSatisfy { $0.v == UsageSample.currentVersion
                                             && $0.sevV == UsageSample.currentColorVersion },
                        "\(name): pass rewrote nothing but the file is not current")
            }
            // The repaired dates must land on the real grid, not near it.
            #expect(worstError < 1, "\(name): worst repair error \(worstError) s")
            // And the whole point: the marker moves again instead of sitting at zero for hours.
            #expect(longestZeroRun <= 1, "\(name): \(longestZeroRun) consecutive repaired zeros")
        }
    }
}
