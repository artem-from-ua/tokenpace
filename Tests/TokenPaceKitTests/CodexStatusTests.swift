import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Codex status provider (#503)

/// The decisions that would be expensive to re-derive: which endpoint the statuses come from, why
/// the incidents come from an undocumented one, why `updated_at` is not read, and what the
/// degradation costs when the undocumented endpoint is gone.
///
/// Driven by captured live bodies (``CodexFixtures``) rather than hand-written JSON — the shapes
/// here are somebody else's and a hand-written approximation would pass while the real feed failed.
@Suite("Codex status provider")
struct CodexStatusTests {

    private static let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func components() throws -> StatusSummary {
        try StatusClient.decode(from: Data(CodexFixtures.components.utf8))
    }

    private func incidents() throws -> CodexIncidentFeed {
        try CodexIncidentClient.decode(from: Data(CodexFixtures.proxyIncidents.utf8))
    }

    // MARK: the feed choice

    /// `components.json` carries `CLI`; `summary.json` cannot, because its components run `position`
    /// 0–24 and `CLI` sits at 29. The endpoint choice rests on this, so it is pinned rather than
    /// remembered.
    @Test func componentFeedCarriesCLIWhichTheSummaryCannot() throws {
        let summary = try components()
        #expect(summary.components.count == 34)
        let cli = try #require(summary.components.first { $0.name == "CLI" })
        #expect(cli.id != nil)
        // Everything at position 25 or above is invisible to `summary.json`, `CLI` included.
        let truncated = summary.components.filter { $0.name == "CLI" }
        #expect(truncated.count == 1)
    }

    /// `updated_at` is the same value on every component — the page's edit stamp, not a status
    /// change. Passing it through would render an age measured from an unrelated event.
    @Test func updatedAtIsIdenticalOnEveryComponentAndSoIsNeverAnAge() throws {
        let stamps = Set(try components().components.compactMap(\.updatedAt))
        #expect(stamps.count == 1)

        // And the mapping does not read it: with no `changedAt` supplied, every age is `nil`.
        let health = StatusHealth.fromCodex(try components(), config: .default)
        #expect(health.checks.flatMap(\.components).allSatisfy { $0.changedAt == nil })
    }

    // MARK: services

    @Test func fiveServicesMapOneToOneAndLoginAppearsNowhere() throws {
        let health = StatusHealth.fromCodex(try components(), config: .default)
        #expect(health.checks.count == 5)
        #expect(health.checks.allSatisfy { $0.components.count == 1 })
        #expect(health.checks.map(\.id) == [
            .codexAPI, .codexCLI, .codexVSCode, .codexWeb, .codexChatGPTDesktop,
        ])
        let names = Set(health.checks.flatMap(\.components).map(\.name))
        #expect(names == [
            "Codex API", "CLI", "VS Code extension", "Codex Web", "Codex in ChatGPT Desktop",
        ])
        #expect(!names.contains("Login"))
    }

    /// `Login` is excluded because the feed carries it **twice**, under two ids — an exact-name match
    /// would resolve to whichever copy the array lists first.
    @Test func loginAppearsTwiceInTheFeedUnderDifferentIDs() throws {
        let logins = try components().components.filter { $0.name == "Login" }
        #expect(logins.count == 2)
        #expect(Set(logins.compactMap(\.id)).count == 2)
    }

    @Test func aDisabledServiceContributesNothing() throws {
        var config = CodexMonitoring.default
        config.cliEnabled = false
        let health = StatusHealth.fromCodex(try components(), config: config)
        #expect(!health.checks.flatMap(\.components).contains { $0.name == "CLI" })
        #expect(health.checks.count == 4)
    }

    @Test func everythingOffYieldsNoChecksAndMonitorsNothing() throws {
        let config = CodexMonitoring(
            apiEnabled: false, cliEnabled: false, vsCodeEnabled: false, webEnabled: false,
            chatGPTDesktopEnabled: false)
        #expect(!config.isMonitoringAnything)
        #expect(StatusHealth.fromCodex(try components(), config: config).checks.isEmpty)
    }

    /// The quota switch is not a reason to poll a status page, so it does not make the provider
    /// "monitoring something".
    @Test func usageSwitchDoesNotMakeTheProviderMonitored() {
        let config = CodexMonitoring(
            apiEnabled: false, cliEnabled: false, vsCodeEnabled: false, webEnabled: false,
            chatGPTDesktopEnabled: false, usageEnabled: true)
        #expect(!config.isMonitoringAnything)
    }

    @Test func usageIsOffByDefaultWhileEveryStatusServiceIsOn() {
        let d = CodexMonitoring.default
        #expect(!d.usageEnabled)
        #expect(d.isMonitoringAnything)
        #expect(StatusHealth.monitoredCodexComponentNames(for: d).count == 5)
    }

    /// An absent key takes the default rather than failing the whole config — what lets a blob
    /// written by a build predating a key still load.
    @Test func decodingToleratesMissingKeys() throws {
        let config = try JSONDecoder().decode(
            CodexMonitoring.self, from: Data(#"{"cliEnabled":false}"#.utf8))
        #expect(!config.cliEnabled)
        #expect(config.apiEnabled)
        #expect(!config.usageEnabled)
    }

    // MARK: component-id resolution

    /// The join the incident feed needs: it names components by id, and every one of them resolves
    /// against `components.json`.
    @Test func everyIncidentComponentIDResolvesToAName() throws {
        let names = CodexStatusMapping.componentNames(in: try components())
        #expect(names.count == 34)
        var unknown: [String] = []
        for incident in try incidents().incidents {
            for affected in incident.affectedComponents where names[affected.componentID] == nil {
                unknown.append(affected.componentID)
            }
            for impact in incident.componentImpacts where names[impact.componentID] == nil {
                unknown.append(impact.componentID)
            }
        }
        #expect(unknown.isEmpty)
    }

    // MARK: incident filtering

    /// Filtering is exact: an incident naming only `Codex API` reaches the plate, and one naming only
    /// `Sora` does not.
    @Test func onlyIncidentsTouchingMonitoredComponentsAreVisible() throws {
        let summary = try components()
        let names = CodexStatusMapping.componentNames(in: summary)
        let feed = try incidents()
        // The fixture's incidents are all `resolved`, so re-stage them as open — the stage gate is
        // tested separately and would otherwise drop every case before the component filter runs.
        let open = CodexIncidentFeed(incidents: feed.incidents.map {
            CodexIncident(
                id: $0.id, name: $0.name, status: "investigating", publishedAt: $0.publishedAt,
                affectedComponents: $0.affectedComponents.map {
                    // `current_status` is what decides whether the incident still hurts, and every
                    // captured one has recovered — restage it to the status it drove them to.
                    CodexAffectedComponent(
                        componentID: $0.componentID, status: $0.status, currentStatus: $0.status)
                },
                componentImpacts: $0.componentImpacts, updates: $0.updates)
        })
        let visible = CodexStatusMapping.visibleIncidents(
            in: open, componentNames: names,
            monitoredComponentNames: StatusHealth.monitoredCodexComponentNames(for: .default),
            now: Self.now)
        let titles = Set(visible.map(\.name))
        #expect(titles.contains("Elevated Codex API authentication errors"))
        #expect(titles.contains("Some users are unable to access Codex"))
        // Neither of these touches a Codex component.
        #expect(!titles.contains("Elevated Errors for Sora API"))
        #expect(!titles.contains("Unexpected logouts for some ChatGPT web users"))
    }

    /// A closed incident never reaches the plate — which is why the fixture, whose incidents are all
    /// `resolved`, yields nothing until it is restaged.
    @Test func resolvedIncidentsAreDropped() throws {
        let names = CodexStatusMapping.componentNames(in: try components())
        let visible = CodexStatusMapping.visibleIncidents(
            in: try incidents(), componentNames: names,
            monitoredComponentNames: StatusHealth.monitoredCodexComponentNames(for: .default),
            now: Self.now)
        #expect(visible.isEmpty)
    }

    /// The proxy has no `shortlink`, so a Codex incident row carries no external link — recorded so
    /// the missing link reads as the feed's limit rather than as a bug.
    @Test func codexIncidentsCarryNoShortlink() throws {
        let names = CodexStatusMapping.componentNames(in: try components())
        let source = try #require(try incidents().incidents.first {
            $0.name == "Elevated Codex API authentication errors"
        })
        let open = CodexIncidentFeed(incidents: [
            CodexIncident(
                id: source.id, name: source.name, status: "investigating",
                publishedAt: source.publishedAt,
                affectedComponents: source.affectedComponents.map {
                    CodexAffectedComponent(
                        componentID: $0.componentID, status: $0.status, currentStatus: $0.status)
                },
                componentImpacts: source.componentImpacts, updates: source.updates),
        ])
        let visible = CodexStatusMapping.visibleIncidents(
            in: open, componentNames: names,
            monitoredComponentNames: StatusHealth.monitoredCodexComponentNames(for: .default),
            now: Self.now)
        #expect(visible.count == 1)
        #expect(visible[0].shortlink == nil)
        #expect(visible[0].startedAt != nil)
        #expect(visible[0].latestUpdateBody != nil)
    }

    // MARK: the proxy's own status vocabulary

    /// `full_outage` is the one word this page uses where Statuspage says `major_outage`. A shared
    /// mapper would bucket it to `.unknown` — visibly milder than an outage.
    @Test func fullOutageMapsToMajorOutage() {
        #expect(CodexStatusMapping.serviceStatus(fromProxy: "full_outage") == .majorOutage)
        #expect(CodexStatusMapping.serviceStatus(fromProxy: "degraded_performance") == .degraded)
        #expect(CodexStatusMapping.serviceStatus(fromProxy: "partial_outage") == .partialOutage)
        #expect(CodexStatusMapping.serviceStatus(fromProxy: "operational") == .operational)
        #expect(CodexStatusMapping.serviceStatus(fromProxy: "something_new") == .unknown)
    }

    /// The captured feed really does contain `full_outage` and never `major_outage` — the measurement
    /// the mapping above rests on.
    @Test func theCapturedFeedUsesFullOutageAndNeverMajorOutage() throws {
        let words = Set(try incidents().incidents.flatMap { $0.affectedComponents.map(\.status) })
        #expect(words.contains("full_outage"))
        #expect(!words.contains("major_outage"))
    }

    // MARK: age from the incident feed

    /// The age comes from an **open** `component_impacts[].start_at`. A closed impact describes a
    /// state the component has already left, so dating the current state from it would be wrong.
    @Test func ageComesFromOpenImpactsOnly() throws {
        let names = CodexStatusMapping.componentNames(in: try components())
        let cliID = try #require(names.first { $0.value == "CLI" }?.key)
        let closed = Date(timeIntervalSince1970: 1_786_000_000)
        let open = Date(timeIntervalSince1970: 1_786_900_000)

        let feed = CodexIncidentFeed(incidents: [
            CodexIncident(
                id: "a", name: "over", status: "resolved",
                componentImpacts: [CodexComponentImpact(
                    componentID: cliID, status: "degraded_performance",
                    startAt: ResetClock.isoString(from: closed),
                    endAt: ResetClock.isoString(from: Self.now))]),
            CodexIncident(
                id: "b", name: "live", status: "investigating",
                componentImpacts: [CodexComponentImpact(
                    componentID: cliID, status: "degraded_performance",
                    startAt: ResetClock.isoString(from: open), endAt: nil)]),
        ])
        let ages = CodexStatusMapping.changedAt(in: feed, componentNames: names)
        #expect(ages["CLI"] == open)
    }

    @Test func noOpenImpactMeansNoAge() throws {
        let names = CodexStatusMapping.componentNames(in: try components())
        #expect(CodexStatusMapping.changedAt(in: try incidents(), componentNames: names).isEmpty)
    }

    /// The age reaches the rendered component, which is the whole point of the lookup.
    @Test func theAgeReachesTheResolvedComponent() throws {
        let when = Date(timeIntervalSince1970: 1_786_900_000)
        let health = StatusHealth.fromCodex(try components(), config: .default) { name in
            name == "CLI" ? when : nil
        }
        let cli = try #require(health.checks.flatMap(\.components).first { $0.name == "CLI" })
        #expect(cli.changedAt == when)
        #expect(cli.stateAge(at: Self.now) == Self.now.timeIntervalSince(when))
        let api = try #require(health.checks.flatMap(\.components).first { $0.name == "Codex API" })
        #expect(api.stateAge(at: Self.now) == nil)
    }

    // MARK: degradation

    /// The failure that matters: with the incident feed gone, statuses still render and only the
    /// incident rows disappear. The two come from different requests, which is what makes it possible.
    @Test func losingTheIncidentFeedCostsRowsAndNotStatuses() throws {
        let health = StatusHealth.fromCodex(try components(), config: .default)
        #expect(health.checks.count == 5)
        #expect(health.aggregate(of: .codex) == .operational)
        // No feed → no ages and no incidents, and neither greys a single row.
        #expect(health.checks.flatMap(\.components).allSatisfy { $0.status != .unknown })
    }

    /// A shape change at the undocumented endpoint degrades like an outage rather than crashing the
    /// poll — the property that keeps the statuses alive when the page's frontend is rewritten.
    @Test func anUnparseableIncidentBodyThrowsDecodeRatherThanCrashing() {
        #expect(throws: StatusFetchError.decode) {
            try CodexIncidentClient.decode(from: Data(#"{"incidents":[{"nope":1}]}"#.utf8))
        }
    }

    /// An absent `incidents` array is not an error — the same hardening `StatusSummary` applies.
    @Test func anEmptyIncidentBodyDecodesToNoIncidents() throws {
        #expect(try CodexIncidentClient.decode(from: Data("{}".utf8)).incidents.isEmpty)
    }

    @Test func failedPollGreysExactlyTheMonitoredComponents() {
        var config = CodexMonitoring.default
        config.webEnabled = false
        let health = StatusHealth.unknownCodex(for: config)
        #expect(health.checks.count == 4)
        #expect(health.checks.flatMap(\.components).allSatisfy { $0.status == .unknown })
        #expect(health.worstProblem(of: .codex) == .unknown)
    }

    // MARK: routing

    @Test func codexRowsLinkToOpenAIsPage() {
        for service in StatusHealth.codexServices {
            #expect(StatusHealth.pageURL(for: service.id) == StatusHealth.codexPageURL)
        }
        #expect(StatusHealth.pageURL(for: .claudeAPI) == StatusHealth.pageURL)
        #expect(StatusHealth.pageURL(for: .githubDevelopment) == StatusHealth.githubPageURL)
    }

    /// The statuses come from `components.json`, never from the truncated summary.
    @Test func theComponentEndpointIsNotTheSummaryEndpoint() {
        #expect(StatusHealth.codexEndpoint.path == "/api/v2/components.json")
        #expect(!StatusHealth.codexEndpoint.absoluteString.contains("summary"))
        #expect(StatusHealth.codexIncidentsEndpoint.absoluteString.contains("/proxy/"))
        #expect(StatusHealth.codexIncidentsFallbackEndpoint.path == "/api/v2/incidents.json")
    }
}
