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

// MARK: - Test helpers

/// Build a summary from `(name, status)` pairs.
private func summary(_ pairs: [(String, String)]) -> StatusSummary {
    StatusSummary(components: pairs.map { StatusComponent(name: $0.0, status: $0.1) })
}

/// The status of a logical service in a `StatusHealth`, or `nil` if that service is not present.
private func check(_ id: ServiceID, in health: StatusHealth) -> ServiceCheck? {
    health.checks.first { $0.id == id }
}

// MARK: - ServiceCheck.status (worst-of-N)

@Suite("ServiceCheck.status (worst-of-N)")
struct ServiceCheckStatusTests {

    private func check(_ statuses: [ServiceStatus]) -> ServiceCheck {
        ServiceCheck(id: .webDesktop, components: statuses.enumerated().map {
            ResolvedComponent(name: "c\($0.offset)", status: $0.element)
        })
    }

    @Test func singleComponentPassesThrough() {
        #expect(check([.degraded]).status == .degraded)
        #expect(check([.operational]).status == .operational)
    }

    @Test func picksMoreSevereOfTwo() {
        #expect(check([.operational, .majorOutage]).status == .majorOutage)
        #expect(check([.degraded, .partialOutage]).status == .partialOutage)
    }

    @Test func coworkOutageDrivesWorstOfN() {
        // claude.ai operational + Cowork major → the service row reads major.
        #expect(check([.operational, .majorOutage]).status == .majorOutage)
    }

    @Test func emptyComponentsIsUnknown() {
        #expect(ServiceCheck(id: .webDesktop, components: []).status == .unknown)
    }
}

// MARK: - StatusHealth.from(_:config:)

@Suite("StatusHealth.from with config")
struct StatusHealthFromTests {

    private let allComponents: [(String, String)] = [
        ("Claude API (api.anthropic.com)", "operational"),
        ("Claude Code", "operational"),
        ("claude.ai", "operational"),
        ("Claude Cowork", "operational"),
    ]

    @Test func claudeAPIAlwaysPresentEvenWhenEverythingElseOff() {
        // Both toggleable services disabled → Claude API is still monitored (it is not configurable).
        let config = MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: false)
        let health = StatusHealth.from(summary(allComponents), config: config)
        #expect(health.checks.map(\.id) == [.claudeAPI])
        #expect(check(.claudeAPI, in: health)?.components.map(\.name) == ["Claude API (api.anthropic.com)"])
    }

    @Test func defaultConfigHasApiCodeAndWebDesktop() {
        let health = StatusHealth.from(summary(allComponents), config: .default)
        #expect(health.checks.map(\.id) == [.claudeAPI, .claudeCode, .webDesktop])
    }

    @Test func disabledClaudeCodeProducesNoCheck() {
        let config = MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: true)
        let health = StatusHealth.from(summary(allComponents), config: config)
        #expect(check(.claudeCode, in: health) == nil)
        #expect(check(.claudeAPI, in: health) != nil)
        #expect(check(.webDesktop, in: health) != nil)
    }

    @Test func disabledWebDesktopProducesNoCheck() {
        let config = MonitoredServices(claudeCodeEnabled: true, webDesktopEnabled: false)
        let health = StatusHealth.from(summary(allComponents), config: config)
        #expect(check(.webDesktop, in: health) == nil)
    }

    @Test func webDesktopChatOnlyHasOneComponent() {
        let config = MonitoredServices(webDesktopEnabled: true, webDesktopMode: .chatOnly)
        let health = StatusHealth.from(summary(allComponents), config: config)
        #expect(check(.webDesktop, in: health)?.components.map(\.name) == ["claude.ai"])
    }

    @Test func webDesktopCoworkAddsCoworkComponent() {
        let config = MonitoredServices(webDesktopEnabled: true, webDesktopMode: .chatAndCowork)
        let health = StatusHealth.from(summary(allComponents), config: config)
        #expect(check(.webDesktop, in: health)?.components.map(\.name) == ["claude.ai", "Claude Cowork"])
    }

    @Test func mapsComponentStatusesByName() {
        let health = StatusHealth.from(summary([
            ("Claude API (api.anthropic.com)", "degraded_performance"),
            ("Claude Code", "major_outage"),
        ]), config: .default)
        #expect(check(.claudeAPI, in: health)?.status == .degraded)
        #expect(check(.claudeCode, in: health)?.status == .majorOutage)
    }

    @Test func missingComponentIsUnknown() {
        // Claude Code component absent → unknown (not silently operational).
        let health = StatusHealth.from(summary([
            ("Claude API (api.anthropic.com)", "operational"),
        ]), config: .default)
        #expect(check(.claudeCode, in: health)?.status == .unknown)
        #expect(check(.claudeAPI, in: health)?.status == .operational)
    }

    @Test func ignoresUnrelatedComponents() {
        let health = StatusHealth.from(summary([
            ("Claude for Government", "major_outage"),
            ("Claude API (api.anthropic.com)", "operational"),
            ("Claude Code", "operational"),
            ("claude.ai", "operational"),
        ]), config: .default)
        #expect(health.worstProblem == nil)
    }

    @Test func emptySummaryYieldsUnknownForEnabledServices() {
        let health = StatusHealth.from(summary([]), config: .default)
        // Every enabled component resolves to unknown when the array is empty.
        #expect(check(.claudeAPI, in: health)?.status == .unknown)
        #expect(check(.claudeCode, in: health)?.status == .unknown)
        #expect(check(.webDesktop, in: health)?.status == .unknown)
    }
}

// MARK: - StatusHealth.unknown(for:)

@Suite("StatusHealth.unknown(for:)")
struct StatusHealthUnknownTests {

    @Test func allEnabledComponentsUnknown() {
        let health = StatusHealth.unknown(for: .default)
        #expect(health.checks.flatMap(\.components).allSatisfy { $0.status == .unknown })
    }

    @Test func respectsDisabledServices() {
        let config = MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: false)
        let health = StatusHealth.unknown(for: config)
        #expect(health.checks.map(\.id) == [.claudeAPI])
    }

    @Test func coworkComponentPresentInUnknownWhenModeAddsIt() {
        let config = MonitoredServices(webDesktopEnabled: true, webDesktopMode: .chatAndCowork)
        let health = StatusHealth.unknown(for: config)
        #expect(check(.webDesktop, in: health)?.components.map(\.name) == ["claude.ai", "Claude Cowork"])
    }

    @Test func worstProblemIsUnknownWhenAnyEnabled() {
        // A failed fetch still shows a (grey) dot — honest "don't know".
        #expect(StatusHealth.unknown(for: .default).worstProblem == .unknown)
    }
}

// MARK: - worstProblem (menu-bar dot), worst-of-all-enabled

@Suite("StatusHealth.worstProblem across enabled services")
struct StatusHealthWorstProblemTests {

    /// A health built from a summary at the default config, for concise worst-of-all assertions.
    private func health(api: String = "operational", code: String = "operational",
                        web: String = "operational") -> StatusHealth {
        StatusHealth.from(summary([
            ("Claude API (api.anthropic.com)", api),
            ("Claude Code", code),
            ("claude.ai", web),
        ]), config: .default)
    }

    @Test func allOperationalHasNoProblem() {
        #expect(health().worstProblem == nil)
    }

    @Test func oneDegradedSurfaces() {
        #expect(health(code: "degraded_performance").worstProblem == .degraded)
    }

    @Test func picksTheMostSevereAcrossServices() {
        // Claude Code degraded + WEB/Desktop major → major (worst-of-all, not per-service).
        #expect(health(code: "degraded_performance", web: "major_outage").worstProblem == .majorOutage)
    }

    @Test func severityOrdering() {
        // operational < underMaintenance < unknown < degraded < partialOutage < majorOutage
        #expect(health(api: "under_maintenance", code: "totally_unknown").worstProblem == .unknown)
        #expect(health(api: "totally_unknown", code: "degraded_performance").worstProblem == .degraded)
        #expect(health(code: "degraded_performance", web: "partial_outage").worstProblem == .partialOutage)
    }

    @Test func maintenanceCountsAsProblem() {
        #expect(health(web: "under_maintenance").worstProblem == .underMaintenance)
    }

    @Test func coworkProblemSurfacesOnlyInCoworkMode() {
        let components: [(String, String)] = [
            ("Claude API (api.anthropic.com)", "operational"),
            ("claude.ai", "operational"),
            ("Claude Cowork", "major_outage"),
        ]
        // Chat only → Cowork is not monitored, so its outage does not surface.
        let chatOnly = StatusHealth.from(summary(components),
            config: MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: true, webDesktopMode: .chatOnly))
        #expect(chatOnly.worstProblem == nil)
        // Chat and Cowork → the Cowork outage drives the dot.
        let cowork = StatusHealth.from(summary(components),
            config: MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: true, webDesktopMode: .chatAndCowork))
        #expect(cowork.worstProblem == .majorOutage)
    }

    @Test func claudeAPIProblemSurfacesEvenWithEverythingElseDisabled() {
        let health = StatusHealth.from(summary([("Claude API (api.anthropic.com)", "major_outage")]),
            config: MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: false))
        #expect(health.worstProblem == .majorOutage)
    }
}

// MARK: - Incidents are ignored (ADR-0013)

@Suite("Status incidents do not affect component state")
struct StatusIncidentsIgnoredTests {

    /// A real-shape summary where the tracked components are `operational` but an active `major`
    /// incident lists some (the Mythos/Fable suspension case). Decoding it and mapping must yield
    /// operational states — incidents are not decoded, so they cannot change the lines.
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
        let health = StatusHealth.from(summary, config: .default)

        #expect(health.worstProblem == nil)
        #expect(check(.claudeCode, in: health)?.status == .operational)
        #expect(check(.claudeAPI, in: health)?.status == .operational)
    }
}
