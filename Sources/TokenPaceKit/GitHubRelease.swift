import Foundation

// MARK: - GitHubRelease

/// The two fields TokenPace needs from GitHub's `GET /repos/{owner}/{repo}/releases/latest`
/// response (#37): the release tag (compared against the running version) and the release page URL
/// (opened from the menu / notification / Configure line).
///
/// The REST payload carries dozens of other keys (`id`, `name`, `body`, `assets[]`, `prerelease`,
/// `draft`, …) — all deliberately unmodeled. `Decodable` drops unknown keys for free, mirroring
/// ``StatusSummary``'s forward-compatible decode.
///
/// This model is the **shared** decode target of both fetch paths: the anonymous HTTPS body and the
/// `gh api` subprocess stdout are the same REST JSON, so ``GitHubReleaseDecoder/decode(from:)`` maps
/// both. That is what keeps the `gh`-subprocess path (glue) testable without a live process — only
/// the byte source differs, never the decode.
public struct GitHubRelease: Sendable, Equatable, Decodable {
    /// The release tag, verbatim from the API — e.g. `"v0.20.0"`. Fed straight to
    /// ``UpdateComparison/isNewer(tag:than:)``, which strips the `v` while parsing.
    public let tagName: String
    /// The human-facing release page URL (`html_url`), e.g.
    /// `https://github.com/artem-from-ua/tokenpace/releases/tag/v0.20.0`. Opened on click.
    public let htmlURL: String

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(tagName: String, htmlURL: String) {
        self.tagName = tagName
        self.htmlURL = htmlURL
    }
}

// MARK: - GitHubReleaseDecodeError

/// Why decoding a `/releases/latest` body failed. A single case: the payload was not the JSON object
/// we expect (missing `tag_name`/`html_url`, or malformed JSON). Kept narrow — the shell maps any
/// failure to "no update" and never surfaces it to the user.
public enum GitHubReleaseDecodeError: Error, Sendable, Equatable {
    case decode
}

// MARK: - GitHubReleaseDecoder

/// The pure `Data → GitHubRelease` seam, unit-tested with literal fixtures. Any `DecodingError`
/// (including an absent `tag_name`) maps to ``GitHubReleaseDecodeError/decode`` and logs a single
/// `network.error`, mirroring ``StatusClient/decode(from:)``.
public enum GitHubReleaseDecoder {
    public static func decode(from data: Data) throws -> GitHubRelease {
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch is DecodingError {
            AppLogger.network.error("update: release decode failed")
            throw GitHubReleaseDecodeError.decode
        }
    }
}
