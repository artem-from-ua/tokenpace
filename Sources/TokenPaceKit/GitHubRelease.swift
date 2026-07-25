import Foundation

// MARK: - GitHubRelease

/// The fields TokenPace needs from GitHub's `GET /repos/{owner}/{repo}/releases/latest` response
/// (#37): the release tag (compared against the running version), the release page URL (opened from
/// the menu / notification / Configure line), and the downloadable assets (the notarized `.zip` the
/// auto-installer fetches, #122).
///
/// The REST payload carries dozens of other keys (`id`, `name`, `body`, `prerelease`, `draft`, …) —
/// all deliberately unmodeled. `Decodable` drops unknown keys for free, mirroring ``StatusSummary``'s
/// forward-compatible decode.
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
    /// The release's downloadable assets (#122), used by ``UpdateAssetSelector`` to find the
    /// notarized `.zip`. Absent/empty for the signal-only path (a stub release, or a payload that
    /// predates this field) — see the decode note below.
    public let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
        // Forward-compatible: a `/releases/latest` body always carries `assets` (possibly `[]`), but
        // a hand-built stub (`StubUpdateFetcher`) or an older cached blob may omit it — decode as `[]`
        // rather than failing, matching the "unknown keys dropped" contract for the required fields.
        assets = try c.decodeIfPresent([GitHubReleaseAsset].self, forKey: .assets) ?? []
    }

    public init(tagName: String, htmlURL: String, assets: [GitHubReleaseAsset] = []) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
    }
}

// MARK: - GitHubReleaseAsset

/// One downloadable file attached to a GitHub release (#122) — the subset TokenPace's auto-installer
/// needs: the asset's file `name` (matched against the version-named `.zip` pattern) and its
/// `browser_download_url` (the direct HTTPS download). Other keys (`id`, `size`, `content_type`, …)
/// are unmodeled; `Decodable` drops them.
public struct GitHubReleaseAsset: Sendable, Equatable, Decodable {
    /// The asset's file name, e.g. `"TokenPace-0.31.0.zip"`. Matched by ``UpdateAssetSelector``.
    public let name: String
    /// The direct download URL (`browser_download_url`), e.g.
    /// `https://github.com/.../releases/download/v0.31.0/TokenPace-0.31.0.zip`. Always HTTPS from
    /// GitHub; the selector rejects any non-`https` URL defensively.
    public let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }

    public init(name: String, browserDownloadURL: String) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
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
