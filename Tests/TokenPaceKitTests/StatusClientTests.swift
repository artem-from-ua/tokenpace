import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A realistic status summary body (trimmed to the keys we model plus a few we deliberately ignore:
/// `page`, `status`, `incidents`). Proves the extra keys decode without error and are dropped.
private let realSummaryJSON = """
{"page":{"id":"tymt9n04zgry","name":"Claude"},
 "status":{"indicator":"none","description":"All Systems Operational"},
 "components":[
   {"id":"a","name":"claude.ai","status":"operational"},
   {"id":"b","name":"Claude Console (platform.claude.com)","status":"operational"},
   {"id":"c","name":"Claude API (api.anthropic.com)","status":"operational"},
   {"id":"d","name":"Claude Code","status":"operational"}],
 "incidents":[],
 "scheduled_maintenances":[]}
""".data(using: .utf8)!

/// A summary carrying two simultaneous incidents, trimmed verbatim from a captured
/// `status.claude.com` payload (2026-08-05, incidents `f6gkkq6txl7z` + `mgp99sn4ynd4`).
///
/// Preserved from the real shape because each detail is load-bearing: the fractional-second
/// timestamps (`.287Z`), `components[]` **inside** the incident mirroring the top-level statuses,
/// per-component `updated_at`, and an incident whose `resolved_at` is `null` while it is open.
private let twoIncidentsJSON = """
{"page":{"id":"tymt9n04zgry","name":"Claude"},
 "components":[
   {"id":"a","name":"claude.ai","status":"degraded_performance","updated_at":"2026-08-05T13:51:30.346Z"},
   {"id":"c","name":"Claude API (api.anthropic.com)","status":"degraded_performance","updated_at":"2026-08-05T13:51:30.362Z"},
   {"id":"d","name":"Claude Code","status":"degraded_performance","updated_at":"2026-08-05T13:51:30.376Z"}],
 "incidents":[
   {"id":"mgp99sn4ynd4","name":"Degraded performance for Claude Opus 5","status":"identified",
    "created_at":"2026-08-05T13:51:30.287Z","updated_at":"2026-08-05T13:51:30.436Z",
    "monitoring_at":null,"resolved_at":null,"impact":"minor",
    "shortlink":"https://stspg.io/m7w8kkf4tlqg","started_at":"2026-08-05T13:51:30.277Z",
    "incident_updates":[
      {"id":"nk86fbj1n63l","status":"identified",
       "body":"We have identified the cause of elevated errors on requests to Claude Opus 5.",
       "created_at":"2026-08-05T13:51:30.433Z","deliver_notifications":true,
       "affected_components":[{"code":"d","name":"Claude Code","old_status":"operational","new_status":"degraded_performance"}]}],
    "components":[
      {"id":"d","name":"Claude Code","status":"degraded_performance","updated_at":"2026-08-05T13:51:30.376Z"}]},
   {"id":"f6gkkq6txl7z","name":"Degraded performance of multiple models","status":"monitoring",
    "created_at":"2026-08-05T07:05:54.000Z","resolved_at":null,"impact":"minor",
    "shortlink":"https://stspg.io/s2ysk4zxbyy3","started_at":"2026-08-05T07:05:54.000Z",
    "incident_updates":[
      {"id":"upd-old","status":"investigating","body":"We are investigating.","created_at":"2026-08-05T07:06:00.000Z"},
      {"id":"upd-new","status":"monitoring","body":"A fix has been deployed.","created_at":"2026-08-05T13:08:34.000Z"}],
    "components":[]}],
 "scheduled_maintenances":[]}
""".data(using: .utf8)!

/// Stub transport returning a canned result for the status endpoint — no live network.
private struct StubStatusTransport: UsageTransport {
    let result: Result<(Data, URLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try result.get()
    }

    static func http(_ status: Int, body: Data = Data()) -> StubStatusTransport {
        let response = HTTPURLResponse(
            url: StatusClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return StubStatusTransport(result: .success((body, response)))
    }

    static func failing(_ error: Error) -> StubStatusTransport {
        StubStatusTransport(result: .failure(error))
    }

    static func nonHTTP() -> StubStatusTransport {
        let response = URLResponse(
            url: StatusClient.endpoint, mimeType: "application/json",
            expectedContentLength: 0, textEncodingName: nil)
        return StubStatusTransport(result: .success((Data(), response)))
    }
}

// MARK: - buildRequest

@Suite("StatusClient.buildRequest")
struct StatusBuildRequestTests {

    @Test func hitsTheSummaryEndpoint() {
        #expect(StatusClient.buildRequest().url == StatusClient.endpoint)
        #expect(StatusClient.endpoint.absoluteString == "https://status.claude.com/api/v2/summary.json")
    }

    @Test func carriesUserAgent() {
        let ua = StatusClient.buildRequest().value(forHTTPHeaderField: "User-Agent")
        #expect(ua == "claude-code/\(TokenPaceKit.version)")
    }

    @Test func isAGet() {
        #expect(StatusClient.buildRequest().httpMethod == "GET")
    }
}

// MARK: - decode

@Suite("StatusClient.decode")
struct StatusDecodeTests {

    @Test func decodesComponentsAndIgnoresExtraKeys() throws {
        let summary = try StatusClient.decode(from: realSummaryJSON)
        #expect(summary.components.count == 4)
        #expect(summary.components.contains(StatusComponent(name: "Claude Code", status: "operational")))
    }

    @Test func malformedBodyThrowsDecode() {
        #expect(throws: StatusFetchError.decode) {
            try StatusClient.decode(from: "not json".data(using: .utf8)!)
        }
    }

    @Test func absentComponentsDecodeToEmpty() throws {
        let summary = try StatusClient.decode(from: #"{"status":{"indicator":"none"}}"#.data(using: .utf8)!)
        #expect(summary.components.isEmpty)
    }

    @Test func wrongComponentShapeThrowsDecode() {
        // `components` present but an element is missing `status` → DecodingError → .decode.
        let body = #"{"components":[{"name":"Claude Code"}]}"#.data(using: .utf8)!
        #expect(throws: StatusFetchError.decode) {
            try StatusClient.decode(from: body)
        }
    }

    @Test func componentCarriesUpdatedAt() throws {
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        let code = try #require(summary.components.first { $0.name == "Claude Code" })
        #expect(code.updatedAt == "2026-08-05T13:51:30.376Z")
        // The age the popup shows is `now - updatedAt`, so the string must survive into a `Date`.
        #expect(ResetClock.parse(code.updatedAt) != nil)
    }

    @Test func componentWithoutUpdatedAtStillDecodes() throws {
        // `realSummaryJSON` predates the field entirely — a missing `updated_at` must not fail.
        let summary = try StatusClient.decode(from: realSummaryJSON)
        #expect(summary.components.allSatisfy { $0.updatedAt == nil })
    }
}

// MARK: - incidents (#279)

@Suite("StatusSummary.incidents")
struct StatusIncidentDecodeTests {

    @Test func decodesBothIncidents() throws {
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        #expect(summary.incidents.map(\.id) == ["mgp99sn4ynd4", "f6gkkq6txl7z"])
        #expect(summary.incidents.map(\.status) == ["identified", "monitoring"])
    }

    @Test func decodesTheFieldsTheRowNeeds() throws {
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        let incident = try #require(summary.incidents.first)
        #expect(incident.name == "Degraded performance for Claude Opus 5")
        #expect(incident.shortlink == "https://stspg.io/m7w8kkf4tlqg")
        #expect(incident.impact == "minor")
        // The row's age comes from `started_at`, and Statuspage emits fractional seconds.
        #expect(ResetClock.parse(incident.startedAt) != nil)
    }

    @Test func openIncidentHasNoResolvedAt() throws {
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        #expect(summary.incidents.allSatisfy { $0.resolvedAt == nil })
    }

    @Test func decodesUpdatesInApiOrder() throws {
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        let multiModel = try #require(summary.incidents.first { $0.id == "f6gkkq6txl7z" })
        #expect(multiModel.incidentUpdates.map(\.id) == ["upd-old", "upd-new"])
        #expect(multiModel.incidentUpdates.last?.body == "A fix has been deployed.")
    }

    @Test func incidentComponentsMirrorLiveStatus() throws {
        // Not a snapshot of "how it was when the incident opened" — the same status as the
        // top-level array. `IncidentVisibility` leans on this to gate green incidents.
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        let opus = try #require(summary.incidents.first { $0.id == "mgp99sn4ynd4" })
        #expect(opus.components.map(\.status) == ["degraded_performance"])
    }

    @Test func emptyIncidentComponentsDecodeToEmpty() throws {
        let summary = try StatusClient.decode(from: twoIncidentsJSON)
        let multiModel = try #require(summary.incidents.first { $0.id == "f6gkkq6txl7z" })
        #expect(multiModel.components.isEmpty)
    }

    @Test func absentIncidentsDecodeToEmpty() throws {
        // The all-clear payload carries `"incidents":[]`; a summary omitting the key entirely must
        // behave the same rather than failing and greying out every service line.
        #expect(try StatusClient.decode(from: realSummaryJSON).incidents.isEmpty)
        let noKey = #"{"components":[{"name":"Claude Code","status":"operational"}]}"#.data(using: .utf8)!
        #expect(try StatusClient.decode(from: noKey).incidents.isEmpty)
    }

    @Test func incidentMissingSubArraysStillDecodes() throws {
        let body = """
        {"components":[],"incidents":[{"id":"x","name":"Something","status":"investigating"}]}
        """.data(using: .utf8)!
        let incident = try #require(try StatusClient.decode(from: body).incidents.first)
        #expect(incident.components.isEmpty)
        #expect(incident.incidentUpdates.isEmpty)
        #expect(incident.shortlink == nil)
    }

    @Test func incidentMissingRequiredFieldThrowsDecode() {
        // `id`/`name`/`status` are the row's substance — an incident without them is not a row.
        let body = #"{"components":[],"incidents":[{"id":"x","status":"investigating"}]}"#.data(using: .utf8)!
        #expect(throws: StatusFetchError.decode) {
            try StatusClient.decode(from: body)
        }
    }
}

// MARK: - fetch

@Suite("StatusClient.fetch")
struct StatusFetchTests {

    @Test func success200ReturnsSummary() async throws {
        let summary = try await StatusClient.fetch(transport: StubStatusTransport.http(200, body: realSummaryJSON))
        #expect(summary.components.count == 4)
    }

    @Test func non200ThrowsDecode() async {
        await #expect(throws: StatusFetchError.decode) {
            _ = try await StatusClient.fetch(transport: StubStatusTransport.http(503))
        }
    }

    @Test func transportErrorThrowsTransport() async {
        let stub = StubStatusTransport.failing(URLError(.notConnectedToInternet))
        await #expect(throws: StatusFetchError.self) {
            _ = try await StatusClient.fetch(transport: stub)
        }
    }

    @Test func nonHTTPResponseThrowsTransport() async {
        await #expect(throws: StatusFetchError.self) {
            _ = try await StatusClient.fetch(transport: StubStatusTransport.nonHTTP())
        }
    }
}
