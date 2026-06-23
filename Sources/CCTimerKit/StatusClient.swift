import Foundation

// MARK: - StatusClient

/// HTTP client for the Claude status page summary, `GET https://status.claude.com/api/v2/summary.json`.
///
/// A stateless namespace mirroring ``UsageClient``: no stored state, no timer. It is a **second,
/// independent** data source from the usage API — a separate, polite cadence owned by the shell,
/// never sharing the usage 429 backoff (ADR-0013). The endpoint needs no auth.
///
/// ## Layers (purity split, mirrors ``UsageClient``)
/// | Layer | Purity | Unit-tested |
/// |---|---|---|
/// | ``buildRequest()`` | pure (→ `URLRequest`) | yes |
/// | ``decode(from:)`` | pure (`Data` → ``StatusSummary``) | yes |
/// | ``fetch(transport:)`` | network I/O | no (stub / manual) |
///
/// `fetch` performs exactly one request and never sleeps or retries — the shell's status loop
/// schedules the next poll on its own cadence. Any failure throws a narrow ``StatusFetchError``
/// that the shell turns into ``StatusHealth/unknown`` (it never escalates the usage backoff).
public enum StatusClient {

    /// The status summary endpoint. Force-unwrapped: a compile-time literal whose failure would be
    /// a programmer error, not a runtime condition.
    public static let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    /// `claude-code/<version>` — sent on this request too, for consistency with the usage client
    /// and to be a well-behaved client of the status page. The version is ``CCTimerKit/version``.
    static func userAgent() -> String { "claude-code/\(CCTimerKit.version)" }

    // MARK: buildRequest (pure seam)

    /// Build the GET request with the `User-Agent` header. No auth, no beta header — the status
    /// page is public.
    public static func buildRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: decode (pure seam)

    /// Decode a 200 body into a ``StatusSummary``. Any `DecodingError` maps to
    /// ``StatusFetchError/decode``. Unknown keys (`status`, `incidents`, `page`, …) are ignored;
    /// an absent `components` array decodes to `[]`.
    public static func decode(from data: Data) throws -> StatusSummary {
        do {
            return try JSONDecoder().decode(StatusSummary.self, from: data)
        } catch is DecodingError {
            AppLogger.network.error("status decode failed")
            throw StatusFetchError.decode
        }
    }

    // MARK: fetch (network)

    /// Perform one status poll. Returns the summary on 200; otherwise throws a ``StatusFetchError``.
    /// Does **not** sleep, retry, or own a timer — the shell's status loop schedules the next poll.
    ///
    /// - Parameter transport: Injected for testing; defaults to `URLSession.shared`. Reuses the
    ///   ``UsageTransport`` seam (same `data(for:)` signature) — no second protocol needed.
    public static func fetch(transport: UsageTransport = URLSession.shared) async throws -> StatusSummary {
        let request = buildRequest()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            AppLogger.network.error(
                "status request transport error: \(error.localizedDescription, privacy: .public)")
            throw StatusFetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            AppLogger.network.error("status response not HTTP")
            throw StatusFetchError.transport("non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            let summary = try decode(from: data)
            AppLogger.network.notice("status 200 ok components=\(summary.components.count, privacy: .public)")
            return summary
        default:
            // The status page carries no secrets and no per-status meaning beyond "not 200" for our
            // purposes — both map to `.decode` (→ `StatusHealth.unknown`), so we do not model
            // individual codes the way the usage client does for auth/429.
            AppLogger.network.error(
                "status request failed: HTTP \(http.statusCode, privacy: .public)")
            throw StatusFetchError.decode
        }
    }
}
