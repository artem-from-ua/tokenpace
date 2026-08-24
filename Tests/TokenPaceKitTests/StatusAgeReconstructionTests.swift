import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Status age reconstructed from the journal (#503)

/// The fallback when a provider's feed cannot say when a component changed. Its **limits** are what
/// these tests pin: no history means no age, and the oldest line in the record is not evidence of a
/// change.
@Suite("Status age reconstruction")
struct StatusAgeReconstructionTests {

    private static let base = Date(timeIntervalSince1970: 1_787_000_000)

    private func sample(
        _ minutesAgo: Int,
        _ entries: [(String, String)],
        provider: ProviderID = .codex
    ) -> StatusSample {
        StatusSample(
            t: ResetClock.isoString(from: Self.base.addingTimeInterval(-Double(minutesAgo) * 60)),
            provider: provider.rawValue,
            svc: entries.map { StatusSample.ServiceEntry(n: $0.0, s: $0.1) },
            worst: "operational")
    }

    /// A component that turned red partway through the record is dated to the first line that saw it
    /// red, not to the newest line and not to the change's true instant — the resolution is the poll
    /// cadence, and this is what that means.
    @Test func aChangeIsDatedToTheFirstPollThatSawIt() {
        let samples = [
            sample(50, [("CLI", "operational")]),
            sample(40, [("CLI", "operational")]),
            sample(30, [("CLI", "major_outage")]),
            sample(20, [("CLI", "major_outage")]),
            sample(10, [("CLI", "major_outage")]),
        ]
        let ages = StatusAgeReconstruction.changedAt(from: samples, provider: .codex)
        #expect(ages["CLI"] == Self.base.addingTimeInterval(-30 * 60))
    }

    /// The order the lines arrive in must not matter — the journal is append-only but a caller may
    /// concatenate two months.
    @Test func inputOrderDoesNotMatter() {
        let samples = [
            sample(10, [("CLI", "major_outage")]),
            sample(50, [("CLI", "operational")]),
            sample(30, [("CLI", "major_outage")]),
            sample(20, [("CLI", "major_outage")]),
            sample(40, [("CLI", "operational")]),
        ]
        #expect(StatusAgeReconstruction.changedAt(from: samples, provider: .codex)["CLI"]
            == Self.base.addingTimeInterval(-30 * 60))
    }

    /// A fresh install has no history, and the honest answer is no age at all — never zero, which
    /// would claim the component had just changed.
    @Test func noHistoryYieldsNoAge() {
        #expect(StatusAgeReconstruction.changedAt(from: [], provider: .codex).isEmpty)
    }

    /// A status that has held for the whole record is **not** dated to the record's first line: that
    /// would report the retention window's edge as a change that never happened.
    @Test func aStatusHeldForTheWholeRecordHasNoReconstructedAge() {
        let samples = [
            sample(50, [("CLI", "operational")]),
            sample(30, [("CLI", "operational")]),
            sample(10, [("CLI", "operational")]),
        ]
        #expect(StatusAgeReconstruction.changedAt(from: samples, provider: .codex)["CLI"] == nil)
    }

    /// One provider's lines never answer for another's — the same isolation the healths keep.
    @Test func anotherProvidersLinesAreIgnored() {
        let samples = [
            sample(50, [("CLI", "operational")], provider: .codex),
            sample(40, [("CLI", "major_outage")], provider: .github),
            sample(30, [("CLI", "operational")], provider: .codex),
        ]
        #expect(StatusAgeReconstruction.changedAt(from: samples, provider: .codex)["CLI"] == nil)
        #expect(StatusAgeReconstruction.changedAt(from: samples, provider: .github).isEmpty)
    }

    /// A line that does not name the component ends the walk: its absence is not evidence the status
    /// held across it.
    @Test func aGapInTheFeedEndsTheWalk() {
        let samples = [
            sample(50, [("CLI", "major_outage")]),
            sample(40, []),
            sample(30, [("CLI", "major_outage")]),
            sample(20, [("CLI", "major_outage")]),
        ]
        #expect(StatusAgeReconstruction.changedAt(from: samples, provider: .codex)["CLI"]
            == Self.base.addingTimeInterval(-30 * 60))
    }

    /// Components are reconstructed independently — one changing does not re-date the others.
    @Test func componentsAreIndependent() {
        let samples = [
            sample(60, [("CLI", "operational"), ("Codex API", "operational")]),
            sample(40, [("CLI", "major_outage"), ("Codex API", "operational")]),
            sample(20, [("CLI", "major_outage"), ("Codex API", "degraded_performance")]),
        ]
        let ages = StatusAgeReconstruction.changedAt(from: samples, provider: .codex)
        #expect(ages["CLI"] == Self.base.addingTimeInterval(-40 * 60))
        #expect(ages["Codex API"] == Self.base.addingTimeInterval(-20 * 60))
    }
}
