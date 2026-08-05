import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

private func component(_ name: String, _ status: String, updatedAt: String? = nil) -> StatusComponent {
    StatusComponent(name: name, status: status, updatedAt: updatedAt)
}

private func update(_ id: String, _ body: String = "…") -> StatusIncidentUpdate {
    StatusIncidentUpdate(id: id, status: "identified", body: body)
}

private func incident(
    id: String,
    status: String = "identified",
    updates: [StatusIncidentUpdate] = []
) -> StatusIncident {
    StatusIncident(id: id, name: "Something is degraded", status: status, incidentUpdates: updates)
}

private let baseline = StatusSummary(
    components: [component("Claude Code", "degraded_performance"), component("claude.ai", "operational")],
    incidents: [incident(id: "inc1", updates: [update("u1"), update("u2")])])

// MARK: - Order independence

@Suite("StatusPayloadFingerprint — order independence")
struct FingerprintOrderTests {

    /// The load-bearing property: Statuspage does not promise array order, and without sorting a
    /// reshuffled-but-identical payload would write a duplicate line on every single poll.
    @Test func reorderedComponentsFingerprintIdentically() {
        let reordered = StatusSummary(
            components: baseline.components.reversed(),
            incidents: baseline.incidents)
        #expect(StatusPayloadFingerprint.of(reordered) == StatusPayloadFingerprint.of(baseline))
    }

    @Test func reorderedIncidentsFingerprintIdentically() {
        let two = StatusSummary(
            components: baseline.components,
            incidents: [incident(id: "a"), incident(id: "b")])
        let flipped = StatusSummary(
            components: baseline.components,
            incidents: [incident(id: "b"), incident(id: "a")])
        #expect(StatusPayloadFingerprint.of(flipped) == StatusPayloadFingerprint.of(two))
    }

    @Test func reorderedUpdatesFingerprintIdentically() {
        let flipped = StatusSummary(
            components: baseline.components,
            incidents: [incident(id: "inc1", updates: [update("u2"), update("u1")])])
        #expect(StatusPayloadFingerprint.of(flipped) == StatusPayloadFingerprint.of(baseline))
    }

    @Test func anIdenticalPollFingerprintsIdentically() {
        #expect(StatusPayloadFingerprint.of(baseline) == StatusPayloadFingerprint.of(baseline))
    }
}

// MARK: - Sensitivity

@Suite("StatusPayloadFingerprint — what counts as a change")
struct FingerprintSensitivityTests {

    @Test func aComponentStatusChangeShows() {
        let recovered = StatusSummary(
            components: [component("Claude Code", "operational"), component("claude.ai", "operational")],
            incidents: baseline.incidents)
        #expect(StatusPayloadFingerprint.of(recovered) != StatusPayloadFingerprint.of(baseline))
    }

    @Test func aNewUpdateShows() {
        let extra = StatusSummary(
            components: baseline.components,
            incidents: [incident(id: "inc1", updates: [update("u1"), update("u2"), update("u3")])])
        #expect(StatusPayloadFingerprint.of(extra) != StatusPayloadFingerprint.of(baseline))
    }

    @Test func anIncidentStageChangeShows() {
        let monitoring = StatusSummary(
            components: baseline.components,
            incidents: [incident(id: "inc1", status: "monitoring", updates: [update("u1"), update("u2")])])
        #expect(StatusPayloadFingerprint.of(monitoring) != StatusPayloadFingerprint.of(baseline))
    }

    @Test func aNewIncidentShows() {
        let two = StatusSummary(
            components: baseline.components,
            incidents: baseline.incidents + [incident(id: "inc2")])
        #expect(StatusPayloadFingerprint.of(two) != StatusPayloadFingerprint.of(baseline))
    }

    @Test func anIncidentDisappearingShows() {
        let none = StatusSummary(components: baseline.components, incidents: [])
        #expect(StatusPayloadFingerprint.of(none) != StatusPayloadFingerprint.of(baseline))
    }

    /// An update's body is edited retroactively without its `id` changing. Identity is the `id`, so
    /// a reworded update is not a new event and must not log a line (ADR-0071 §7).
    @Test func anEditedUpdateBodyDoesNotShow() {
        let edited = StatusSummary(
            components: baseline.components,
            incidents: [incident(id: "inc1", updates: [update("u1", "reworded"), update("u2", "also reworded")])])
        #expect(StatusPayloadFingerprint.of(edited) == StatusPayloadFingerprint.of(baseline))
    }

    /// `updated_at` moves only when the status moves, which the fingerprint already covers — so a
    /// timestamp alone must not count as material.
    @Test func aTimestampAloneDoesNotShow() {
        let stamped = StatusSummary(
            components: [
                component("Claude Code", "degraded_performance", updatedAt: "2026-08-05T13:51:30.376Z"),
                component("claude.ai", "operational", updatedAt: "2026-08-05T14:14:35.909Z"),
            ],
            incidents: baseline.incidents)
        #expect(StatusPayloadFingerprint.of(stamped) == StatusPayloadFingerprint.of(baseline))
    }
}

// MARK: - Degenerate payloads

@Suite("StatusPayloadFingerprint — empty and all-clear")
struct FingerprintEmptyTests {

    @Test func anEmptySummaryHasAStableFingerprint() {
        let empty = StatusSummary(components: [], incidents: [])
        #expect(StatusPayloadFingerprint.of(empty) == StatusPayloadFingerprint.of(empty))
    }

    @Test func allClearDiffersFromDegraded() {
        let allClear = StatusSummary(
            components: [component("Claude Code", "operational"), component("claude.ai", "operational")],
            incidents: [])
        #expect(StatusPayloadFingerprint.of(allClear) != StatusPayloadFingerprint.of(baseline))
    }

    /// Two different shapes must not collide through the separator characters.
    @Test func componentAndIncidentSectionsDoNotBleed() {
        let a = StatusSummary(components: [component("x=y", "operational")], incidents: [])
        let b = StatusSummary(components: [], incidents: [incident(id: "x=y", status: "operational")])
        #expect(StatusPayloadFingerprint.of(a) != StatusPayloadFingerprint.of(b))
    }
}
