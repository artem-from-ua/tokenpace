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
