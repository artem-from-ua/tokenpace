import Foundation

// MARK: - UpdateFetcher

/// The one thing that varies between the two update-check paths (#37): where the raw
/// `/releases/latest` JSON bytes come from.
///
/// Two conformers exist:
/// - ``HTTPUpdateFetcher`` (this file) — anonymous HTTPS via the shared ``UsageTransport`` seam.
///   Used once the repo is public; while it is private the request 404s and maps to
///   ``UpdateFetchError/notFound``.
/// - `GHReleaseFetcher` (the `TokenPace` glue target) — spawns `gh api …` so the maintainers' local
///   `gh` credentials read a private repo's releases. A subprocess is a platform side-effect, so it
///   lives in the shell behind this protocol, exactly like `DelegatedRefresher`.
///
/// Both feed their bytes through the **same** pure ``GitHubReleaseDecoder``, so the decode/compare
/// half stays in the kit and is unit-tested with a stub fetcher — no live network or process needed.
public protocol UpdateFetcher: Sendable {
    /// Fetch the raw `/releases/latest` JSON bytes, or throw an ``UpdateFetchError``.
    func fetchLatestReleaseJSON() async throws -> Data
}

// MARK: - UpdateFetchError

/// Why an update fetch failed. All cases degrade to "no update" in the shell — the feature is a
/// courtesy signal and must never surface an error to the user.
public enum UpdateFetchError: Error, Sendable, Equatable {
    /// A transport/connectivity failure (offline, TLS, timeout, DNS, non-HTTP response).
    case transport(String)
    /// HTTP 404 — the expected result of the anonymous path while the repo is private, or a repo /
    /// release that does not exist. Distinct from ``transport`` so the shell can log it as an
    /// expected no-op rather than a fault.
    case notFound
    /// The fetch mechanism itself was unavailable (`gh` binary not found, non-zero `gh` exit, spawn
    /// failure). Glue-path only; the shell treats it exactly like ``notFound`` (silent).
    case unavailable(String)
    /// A non-404 HTTP error, or a 200 body that did not decode. Kept for symmetry with the other
    /// clients; also mapped to "no update".
    case decode
}

// MARK: - GitHubReleaseClient

/// The `GET /repos/artem-from-ua/tokenpace/releases/latest` client (#37), mirroring the
/// ``StatusClient`` purity split. The transport is abstracted one level higher than the other
/// clients (behind ``UpdateFetcher``, not ``UsageTransport``) because one of the two paths is a
/// subprocess, not an HTTP request.
///
/// ## Layers
/// | Layer | Purity | Unit-tested |
/// |---|---|---|
/// | ``buildRequest()`` | pure (→ `URLRequest`) | yes |
/// | ``GitHubReleaseDecoder/decode(from:)`` | pure (`Data` → ``GitHubRelease``) | yes |
/// | ``checkForUpdate(using:currentVersion:)`` | orchestration over an injected fetcher | yes (stub) |
public enum GitHubReleaseClient {
    public static let owner = "artem-from-ua"
    public static let repo = "tokenpace"

    /// The `/releases/latest` endpoint. Force-unwrapped: a compile-time literal whose failure would
    /// be a programmer error, not a runtime condition.
    public static let endpoint = URL(
        string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!

    /// The user-facing releases page — the fallback link when no concrete release is known yet
    /// (e.g. the menu item is somehow shown before a successful fetch). Force-unwrapped literal.
    public static let releasesPageURL = URL(
        string: "https://github.com/\(owner)/\(repo)/releases")!

    /// `TokenPace/<version>` — GitHub's REST API **requires** a `User-Agent` header and 403s without
    /// one. Distinct from the usage/status clients' `claude-code/…` UA: this request is TokenPace's
    /// own, not a Claude Code call.
    static func userAgent() -> String { "TokenPace/\(TokenPaceKit.version)" }

    // MARK: buildRequest (pure seam)

    /// Build the anonymous GET request: the mandatory `User-Agent` plus GitHub's recommended
    /// `Accept: application/vnd.github+json`. No auth header — the anonymous path relies on the repo
    /// being public; the authenticated maintainer path goes through `gh`, not this request.
    public static func buildRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: checkForUpdate (orchestration)

    /// The single high-level call the shell makes: fetch the latest release via `fetcher`, decode it,
    /// and return it **iff** its tag is strictly newer than `currentVersion`; otherwise `nil`.
    ///
    /// Never throws. Any ``UpdateFetchError`` (including the expected ``UpdateFetchError/notFound``
    /// on a private repo), a decode failure, or a non-newer release all collapse to `nil` — the
    /// graceful-degradation contract. The only thing that varies at the call site is which
    /// ``UpdateFetcher`` is passed (HTTP vs `gh`), so the path choice is isolated to one line.
    public static func checkForUpdate(
        using fetcher: UpdateFetcher,
        currentVersion: String = TokenPaceKit.version
    ) async -> GitHubRelease? {
        let data: Data
        do {
            data = try await fetcher.fetchLatestReleaseJSON()
        } catch let error as UpdateFetchError {
            switch error {
            case .notFound:
                AppLogger.network.notice("update: releases/latest 404 (repo private or no release)")
            case .transport(let message):
                AppLogger.network.error("update: fetch transport error: \(message, privacy: .public)")
            case .unavailable(let message):
                AppLogger.network.notice("update: fetch unavailable: \(message, privacy: .public)")
            case .decode:
                AppLogger.network.error("update: fetch decode error")
            }
            return nil
        } catch {
            AppLogger.network.error(
                "update: fetch unexpected error: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let release = try? GitHubReleaseDecoder.decode(from: data) else { return nil }
        guard UpdateComparison.isNewer(tag: release.tagName, than: currentVersion) else {
            AppLogger.network.notice(
                "update: latest=\(release.tagName, privacy: .public) not newer than \(currentVersion, privacy: .public)")
            return nil
        }
        return release
    }
}

// MARK: - HTTPUpdateFetcher

/// The anonymous-HTTPS ``UpdateFetcher`` — reuses the shared ``UsageTransport`` seam (no second
/// transport protocol, per ADR-0008), so it stubs identically to the other clients. Maps HTTP 404 to
/// ``UpdateFetchError/notFound`` so the private-repo case is an expected no-op, not an error.
public struct HTTPUpdateFetcher: UpdateFetcher {
    private let transport: UsageTransport

    public init(transport: UsageTransport = URLSession.shared) {
        self.transport = transport
    }

    public func fetchLatestReleaseJSON() async throws -> Data {
        let request = GitHubReleaseClient.buildRequest()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw UpdateFetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateFetchError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            return data
        case 404:
            throw UpdateFetchError.notFound
        default:
            throw UpdateFetchError.decode
        }
    }
}
