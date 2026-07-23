import Testing
import Foundation
@testable import TokenPaceKit

@Suite("GitHubReleaseDecoder.decode")
struct GitHubReleaseDecodeTests {

    /// A trimmed but realistic `/releases/latest` payload with extra keys the model must ignore.
    private static let realistic = Data("""
    {
      "url": "https://api.github.com/repos/artem-from-ua/tokenpace/releases/1",
      "html_url": "https://github.com/artem-from-ua/tokenpace/releases/tag/v0.20.0",
      "id": 1,
      "tag_name": "v0.20.0",
      "name": "TokenPace v0.20.0",
      "draft": false,
      "prerelease": false,
      "body": "notes",
      "assets": []
    }
    """.utf8)

    @Test func decodesTagAndURL() throws {
        let release = try GitHubReleaseDecoder.decode(from: Self.realistic)
        #expect(release.tagName == "v0.20.0")
        #expect(release.htmlURL == "https://github.com/artem-from-ua/tokenpace/releases/tag/v0.20.0")
    }

    @Test func ignoresUnknownKeys() throws {
        // The realistic fixture is full of unmodeled keys; decoding must not fail on them.
        let release = try GitHubReleaseDecoder.decode(from: Self.realistic)
        #expect(release == GitHubRelease(
            tagName: "v0.20.0",
            htmlURL: "https://github.com/artem-from-ua/tokenpace/releases/tag/v0.20.0"))
    }

    @Test func missingTagNameThrowsDecode() {
        let noTag = Data(#"{"html_url": "https://example.com"}"#.utf8)
        #expect(throws: GitHubReleaseDecodeError.decode) {
            try GitHubReleaseDecoder.decode(from: noTag)
        }
    }

    @Test func malformedJSONThrowsDecode() {
        let garbage = Data("not json".utf8)
        #expect(throws: GitHubReleaseDecodeError.decode) {
            try GitHubReleaseDecoder.decode(from: garbage)
        }
    }
}

// MARK: - Stub fetcher

/// A canned ``UpdateFetcher`` for `checkForUpdate` tests — no network, no process.
private struct StubFetcher: UpdateFetcher {
    let result: Result<Data, UpdateFetchError>
    func fetchLatestReleaseJSON() async throws -> Data {
        try result.get()
    }
}

private func releaseJSON(tag: String) -> Data {
    Data(#"{"tag_name": "\#(tag)", "html_url": "https://example.com/\#(tag)"}"#.utf8)
}

@Suite("GitHubReleaseClient.checkForUpdate")
struct GitHubReleaseClientTests {

    @Test func returnsReleaseWhenNewer() async {
        let fetcher = StubFetcher(result: .success(releaseJSON(tag: "v0.20.0")))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release?.tagName == "v0.20.0")
    }

    @Test func nilWhenEqual() async {
        let fetcher = StubFetcher(result: .success(releaseJSON(tag: "v0.18.0")))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release == nil)
    }

    @Test func nilWhenOlder() async {
        let fetcher = StubFetcher(result: .success(releaseJSON(tag: "v0.17.0")))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release == nil)
    }

    @Test func nilOnNotFound() async {
        // The private-repo anonymous case: a 404 degrades to "no update", never an error.
        let fetcher = StubFetcher(result: .failure(.notFound))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release == nil)
    }

    @Test func nilOnTransportError() async {
        let fetcher = StubFetcher(result: .failure(.transport("offline")))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release == nil)
    }

    @Test func nilOnUnavailable() async {
        // The gh-path "binary missing / non-zero exit" case.
        let fetcher = StubFetcher(result: .failure(.unavailable("gh not found")))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release == nil)
    }

    @Test func nilOnGarbageBody() async {
        let fetcher = StubFetcher(result: .success(Data("not json".utf8)))
        let release = await GitHubReleaseClient.checkForUpdate(using: fetcher, currentVersion: "0.18.0")
        #expect(release == nil)
    }
}

@Suite("GitHubReleaseClient.buildRequest")
struct GitHubReleaseClientRequestTests {

    @Test func hasTokenPaceUserAgent() {
        let request = GitHubReleaseClient.buildRequest()
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TokenPace/\(TokenPaceKit.version)")
    }

    @Test func hasGitHubAcceptHeader() {
        let request = GitHubReleaseClient.buildRequest()
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test func targetsLatestReleaseEndpoint() {
        #expect(GitHubReleaseClient.endpoint.absoluteString
            == "https://api.github.com/repos/artem-from-ua/tokenpace/releases/latest")
    }

    @Test func hasNoAuthorizationHeader() {
        // The anonymous path must not carry auth — the maintainer path goes through gh instead.
        #expect(GitHubReleaseClient.buildRequest().value(forHTTPHeaderField: "Authorization") == nil)
    }
}
