import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "now" — every age assertion is relative to this, never to the wall clock.
private let now = ResetClock.parse("2026-08-05T14:00:00Z")!

/// Component names, verbatim as the API emits them.
private let codeName = StatusHealth.claudeCodeComponentName
private let apiName = StatusHealth.claudeAPIComponentName
private let webName = StatusHealth.claudeWebComponentName
private let coworkName = StatusHealth.claudeCoworkComponentName

private func component(_ name: String, _ status: String) -> StatusComponent {
    StatusComponent(name: name, status: status)
}

private func incident(
    id: String = "inc1",
    name: String = "Degraded performance of multiple models",
    status: String = "identified",
    shortlink: String? = "https://stspg.io/m7w8kkf4tlqg",
    startedAt: String? = "2026-08-05T12:00:00.287Z",
    createdAt: String? = nil,
    components: [StatusComponent] = [],
    updates: [StatusIncidentUpdate] = []
) -> StatusIncident {
    StatusIncident(
        id: id, name: name, status: status, impact: "minor", shortlink: shortlink,
        startedAt: startedAt, createdAt: createdAt, resolvedAt: nil,
        components: components, incidentUpdates: updates)
}

private func summary(_ incidents: [StatusIncident], components: [StatusComponent] = []) -> StatusSummary {
    StatusSummary(components: components, incidents: incidents)
}

// MARK: - The green gate (ADR-0071 §4)

@Suite("IncidentVisibility — green components hide the incident")
struct IncidentGreenGateTests {

    @Test func degradedComponentsShowTheIncident() {
        let s = summary([incident(components: [component(codeName, "degraded_performance")])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now)
        #expect(visible.map(\.id) == ["inc1"])
        #expect(visible.first?.severity == .degraded)
    }

    /// The 66-minute case: the incident is still formally open (`monitoring`) but every monitored
    /// component is back to `operational`. The popup must show nothing at all.
    @Test func openIncidentWithGreenComponentsIsHidden() {
        let s = summary([incident(
            status: "monitoring",
            components: [component(codeName, "operational"), component(apiName, "operational")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).isEmpty)
    }

    /// Only *my* components matter: an incident degrading something unmonitored while my own
    /// component is green is not my problem.
    @Test func degradedOnlyOnUnmonitoredComponentIsHidden() {
        let s = summary([incident(components: [
            component(codeName, "operational"),
            component("Claude Console (platform.claude.com)", "major_outage"),
        ])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).isEmpty)
    }

    @Test func severityIsWorstOfMonitoredComponentsOnly() {
        // Cowork is unmonitored in the default config, so its outage must not raise the severity.
        let s = summary([incident(components: [
            component(codeName, "degraded_performance"),
            component(coworkName, "major_outage"),
        ])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).first?.severity == .degraded)
    }
}

// MARK: - The service filter (ADR-0071 §9)

@Suite("IncidentVisibility — filtered by monitored services")
struct IncidentServiceFilterTests {

    @Test func incidentNamingNoComponentsIsHidden() {
        // Cannot pass a filter it carries no data for.
        let s = summary([incident(components: [])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).isEmpty)
    }

    @Test func disablingTheServiceHidesItsIncident() {
        let s = summary([incident(components: [component(codeName, "major_outage")])])
        var config = MonitoredServices.default
        #expect(!IncidentVisibility.visible(in: s, config: config, now: now).isEmpty)

        config.claudeCodeEnabled = false
        #expect(IncidentVisibility.visible(in: s, config: config, now: now).isEmpty)
    }

    @Test func claudeAPIIsAlwaysMonitored() {
        // `Claude API` cannot be switched off — TokenPace's own polling depends on it.
        let s = summary([incident(components: [component(apiName, "partial_outage")])])
        let config = MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: false)
        #expect(IncidentVisibility.visible(in: s, config: config, now: now).count == 1)
    }

    @Test func coworkCountsOnlyInCoworkMode() {
        let s = summary([incident(components: [component(coworkName, "degraded_performance")])])
        let chatOnly = MonitoredServices(webDesktopEnabled: true, webDesktopMode: .chatOnly)
        #expect(IncidentVisibility.visible(in: s, config: chatOnly, now: now).isEmpty)

        let withCowork = MonitoredServices(webDesktopEnabled: true, webDesktopMode: .chatAndCowork)
        #expect(IncidentVisibility.visible(in: s, config: withCowork, now: now).count == 1)
    }
}

// MARK: - Closed incidents and age

@Suite("IncidentVisibility — closed and stale incidents")
struct IncidentClosedAndAgeTests {

    @Test(arguments: ["resolved", "postmortem"])
    func closedIncidentsAreDropped(stage: String) {
        // Degraded components would otherwise show it — the stage alone must drop it.
        let s = summary([incident(status: stage, components: [component(codeName, "major_outage")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).isEmpty)
    }

    @Test(arguments: ["investigating", "identified", "monitoring"])
    func openStagesAreKept(stage: String) {
        let s = summary([incident(status: stage, components: [component(codeName, "degraded_performance")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).count == 1)
    }

    @Test func anUnknownStageIsKeptAndCarriesItsRawValue() {
        // A stage this build has never seen must still render, not vanish.
        let s = summary([incident(status: "mitigating", components: [component(codeName, "degraded_performance")])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now)
        #expect(visible.first?.stage == .unknown("mitigating"))
    }

    @Test func olderThanMaxAgeIsDropped() {
        // Started 2h before `now`.
        let s = summary([incident(components: [component(codeName, "degraded_performance")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now, maxAge: 3 * 3600).count == 1)
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now, maxAge: 3600).isEmpty)
    }

    @Test func noMaxAgeKeepsEvenAZombie() {
        // The sample held one open for 2741 minutes.
        let s = summary([incident(
            startedAt: "2026-08-03T12:00:00Z",
            components: [component(codeName, "degraded_performance")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now, maxAge: nil).count == 1)
    }

    @Test func unparseableStartDateSurvivesTheAgeFilter() {
        // An unknown start is not evidence of being stale — keep it rather than silently hiding it.
        let s = summary([incident(
            startedAt: nil, createdAt: nil,
            components: [component(codeName, "degraded_performance")])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now, maxAge: 60)
        #expect(visible.count == 1)
        #expect(visible.first?.startedAt == nil)
        #expect(visible.first?.age(at: now) == nil)
    }
}

// MARK: - Row payload

@Suite("IncidentVisibility — what the row renders")
struct IncidentRowPayloadTests {

    @Test func ageComesFromStartedAtWithFractionalSeconds() {
        let s = summary([incident(components: [component(codeName, "degraded_performance")])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now).first
        // 12:00:00.287Z → 14:00:00Z is two hours; the fractional part must not defeat the parse.
        #expect(visible?.age(at: now) == TimeInterval(2 * 3600))
    }

    @Test func createdAtIsTheFallbackWhenStartedAtIsAbsent() {
        let s = summary([incident(
            startedAt: nil, createdAt: "2026-08-05T13:30:00.000Z",
            components: [component(codeName, "degraded_performance")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).first?.age(at: now) == TimeInterval(1800))
    }

    @Test func shortlinkBecomesAURL() {
        let s = summary([incident(components: [component(codeName, "degraded_performance")])])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).first?.shortlink
            == URL(string: "https://stspg.io/m7w8kkf4tlqg"))
    }

    @Test func aMalformedShortlinkDegradesToNoLink() {
        // Must cost the link, never the row.
        let s = summary([incident(shortlink: "", components: [component(codeName, "degraded_performance")])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now)
        #expect(visible.count == 1)
        #expect(visible.first?.shortlink == nil)
    }

    @Test func updateIDsAndLatestBodyAreCarried() {
        let s = summary([incident(
            components: [component(codeName, "degraded_performance")],
            updates: [
                StatusIncidentUpdate(id: "u1", status: "investigating", body: "We are investigating."),
                StatusIncidentUpdate(id: "u2", status: "identified", body: "A fix is being worked on."),
            ])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now).first
        #expect(visible?.updateIDs == ["u1", "u2"])
        #expect(visible?.latestUpdateBody == "A fix is being worked on.")
    }

    @Test func silentIncidentHasNoUpdateBody() {
        // Recovery is sometimes entirely silent — no updates at all.
        let s = summary([incident(components: [component(codeName, "degraded_performance")])])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now).first
        #expect(visible?.updateIDs.isEmpty == true)
        #expect(visible?.latestUpdateBody == nil)
    }
}

// MARK: - Several at once

@Suite("IncidentVisibility — simultaneous incidents")
struct SimultaneousIncidentsTests {

    /// The real 2026-08-05 14:00 shape: two open incidents listing the same degraded components.
    @Test func bothAreShownInApiOrder() {
        let shared = [component(codeName, "degraded_performance"), component(apiName, "degraded_performance")]
        let s = summary([
            incident(id: "first", name: "Degraded performance of multiple models", components: shared),
            incident(id: "second", name: "Degraded performance for Claude Opus 5", components: shared),
        ])
        #expect(IncidentVisibility.visible(in: s, config: .default, now: now).map(\.id) == ["first", "second"])
    }

    @Test func oneCanRecoverWhileTheOtherStaysBroken() {
        let s = summary([
            incident(id: "recovered", components: [component(codeName, "operational")]),
            incident(id: "ongoing", components: [component(codeName, "major_outage")]),
        ])
        let visible = IncidentVisibility.visible(in: s, config: .default, now: now)
        #expect(visible.map(\.id) == ["ongoing"])
        #expect(visible.first?.severity == .majorOutage)
    }
}

// MARK: - Anti-drift with the popup rows

@Suite("StatusHealth.monitoredComponentNames")
struct MonitoredComponentNamesTests {

    /// The names used to filter incidents must be exactly the ones the popup draws rows for — for
    /// every config permutation. Adding a service to `checks(for:)` must never silently fail here.
    @Test func matchesTheRowsForEveryConfig() {
        for code in [true, false] {
            for web in [true, false] {
                for mode in [WebDesktopMode.chatOnly, .chatAndCowork] {
                    let config = MonitoredServices(
                        claudeCodeEnabled: code, webDesktopEnabled: web, webDesktopMode: mode)
                    let fromRows = Set(StatusHealth.unknown(for: config).checks.flatMap(\.components).map(\.name))
                    #expect(StatusHealth.monitoredComponentNames(for: config) == fromRows)
                }
            }
        }
    }

    @Test func alwaysContainsClaudeAPI() {
        let config = MonitoredServices(claudeCodeEnabled: false, webDesktopEnabled: false)
        #expect(StatusHealth.monitoredComponentNames(for: config) == [apiName])
    }

    @Test func coworkAppearsOnlyInCoworkMode() {
        let chatOnly = MonitoredServices(webDesktopMode: .chatOnly)
        #expect(!StatusHealth.monitoredComponentNames(for: chatOnly).contains(coworkName))
        #expect(StatusHealth.monitoredComponentNames(for: chatOnly).contains(webName))

        let withCowork = MonitoredServices(webDesktopMode: .chatAndCowork)
        #expect(StatusHealth.monitoredComponentNames(for: withCowork).contains(coworkName))
    }
}
