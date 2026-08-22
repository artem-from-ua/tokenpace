import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Helpers

/// A GitHub summary with every component `operational`, overriding the named ones.
///
/// Built from the **real** feed captured from `githubstatus.com`: the five monitored components plus
/// the seven we ignore, including the non-service row literally named `Visit www.githubstatus.com
/// for more information`. The junk row is here on purpose — it is what proves exact-name matching
/// needs no filter.
private func githubSummary(_ overrides: [String: String] = [:]) -> StatusSummary {
    let all = StatusHealth.githubDevelopmentComponentNames + [
        "Webhooks", "Packages", "Pages", "Copilot", "Codespaces",
        "Copilot AI Model Providers",
        "Visit www.githubstatus.com for more information",
    ]
    return StatusSummary(components: all.map {
        StatusComponent(name: $0, status: overrides[$0] ?? "operational")
    })
}

private func claudeSummary(_ overrides: [String: String] = [:]) -> StatusSummary {
    let all = [
        StatusHealth.claudeAPIComponentName,
        StatusHealth.claudeCodeComponentName,
        StatusHealth.claudeWebComponentName,
    ]
    return StatusSummary(components: all.map {
        StatusComponent(name: $0, status: overrides[$0] ?? "operational")
    })
}

private func service(_ id: ServiceID, in health: StatusHealth) -> ServiceCheck? {
    health.checks.first { $0.id == id }
}

// MARK: - GitHub provider

@Suite("StatusHealth — GitHub provider (#454)")
struct StatusHealthGitHubTests {

    private let on = GitHubMonitoring(developmentServicesEnabled: true)
    private let off = GitHubMonitoring(developmentServicesEnabled: false)

    @Test func theGroupResolvesAllFiveNamesInDisplayOrder() {
        let health = StatusHealth.fromGitHub(githubSummary(), config: on)
        #expect(health.checks.map(\.id) == [.githubDevelopment])
        #expect(service(.githubDevelopment, in: health)?.components.map(\.name) == [
            "Git Operations", "API Requests", "Issues", "Pull Requests", "Actions",
        ])
    }

    @Test func nothingOutsideTheGroupIsSelected() {
        let names = StatusHealth.fromGitHub(githubSummary(), config: on)
            .checks.flatMap(\.components).map(\.name)
        #expect(names.count == 5)
        #expect(!names.contains { $0.hasPrefix("Visit ") })
        #expect(!names.contains("Copilot"))
        #expect(!names.contains("Packages"))
    }

    @Test func theGroupAggregatesWorstOfFive() {
        let degraded = StatusHealth.fromGitHub(
            githubSummary(["Actions": "degraded_performance"]), config: on)
        #expect(service(.githubDevelopment, in: degraded)?.status == .degraded)

        let worse = StatusHealth.fromGitHub(
            githubSummary(["Actions": "degraded_performance", "Git Operations": "major_outage"]),
            config: on)
        #expect(service(.githubDevelopment, in: worse)?.status == .majorOutage)
    }

    @Test func aMissingComponentIsUnknownNotOperational() {
        // GitHub renames or drops a component: it degrades to `unknown`, never to a false green.
        let partial = StatusSummary(components: [StatusComponent(name: "Issues", status: "operational")])
        let health = StatusHealth.fromGitHub(partial, config: on)
        let statuses = service(.githubDevelopment, in: health)?.components.map(\.status)
        #expect(statuses?.filter { $0 == .unknown }.count == 4)
        #expect(service(.githubDevelopment, in: health)?.status == .unknown)
    }

    @Test func disabledYieldsNothing() {
        #expect(StatusHealth.fromGitHub(githubSummary(), config: off).checks.isEmpty)
        #expect(StatusHealth.unknownGitHub(for: off).checks.isEmpty)
        #expect(StatusHealth.monitoredGitHubComponentNames(for: off).isEmpty)
    }

    @Test func monitoredNamesMatchTheRenderedChecks() {
        // The join key `IncidentVisibility` uses must stay pinned to what the popup renders — the
        // same invariant the Claude suite asserts, extended to GitHub.
        let names = StatusHealth.monitoredGitHubComponentNames(for: on)
        let rendered = Set(StatusHealth.fromGitHub(githubSummary(), config: on)
            .checks.flatMap(\.components).map(\.name))
        #expect(names == rendered)
        #expect(names.count == 5)
    }

    @Test func aFailedFetchGreysEveryComponent() {
        #expect(StatusHealth.unknownGitHub(for: on).checks.flatMap(\.components)
            .allSatisfy { $0.status == .unknown })
    }

    @Test func serviceIDsCarryTheirProvider() {
        #expect(ServiceID.claudeAPI.provider == .claude)
        #expect(ServiceID.claudeCode.provider == .claude)
        #expect(ServiceID.webDesktop.provider == .claude)
        #expect(ServiceID.githubDevelopment.provider == .github)
    }

    @Test func eachProviderLinksToItsOwnStatusPage() {
        #expect(StatusHealth.pageURL(for: .claudeCode) == StatusHealth.pageURL)
        #expect(StatusHealth.pageURL(for: .githubDevelopment).absoluteString
            == "https://www.githubstatus.com")
    }
}

// MARK: - Two providers merged

@Suite("StatusHealth — two providers merged (#454)")
struct StatusHealthMergeTests {

    private let githubOn = GitHubMonitoring(developmentServicesEnabled: true)

    private func claude(_ overrides: [String: String] = [:]) -> StatusHealth {
        StatusHealth.from(claudeSummary(overrides), config: .default)
    }

    private func github(_ overrides: [String: String] = [:]) -> StatusHealth {
        StatusHealth.fromGitHub(githubSummary(overrides), config: githubOn)
    }

    @Test func mergeKeepsBothProvidersWithClaudeFirst() {
        let merged = claude().merging(github())
        #expect(merged.checks.map(\.id.provider) == [.claude, .claude, .claude, .github])
        #expect(merged.monitors(.claude))
        #expect(merged.monitors(.github))
    }

    @Test func mergingIsIdempotent() {
        let g = github()
        let once = claude().merging(g)
        #expect(once.merging(g) == once)
    }

    @Test func aPollReplacesOnlyItsOwnProvidersChecks() {
        let merged = claude().merging(github(["Actions": "major_outage"]))
        #expect(merged.aggregate(of: .github) == .majorOutage)

        // A later healthy GitHub poll supersedes the outage and leaves Claude alone.
        let recovered = merged.merging(github())
        #expect(recovered.aggregate(of: .github) == .operational)
        #expect(recovered.checks(of: .claude).count == 3)
    }

    @Test func aFailedPollGreysOnlyItsOwnProvider() {
        let merged = claude().merging(github())
            .merging(StatusHealth.unknownGitHub(for: githubOn))
        #expect(merged.aggregate(of: .github) == .unknown)
        #expect(merged.aggregate(of: .claude) == .operational)
    }

    @Test func perProviderAggregatesAreIsolated() {
        let merged = claude([StatusHealth.claudeCodeComponentName: "major_outage"]).merging(github())
        #expect(merged.aggregate(of: .claude) == .majorOutage)
        #expect(merged.aggregate(of: .github) == .operational)
        // The menu bar still reads worst-of-all.
        #expect(merged.worstProblem == .majorOutage)
    }

    @Test func aCalmProviderReportsOperationalRatherThanSilence() {
        // The header dot's reason for existing: a calm provider says "healthy" out loud, unlike
        // `worstProblem`, which answers a calm state with `nil`.
        let merged = claude().merging(github())
        #expect(merged.aggregate(of: .github) == .operational)
        #expect(merged.worstProblem(of: .github) == nil)
        #expect(merged.worstProblem == nil)
    }

    @Test func anUnmonitoredProviderHasNoAggregate() {
        let claudeOnly = claude()
        #expect(claudeOnly.aggregate(of: .github) == nil)
        #expect(!claudeOnly.monitors(.github))
    }

    @Test func oneProvidersIncidentDoesNotAccelerateTheOthersCadence() {
        // #455's problem floor reads a per-provider signal; feeding it worst-of-all would poll a
        // third-party page every 60 s because the *other* provider is down.
        let merged = claude([StatusHealth.claudeCodeComponentName: "major_outage"]).merging(github())
        #expect(merged.worstProblem(of: .claude) == .majorOutage)
        #expect(merged.worstProblem(of: .github) == nil)
    }

    @Test func aGitHubOnlyConfigurationIsRepresentable() {
        // Every Claude switch off, GitHub on — reachable, and the health must carry GitHub alone
        // rather than reading as "nothing is monitored" (#454 §2a).
        let githubOnly = StatusHealth(checks: []).merging(github())
        #expect(githubOnly.monitors(.github))
        #expect(!githubOnly.monitors(.claude))
        #expect(githubOnly.aggregate(of: .github) == .operational)
        #expect(!githubOnly.checks.isEmpty)
    }
}

// MARK: - GitHubMonitoring config

@Suite("GitHubMonitoring")
struct GitHubMonitoringTests {

    @Test func defaultsToOff() {
        #expect(GitHubMonitoring.default.developmentServicesEnabled == false)
        #expect(GitHubMonitoring.default.isMonitoringAnything == false)
    }

    @Test func roundTripsThroughJSON() throws {
        let config = GitHubMonitoring(developmentServicesEnabled: true)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(GitHubMonitoring.self, from: data) == config)
    }

    @Test func anEmptyBlobDecodesToTheDefault() throws {
        // A blob written by a build that predates a future key must not fail the whole config.
        let data = Data("{}".utf8)
        #expect(try JSONDecoder().decode(GitHubMonitoring.self, from: data) == .default)
    }
}
