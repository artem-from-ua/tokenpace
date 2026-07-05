import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - ServiceStatus mapping

@Suite("ServiceStatus from raw API value")
struct ServiceStatusMappingTests {

    @Test func operationalMaps() {
        #expect(ServiceStatus(rawAPIValue: "operational") == .operational)
    }

    @Test func degradedPerformanceMaps() {
        #expect(ServiceStatus(rawAPIValue: "degraded_performance") == .degraded)
    }

    @Test func partialOutageMaps() {
        #expect(ServiceStatus(rawAPIValue: "partial_outage") == .partialOutage)
    }

    @Test func majorOutageMaps() {
        #expect(ServiceStatus(rawAPIValue: "major_outage") == .majorOutage)
    }

    @Test func underMaintenanceMaps() {
        #expect(ServiceStatus(rawAPIValue: "under_maintenance") == .underMaintenance)
    }

    @Test func unrecognisedMapsToUnknown() {
        #expect(ServiceStatus(rawAPIValue: "totally_new_status") == .unknown)
        #expect(ServiceStatus(rawAPIValue: "") == .unknown)
    }
}

// MARK: - StatusHealth.from

@Suite("StatusHealth.from(summary:)")
struct StatusHealthFromTests {

    /// Build a summary from `(name, status)` pairs.
    private func summary(_ pairs: [(String, String)]) -> StatusSummary {
        StatusSummary(components: pairs.map { StatusComponent(name: $0.0, status: $0.1) })
    }

    @Test func extractsBothComponentsByName() {
        let health = StatusHealth.from(summary([
            ("Claude Code", "operational"),
            ("Claude API (api.anthropic.com)", "degraded_performance"),
        ]))
        #expect(health.claudeCode == .operational)
        #expect(health.claudeAPI == .degraded)
    }

    @Test func componentsAreIndependent() {
        let health = StatusHealth.from(summary([
            ("Claude Code", "major_outage"),
            ("Claude API (api.anthropic.com)", "operational"),
        ]))
        #expect(health.claudeCode == .majorOutage)
        #expect(health.claudeAPI == .operational)
    }

    @Test func missingComponentIsUnknown() {
        // Only Claude Code present; Claude API absent → unknown (not silently operational).
        let health = StatusHealth.from(summary([("Claude Code", "operational")]))
        #expect(health.claudeCode == .operational)
        #expect(health.claudeAPI == .unknown)
    }

    @Test func ignoresUnrelatedComponents() {
        let health = StatusHealth.from(summary([
            ("claude.ai", "major_outage"),
            ("Claude Cowork", "partial_outage"),
            ("Claude Code", "operational"),
            ("Claude API (api.anthropic.com)", "operational"),
            ("Claude for Government", "major_outage"),
        ]))
        #expect(health.claudeCode == .operational)
        #expect(health.claudeAPI == .operational)
    }

    @Test func emptyComponentsAreUnknown() {
        let health = StatusHealth.from(summary([]))
        #expect(health == .unknown)
    }
}

// MARK: - StatusHealth.unknown

@Suite("StatusHealth.unknown")
struct StatusHealthUnknownTests {

    @Test func bothComponentsUnknown() {
        #expect(StatusHealth.unknown.claudeCode == .unknown)
        #expect(StatusHealth.unknown.claudeAPI == .unknown)
    }
}

// MARK: - worstProblem (menu-bar dot)

@Suite("StatusHealth.worstProblem")
struct StatusHealthWorstProblemTests {

    @Test func bothOperationalHasNoProblem() {
        let h = StatusHealth(claudeCode: .operational, claudeAPI: .operational)
        #expect(h.worstProblem == nil)
    }

    @Test func oneDegradedSurfaces() {
        let h = StatusHealth(claudeCode: .operational, claudeAPI: .degraded)
        #expect(h.worstProblem == .degraded)
    }

    @Test func picksTheMoreSevereOfTwo() {
        // major_outage outranks degraded.
        let h = StatusHealth(claudeCode: .degraded, claudeAPI: .majorOutage)
        #expect(h.worstProblem == .majorOutage)
    }

    @Test func severityOrdering() {
        // operational < underMaintenance < unknown < degraded < partialOutage < majorOutage
        #expect(StatusHealth(claudeCode: .underMaintenance, claudeAPI: .unknown).worstProblem == .unknown)
        #expect(StatusHealth(claudeCode: .unknown, claudeAPI: .degraded).worstProblem == .degraded)
        #expect(StatusHealth(claudeCode: .degraded, claudeAPI: .partialOutage).worstProblem == .partialOutage)
    }

    @Test func unknownCountsAsProblem() {
        // A failed fetch (both unknown) still shows a (grey) dot — honest "don't know".
        #expect(StatusHealth.unknown.worstProblem == .unknown)
    }

    @Test func maintenanceCountsAsProblem() {
        let h = StatusHealth(claudeCode: .underMaintenance, claudeAPI: .operational)
        #expect(h.worstProblem == .underMaintenance)
    }
}

// MARK: - Incidents are ignored (ADR-0013)

@Suite("Status incidents do not affect component state")
struct StatusIncidentsIgnoredTests {

    /// A real-shape summary where both tracked components are `operational` but an active `major`
    /// incident lists both (the Mythos/Fable suspension case). Decoding it and mapping must yield
    /// two `operational` states — incidents are not decoded, so they cannot change the lines.
    @Test func operationalDespiteActiveMajorIncident() throws {
        let json = """
        {"page":{"name":"Claude"},
         "status":{"indicator":"major","description":"Major Outage"},
         "components":[
           {"name":"claude.ai","status":"operational"},
           {"name":"Claude API (api.anthropic.com)","status":"operational"},
           {"name":"Claude Code","status":"operational"}],
         "incidents":[
           {"name":"We've suspended access to Claude Mythos 5 and Claude Fable 5",
            "status":"monitoring","impact":"major",
            "components":[{"name":"Claude API (api.anthropic.com)"},{"name":"Claude Code"}]}],
         "scheduled_maintenances":[]}
        """.data(using: .utf8)!

        let summary = try StatusClient.decode(from: json)
        let health = StatusHealth.from(summary)

        #expect(health.claudeCode == .operational)
        #expect(health.claudeAPI == .operational)
    }
}
