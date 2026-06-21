import Foundation
import Security

// MARK: - OAuthCredentials

/// Claude Code OAuth credentials, read from the macOS Keychain.
///
/// Mirrors the nested `claudeAiOauth` payload of the `"Claude Code-credentials"` generic-password
/// item (SPEC "Стратегія токена", issue #8). Fields the agent does not consume directly
/// (`scopes` / `subscriptionType` / `rateLimitTier`) are kept for diagnostics and the future popup
/// breakdown, but never drive logic.
///
/// ```swift
/// let creds = try TokenProvider.credentials()
/// guard creds.isValid(now: Date()) else { /* wait for a fresh token */ }
/// usageClient.authorize(bearer: creds.accessToken)
/// ```
///
/// `expiresAt` arrives as a Unix timestamp in **milliseconds** and is converted to a `Date` in
/// ``TokenProvider/decode(from:)`` — everywhere downstream it is a plain `Date`.
///
/// - SeeAlso: ``TokenProvider/decode(from:)``, ``isExpired(now:)``, ADR-0007 (scope split / throws).
public struct OAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scopes: [String]
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scopes: [String] = [],
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    // MARK: validity

    /// Whether the token is expired at `now` — equality counts as expired (`expiresAt <= now`).
    ///
    /// The injected `now` keeps the check deterministic, matching the `now:` parameter convention
    /// of `ResetClock`/`PacingModel`. The `<=` boundary mirrors `ResetClock`'s `.resetNow` on
    /// equality: an instant exactly at the deadline is already stale.
    public func isExpired(now: Date) -> Bool { expiresAt <= now }

    /// Convenience inverse of ``isExpired(now:)``: the token is still usable (`expiresAt > now`).
    public func isValid(now: Date) -> Bool { !isExpired(now: now) }
}

// MARK: - TokenError

/// Distinguishable failure causes for reading / decoding the token.
///
/// Unlike the pure parsing in `ResetClock` (optional result, single "did not parse" cause), these
/// causes are mutually distinct and drive different UI reactions (explain the ACL "Always Allow"
/// dialog vs. "launch Claude Code" vs. wait-for-fresh-token), so a typed `throws` is used instead
/// of collapsing everything into one `nil` (ADR-0007).
public enum TokenError: Error, Equatable {
    /// The Keychain has no `"Claude Code-credentials"` item (`errSecItemNotFound`).
    /// Usually means Claude Code has never run on this Mac.
    case itemNotFound
    /// Access blocked by the item ACL or the user declined the dialog
    /// (`errSecAuthFailed`, `errSecInteractionNotAllowed`). UX: explain "Always Allow".
    case accessDenied(OSStatus)
    /// Any other unexpected `OSStatus` from `SecItemCopyMatching`.
    case keychainError(OSStatus)
    /// Payload is not `Data` / not UTF-8 / not JSON / missing the `claudeAiOauth` wrapper /
    /// missing a required field. (issue #8 acceptance: garbage → `malformedData`)
    case malformedData
    /// Credentials read fine but are expired. In this PR (read-only, no refresh) the agent must
    /// **not** send the stale token to the API — it waits for Claude Code to write a fresh one.
    /// PR 8b will attempt a fallback refresh before reaching this.
    case expired
}

// MARK: - TokenProvider

/// Reads the Claude Code OAuth token from the macOS Keychain.
///
/// Stateless namespace (like `ResetClock`/`PacingModel`): no stored state, `now` injected for
/// determinism. The layers are split deliberately:
///
/// | Layer | Purity | Unit-tested |
/// |---|---|---|
/// | ``decode(from:)`` | pure (`Data` → struct) | yes |
/// | ``OAuthCredentials/isExpired(now:)`` / `isValid` | pure | yes |
/// | ``readRawData()`` / ``credentials()`` | Keychain I/O | no (manual check, issue #8) |
/// | fallback refresh | network | PR 8b (test account) |
///
/// ## Token strategy (SPEC "Стратегія токена")
/// 1. Read from the Keychain; if `expiresAt` is in the future → hand back `accessToken` as is.
/// 2. **Fallback only (rare, PR 8b):** if expired — refresh via `refreshToken` and rewrite the
///    Keychain with the same structure, as Claude Code would. Risky: `refreshToken` may be
///    single-use (SPEC "Відкриті питання"), so it is gated behind a test account.
///
/// Until 8b lands, an expired token is **never** sent to the API (that would guarantee a 401 and
/// burn rate-limit budget). ``currentAccessToken(now:)`` throws ``TokenError/expired`` instead, and
/// the polling layer (#9 / #13) treats that as "keep re-reading the Keychain until Claude Code
/// writes a fresh token". `TokenProvider` itself holds no timer and stays stateless.
///
/// ## Privacy
/// The token is **never** logged. `AppLogger.keychain` carries only `.public` diagnostics —
/// `OSStatus`, token length, the fact of expiry — never the secret itself (see `AppLogger`).
public enum TokenProvider {

    // MARK: Keychain attributes

    /// The fixed `kSecAttrService` of the item created by Claude Code (SPEC; confirmed via
    /// `security find-generic-password`). We match on **service only** — `acct` (the user name)
    /// is system-dependent and is left out of the query.
    static let service = "Claude Code-credentials"

    // MARK: credentials

    /// Read and decode the current credentials from the Keychain.
    ///
    /// The ordinary path of issue #8: `SecItemCopyMatching` → ``decode(from:)``. This entry point
    /// does **not** judge expiry — that decision is left to ``currentAccessToken(now:)`` or the
    /// caller (`UsageClient` #9), so a stale-but-readable item still decodes successfully here.
    ///
    /// - Throws: ``TokenError`` (`itemNotFound` / `accessDenied` / `keychainError` / `malformedData`).
    public static func credentials() throws -> OAuthCredentials {
        let data = try readRawData()
        return try decode(from: data)
    }

    // MARK: currentAccessToken

    /// The ready-to-use `accessToken` for the `Authorization: Bearer` header, validity-checked.
    ///
    /// On an expired token this throws ``TokenError/expired`` and **never returns the stale
    /// token** — the agent must not send it to the API. The polling layer treats `.expired` as a
    /// signal to keep re-reading the Keychain until Claude Code writes a fresh pair. PR 8b will
    /// attempt a fallback refresh here before throwing.
    ///
    /// - Parameter now: the current instant (injected for tests; do not call `Date()` inside).
    /// - Throws: ``TokenError/expired`` when stale, or any error from ``credentials()``.
    public static func currentAccessToken(now: Date) throws -> String {
        let creds = try credentials()
        return try accessTokenIfValid(creds, now: now)
    }

    /// Pure validity gate behind ``currentAccessToken(now:)``, extracted so the "never return a
    /// stale token" contract is unit-testable without the Keychain. Returns the `accessToken` only
    /// when still valid; otherwise logs the expiry (length only, `.public`) and throws.
    static func accessTokenIfValid(_ creds: OAuthCredentials, now: Date) throws -> String {
        guard creds.isValid(now: now) else {
            AppLogger.keychain.notice("token expired, len=\(creds.accessToken.count, privacy: .public)")
            throw TokenError.expired
        }
        return creds.accessToken
    }

    // MARK: decode

    /// Parse the Keychain payload (`kSecValueData`) into ``OAuthCredentials``.
    ///
    /// A separate **pure** function on purpose: all format handling (the `claudeAiOauth` wrapper,
    /// `expiresAt` ms→`Date`, absent optional fields) is unit-tested without the Keychain — the
    /// core of the issue #8 acceptance criteria.
    ///
    /// Format (confirmed via `security find-generic-password`):
    /// ```json
    /// {"claudeAiOauth":{"accessToken":"...","refreshToken":"...",
    ///   "expiresAt":1782093167111,"scopes":[...],"subscriptionType":"max",
    ///   "rateLimitTier":"default_claude_max_5x"}}
    /// ```
    /// `expiresAt` is epoch **milliseconds** → `Date(timeIntervalSince1970: ms / 1000)`. The
    /// conversion lives here, not in `Codable`, to keep it explicit and testable.
    ///
    /// - Throws: ``TokenError/malformedData`` for non-UTF-8 / non-JSON / missing wrapper / missing
    ///   required `accessToken` / `refreshToken` / `expiresAt`.
    public static func decode(from data: Data) throws -> OAuthCredentials {
        do {
            let raw = try JSONDecoder().decode(Wrapper.self, from: data).claudeAiOauth
            return OAuthCredentials(
                accessToken: raw.accessToken,
                refreshToken: raw.refreshToken,
                expiresAt: Date(timeIntervalSince1970: raw.expiresAt / 1000),
                scopes: raw.scopes ?? [],
                subscriptionType: raw.subscriptionType,
                rateLimitTier: raw.rateLimitTier
            )
        } catch is DecodingError {
            throw TokenError.malformedData
        }
    }

    // MARK: - Private: Codable shape

    /// Outer JSON wrapper. Private — the public contract is ``OAuthCredentials``.
    private struct Wrapper: Decodable { let claudeAiOauth: RawCredentials }

    /// Inner `claudeAiOauth` object. `expiresAt` stays a `Double` (ms) here; the conversion to
    /// `Date` happens in ``decode(from:)`` so the transform is explicit, not hidden in `Codable`.
    private struct RawCredentials: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
        let scopes: [String]?
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    // MARK: - Private: Keychain I/O

    /// The raw `kSecValueData` of the item, matched on service alone (account is system-dependent).
    /// Maps `OSStatus` to ``TokenError``; logs only the status (`.public`), never the payload.
    private static func readRawData() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,   // genp
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        AppLogger.keychain.debug("SecItemCopyMatching status=\(status, privacy: .public)")
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw TokenError.malformedData }
            return data
        case errSecItemNotFound:
            throw TokenError.itemNotFound
        case errSecAuthFailed, errSecInteractionNotAllowed:
            throw TokenError.accessDenied(status)
        default:
            throw TokenError.keychainError(status)
        }
    }

    // MARK: - PR 8b (fallback refresh) — NOT in this PR
    // Added once the refresh round-trip is verified on a test Max account (refreshToken may be
    // single-use); client_id / endpoint / PKCE are still unconfirmed (SPEC lines 270–273).
    //   static func refreshAndStore(_ creds: OAuthCredentials) async throws -> OAuthCredentials
    //   static func buildRefreshRequest(refreshToken:clientId:endpoint:) -> URLRequest  // pure → tested
    //   private static func writeBack(_ creds: OAuthCredentials) throws                 // SecItemUpdate
}
