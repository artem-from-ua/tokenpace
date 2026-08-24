import Foundation

// MARK: - CodexIncidentClient

/// One request for Codex's incidents, against the status page's own frontend backend.
///
/// A client of its own rather than a `StatusClient` call with another endpoint, because the body is
/// a different shape (``CodexIncidentFeed``, not ``StatusSummary``) and the failure means something
/// different: a failed status poll greys the rows, a failed incident poll costs only the incident
/// rows and is expected to happen — this endpoint is undocumented.
///
/// It answers without a cookie and without a browser User-Agent (verified: a plain
/// `TokenPace/<version>` gets 200 and the same bytes), so no impersonation is attempted here.
///
/// The response is large — roughly half a megabyte for the full history it returns — which is why it
/// takes its own, slower cadence than the component feed and why its body is never journalled.
public enum CodexIncidentClient {

    /// Perform one incident poll. Throws the same narrow ``StatusFetchError`` the status client does,
    /// so a `429` reaches the caller's backoff instead of being flattened into "unavailable".
    public static func fetch(
        transport: UsageTransport = URLSession.shared,
        endpoint: URL = StatusHealth.codexIncidentsEndpoint,
        userAgent: String
    ) async throws -> CodexIncidentFeed {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            AppLogger.network.error(
                "codex incidents transport error: \(error.localizedDescription, privacy: .public)")
            throw StatusFetchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw StatusFetchError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try decode(from: data)
        case 429:
            let retryAfter = StatusClient.retryAfterSeconds(from: http)
            AppLogger.network.error(
                "codex incidents rate-limited: HTTP 429 retryAfter=\(retryAfter ?? -1, privacy: .public)")
            throw StatusFetchError.rateLimited(retryAfter: retryAfter)
        default:
            AppLogger.network.error(
                "codex incidents failed: HTTP \(http.statusCode, privacy: .public)")
            throw StatusFetchError.decode
        }
    }

    /// Decode a 200 body. Any `DecodingError` maps to ``StatusFetchError/decode`` — which is what
    /// makes a **shape change** at this undocumented endpoint degrade like an outage rather than
    /// crash the poll.
    public static func decode(from data: Data) throws -> CodexIncidentFeed {
        do {
            return try JSONDecoder().decode(CodexIncidentFeed.self, from: data)
        } catch is DecodingError {
            AppLogger.network.error("codex incidents decode failed")
            throw StatusFetchError.decode
        }
    }
}
