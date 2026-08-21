import Foundation
import Security

// MARK: - OAuthCredentials

/// Claude Code OAuth credentials, read from the macOS Keychain.
///
/// Mirrors the nested `claudeAiOauth` payload of the `"Claude Code-credentials"` generic-password
/// item (SPEC "Token strategy", issue #8). Fields the agent does not consume directly
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
    /// of `ResetClock`/`PacingModel`. The `<=` boundary mirrors `ResetClock`'s "at or past now is
    /// past" rule: an instant exactly at the deadline is already stale.
    public func isExpired(now: Date) -> Bool { expiresAt <= now }

    /// Convenience inverse of ``isExpired(now:)``: the token is still usable (`expiresAt > now`).
    public func isValid(now: Date) -> Bool { !isExpired(now: now) }
}

// MARK: - TokenCredentials

/// The subset of ``OAuthCredentials`` the polling engine actually needs: the bearer token and its
/// expiry — deliberately **without** the `refreshToken` (the secret never travels into the engine)
/// or the diagnostic fields. Introduced with the Troubleshoot window (ADR-0020) so a single
/// Keychain read hands the engine both the token *and* its `expiresAt`: the expiry drives the
/// delegated-refresh decision (moved here from the provider) and feeds ``TokenDiagnostics`` — even
/// for an already-expired token, the most valuable diagnostic case.
///
/// The provider no longer judges expiry; ``isExpired(now:)`` is the same `expiresAt <= now`
/// predicate as ``OAuthCredentials/isExpired(now:)``, applied by the engine.
public struct TokenCredentials: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Date
    /// The plan tier from the Keychain payload (`subscriptionType`, e.g. `"max"`), or `nil` when
    /// absent. **Not a secret** — a plan label, carried alongside `expiresAt` so the journal (#242)
    /// and diagnostics can record which plan produced a reading (limits/pacing differ by plan).
    public let subscriptionType: String?
    /// The rate-limit tier (`rateLimitTier`, e.g. `"default_claude_max_5x"`), or `nil`. Not a secret.
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        expiresAt: Date,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    /// Whether the token is expired at `now` — equality counts as expired (`expiresAt <= now`),
    /// mirroring ``OAuthCredentials/isExpired(now:)``.
    public func isExpired(now: Date) -> Bool { expiresAt <= now }
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
    /// (`errSecAuthFailed`, `errSecInteractionNotAllowed`). Not produced by the `security`-CLI
    /// read path (ADR-0019) — kept for exhaustive-switch compatibility downstream.
    case accessDenied(OSStatus)
    /// Any other failure of the Keychain read. On the `security`-CLI path (ADR-0019) the payload
    /// is the tool's **exit code** (not an `OSStatus`), or a local sentinel:
    /// ``TokenProvider/launchFailedStatus`` / ``TokenProvider/timedOutStatus``.
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
/// | ``parseSecretOutput(_:)`` / ``mapExitStatus(_:)`` | pure | yes |
/// | ``readRawData()`` / ``credentials()`` | Keychain I/O (`security` CLI) | no (manual check, issue #8) |
/// | fallback refresh | network | PR 8b (test account) |
///
/// ## Token strategy (SPEC "Token strategy")
/// 1. Read from the Keychain; if `expiresAt` is in the future → hand back `accessToken` as is.
/// 2. **Fallback only (rare, ADR-0017):** if expired — the polling layer performs a *delegated
///    refresh*: it spawns the `claude` CLI (`ClaudeCLIRefresher`) so Claude Code rotates its own
///    credentials, then re-reads this provider. TokenPace never runs the `refresh_token` grant
///    and never writes the Keychain — refresh tokens rotate, so a self-refresh would desync
///    Claude Code's stored pair and log the user out of the CLI.
///
/// An expired token is **never** sent to the API (that would guarantee a 401 and burn rate-limit
/// budget). Since ADR-0020 the provider no longer judges expiry: ``currentCredentials(now:)`` hands
/// back the token **and** its `expiresAt` (readable even when stale, for diagnostics), and the
/// polling engine decides — it short-circuits the network on an expired token and triggers the
/// delegated refresh above. `TokenProvider` itself holds no timer and stays stateless.
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

    // MARK: currentCredentials

    /// The current token plus its expiry, for the polling engine. Reads ``credentials()`` and
    /// projects it onto ``TokenCredentials`` — it does **not** judge expiry (that decision moved to
    /// the engine with ADR-0020, so `expiresAt` is available even for a stale token, the most
    /// valuable diagnostic case). A stale-but-readable item therefore returns successfully here; the
    /// engine calls ``TokenCredentials/isExpired(now:)`` and short-circuits the network + triggers
    /// the delegated refresh (ADR-0017).
    ///
    /// - Parameter now: accepted for signature symmetry with the rest of the codebase; unused here
    ///   now that expiry is judged downstream.
    /// - Throws: ``TokenError`` (`itemNotFound` / `accessDenied` / `keychainError` / `malformedData`)
    ///   from ``credentials()``.
    public static func currentCredentials(now: Date) throws -> TokenCredentials {
        let creds = try credentials()
        return TokenCredentials(
            accessToken: creds.accessToken, expiresAt: creds.expiresAt,
            subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier)
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

    /// Absolute path of the Apple `security` tool. A fixed path (not a `$PATH` lookup) — the app
    /// runs under launchd with a minimal PATH, and `/usr/bin/security` is part of macOS.
    private static let securityCLIPath = "/usr/bin/security"

    /// Hard cap on the `security` subprocess. A normal read finishes in tens of milliseconds; the
    /// cap only guards pathologies (e.g. a locked keychain making the tool wait for input it can
    /// never receive with no TTY attached).
    static let readTimeout: TimeInterval = 10

    /// Sentinel payloads for ``TokenError/keychainError(_:)`` on the CLI read path (ADR-0019).
    static let launchFailedStatus: OSStatus = -1
    static let timedOutStatus: OSStatus = -2

    /// The tool's "The specified item could not be found in the keychain" exit status
    /// (verified empirically; the CLI does not surface raw `errSecItemNotFound`).
    static let notFoundExitStatus: Int32 = 44

    /// The raw secret of the item, read by spawning `security find-generic-password -w` (match on
    /// service alone — the account is system-dependent), normalized by ``parseSecretOutput(_:)``.
    /// Maps failures to ``TokenError``; logs only exit status and byte count (`.public`), never
    /// the payload.
    ///
    /// A subprocess instead of `SecItemCopyMatching` on purpose (ADR-0019): Claude Code rewrites
    /// this item via `security add-generic-password -U` on every token refresh, and that call
    /// resets the item's ACL partition list to `apple-tool:` — silently revoking the
    /// "Always Allow" grant of any GUI app, so a direct API read re-triggers keychain prompts
    /// after every refresh (~every 8 h). The `security` tool is an Apple tool inside the
    /// `apple-tool:` partition, so this path stays silent no matter how often Claude Code
    /// rewrites the item — for any build flavor, ad-hoc `swift run` included.
    private static func readRawData() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityCLIPath)
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()   // captured so it cannot reach the console; may echo item attributes
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            AppLogger.keychain.error("security cli launch failed")
            throw TokenError.keychainError(launchFailedStatus)
        }
        guard finished.wait(timeout: .now() + readTimeout) != .timedOut else {
            process.terminate()
            AppLogger.keychain.error("security cli read timed out after \(Int(readTimeout), privacy: .public)s")
            throw TokenError.keychainError(timedOutStatus)
        }
        // The payload is ~3 KB — far below the 64 KB pipe buffer, so reading after exit
        // cannot deadlock.
        let raw = stdout.fileHandleForReading.readDataToEndOfFile()
        let status = process.terminationStatus
        AppLogger.keychain.debug("security cli read exit=\(status, privacy: .public) bytes=\(raw.count, privacy: .public)")
        guard status == 0 else { throw mapExitStatus(status) }
        return parseSecretOutput(raw)
    }

    /// Map a non-zero `security find-generic-password` exit status to a ``TokenError``.
    /// ``notFoundExitStatus`` (44) is the tool's "item not found"; anything else is carried in
    /// ``TokenError/keychainError(_:)`` as the raw exit code.
    static func mapExitStatus(_ status: Int32) -> TokenError {
        status == notFoundExitStatus ? .itemNotFound : .keychainError(OSStatus(status))
    }

    /// Normalize the raw stdout of `security find-generic-password -w` into the secret bytes.
    ///
    /// The tool prints the secret followed by one trailing newline. UTF-8-printable secrets (the
    /// `claudeAiOauth` JSON wrapper) are printed verbatim; non-printable ones are hex-encoded —
    /// decoded here defensively so a future re-encoding by Claude Code cannot break the read.
    /// The JSON wrapper always starts with `{`, so it can never be mistaken for hex; anything
    /// else that does not look like hex passes through untouched (``decode(from:)`` judges it).
    static func parseSecretOutput(_ raw: Data) -> Data {
        var bytes = raw
        if bytes.last == 0x0A { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count % 2 == 0,
              let text = String(data: bytes, encoding: .utf8),
              text.first != "{", text.allSatisfy(\.isHexDigit)
        else { return bytes }
        var decoded = Data(capacity: bytes.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            decoded.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return decoded
    }

}
