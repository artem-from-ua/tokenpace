import Foundation

// MARK: - UpdateAssetSelector

/// The pure decision "which asset of a release is the installable `.zip`?" (#122) — no I/O, unit-
/// tested with literal fixtures (ADR-0009). The shell (`UpdateInstaller`) downloads whatever this
/// returns; if it returns `nil` the auto-installer stands down and the manual "Download" link stays
/// as the fallback.
///
/// The match is deliberately **exact**, not "any `.zip`": the auto-installer replaces the running
/// executable bundle, so it must fetch *our* artifact and nothing else. The release's build script
/// publishes a version-named archive — `TokenPace-<X.Y.Z>.zip` (see `docs/releasing.md`) — so the
/// selector reconstructs that expected name from the release tag (`v0.31.0` → `TokenPace-0.31.0.zip`)
/// and picks the asset whose file name matches it. A tag that does not parse to a clean version, or a
/// release with no such asset, yields `nil` — the same "no trusted input, no action" contract
/// ``UpdateComparison`` uses.
///
/// A non-`https` `browser_download_url` is rejected defensively: GitHub always serves assets over
/// HTTPS, so a plain-`http` (or other-scheme) URL is anomalous and must never be downloaded and run.
public enum UpdateAssetSelector {

    /// The product name prefix of the release archive (`TokenPace-<version>.zip`). Matches the
    /// `APP_NAME` in `scripts/build-app.sh` and the version-named zip produced in `docs/releasing.md`.
    static let assetPrefix = "TokenPace-"
    static let assetSuffix = ".zip"

    /// The installable asset for `release`, or `nil` if none is trustworthy.
    ///
    /// Steps: derive the expected file name from the release tag (via ``SemanticVersion`` so a `v`
    /// prefix is normalized away), then return the first asset whose `name` matches it **and** whose
    /// download URL is HTTPS. `nil` when the tag does not parse, no asset matches, or the only match
    /// is not HTTPS.
    public static func selectZIP(from release: GitHubRelease) -> GitHubReleaseAsset? {
        guard let expectedName = expectedAssetName(forTag: release.tagName) else { return nil }
        return release.assets.first { asset in
            asset.name == expectedName && isHTTPS(asset.browserDownloadURL)
        }
    }

    /// The expected archive file name for a release tag, e.g. `"v0.31.0"` → `"TokenPace-0.31.0.zip"`,
    /// or `nil` if the tag does not parse to a clean `MAJOR.MINOR.PATCH` (a tag we would not trust to
    /// build a download target from). The reconstructed version is always the canonical `X.Y.Z`, so a
    /// `v`-prefixed tag and a bare asset name line up.
    static func expectedAssetName(forTag tag: String) -> String? {
        guard let v = SemanticVersion(tag) else { return nil }
        return "\(assetPrefix)\(v.major).\(v.minor).\(v.patch)\(assetSuffix)"
    }

    /// Whether `urlString` is an `https` URL. A parse failure or any other scheme → `false`.
    private static func isHTTPS(_ urlString: String) -> Bool {
        URL(string: urlString)?.scheme?.lowercased() == "https"
    }
}
