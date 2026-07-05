import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so every validity assertion is deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// A full, well-formed Keychain payload matching the real `claudeAiOauth` shape.
private func payload(
    accessToken: String = "acc-123",
    refreshToken: String = "ref-456",
    expiresAt: String = "1782093167111",
    scopes: String? = #"["user:inference","user:profile"]"#,
    subscriptionType: String? = #""max""#,
    rateLimitTier: String? = #""default_claude_max_5x""#
) -> Data {
    var fields = [
        "\"accessToken\":\"\(accessToken)\"",
        "\"refreshToken\":\"\(refreshToken)\"",
        "\"expiresAt\":\(expiresAt)",
    ]
    if let scopes { fields.append("\"scopes\":\(scopes)") }
    if let subscriptionType { fields.append("\"subscriptionType\":\(subscriptionType)") }
    if let rateLimitTier { fields.append("\"rateLimitTier\":\(rateLimitTier)") }
    return "{\"claudeAiOauth\":{\(fields.joined(separator: ","))}}".data(using: .utf8)!
}

// MARK: - decode

@Suite("TokenProvider.decode")
struct DecodeTests {

    @Test func validPayloadDecodesAllFields() throws {
        let creds = try TokenProvider.decode(from: payload())
        #expect(creds.accessToken == "acc-123")
        #expect(creds.refreshToken == "ref-456")
        #expect(creds.scopes == ["user:inference", "user:profile"])
        #expect(creds.subscriptionType == "max")
        #expect(creds.rateLimitTier == "default_claude_max_5x")
    }

    @Test func expiresAtMillisConvertsToDate() throws {
        // 1782093167111 ms → 1782093167.111 s, built independently of TokenProvider's own math.
        let expected = Date(timeIntervalSince1970: 1_782_093_167.111)
        let creds = try TokenProvider.decode(from: payload())
        #expect(creds.expiresAt == expected)
    }

    @Test func optionalFieldsAbsentDecodes() throws {
        let data = payload(scopes: nil, subscriptionType: nil, rateLimitTier: nil)
        let creds = try TokenProvider.decode(from: data)
        #expect(creds.scopes == [])
        #expect(creds.subscriptionType == nil)
        #expect(creds.rateLimitTier == nil)
    }

    @Test func missingAccessTokenThrowsMalformed() {
        // Wrapper present, required field absent.
        let data = #"{"claudeAiOauth":{"refreshToken":"r","expiresAt":1782093167111}}"#.data(using: .utf8)!
        #expect(throws: TokenError.malformedData) { try TokenProvider.decode(from: data) }
    }

    @Test func missingWrapperThrowsMalformed() {
        // Flat shape without the `claudeAiOauth` key.
        let data = #"{"accessToken":"a","refreshToken":"r","expiresAt":1782093167111}"#.data(using: .utf8)!
        #expect(throws: TokenError.malformedData) { try TokenProvider.decode(from: data) }
    }

    @Test func garbageBytesThrowMalformed() {
        let data = "not json at all".data(using: .utf8)!
        #expect(throws: TokenError.malformedData) { try TokenProvider.decode(from: data) }
    }

    @Test func emptyDataThrowsMalformed() {
        #expect(throws: TokenError.malformedData) { try TokenProvider.decode(from: Data()) }
    }

    @Test func expiresAtAsStringThrowsMalformed() {
        // `expiresAt` quoted (string, not number) — pins the numeric contract.
        let data = payload(expiresAt: "\"1782093167111\"")
        #expect(throws: TokenError.malformedData) { try TokenProvider.decode(from: data) }
    }
}

// MARK: - validity

@Suite("OAuthCredentials.validity")
struct ValidityTests {

    private func creds(expiresAt: Date) -> OAuthCredentials {
        OAuthCredentials(accessToken: "acc", refreshToken: "ref", expiresAt: expiresAt)
    }

    @Test func futureExpiryIsValid() {
        let c = creds(expiresAt: now.addingTimeInterval(3600))
        #expect(c.isValid(now: now))
        #expect(!c.isExpired(now: now))
    }

    @Test func pastExpiryIsExpired() {
        let c = creds(expiresAt: now.addingTimeInterval(-1))
        #expect(c.isExpired(now: now))
        #expect(!c.isValid(now: now))
    }

    @Test func exactBoundaryIsExpired() {
        // `expiresAt == now` counts as expired (`<=`), mirroring ResetClock's `.resetNow` on equality.
        #expect(creds(expiresAt: now).isExpired(now: now))
    }

    @Test func expiredCredentialsThrowNotReturnOldToken() {
        // Contract: a stale token is never handed back — the agent must not send it to the API.
        let stale = creds(expiresAt: now.addingTimeInterval(-1))
        #expect(throws: TokenError.expired) { try TokenProvider.accessTokenIfValid(stale, now: now) }
    }

    @Test func validCredentialsReturnAccessToken() throws {
        let fresh = creds(expiresAt: now.addingTimeInterval(3600))
        #expect(try TokenProvider.accessTokenIfValid(fresh, now: now) == "acc")
    }
}
