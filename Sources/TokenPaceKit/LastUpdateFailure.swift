import Foundation

// MARK: - LastUpdateFailure

/// A record of the **most recent** auto-update install attempt that failed (#210) — the tag it tried,
/// the pipeline **stage** it broke at, and the raw **reason** string. Persisted (via `PersistedConfig`)
/// so it survives a relaunch and can be surfaced on the Settings → About pane, where the user learns
/// *why* their previous update did not go through.
///
/// This is a pure value type with no clock or I/O, so the "should this record still be shown?" logic
/// (`shouldClear`) is unit-tested with literals (ADR-0009), like ``UpdateMenuState``. The shell
/// (`AppDelegate`) maps an `UpdateInstallOutcome` into a `Stage` + reason and writes the three fields;
/// the view (`AboutPane`) reads them back and renders the ⚠️ line.
public struct LastUpdateFailure: Sendable, Equatable {

    /// The pipeline stage an auto-install broke at — the four failing points of `UpdateInstaller`'s
    /// download → unzip → verify → replace pipeline. Success and the inert dev-build `notApplicable`
    /// case are **not** stages (they never produce a `LastUpdateFailure`).
    public enum Stage: String, Sendable, Equatable, CaseIterable {
        /// The download of the release asset failed (network / HTTP status / write error).
        case download
        /// Unzipping the downloaded archive failed.
        case unzip
        /// Signature / notarization / Team-ID verification of the downloaded bundle failed.
        case verify
        /// The atomic replacement of the installed `.app` failed (permissions / I/O).
        case replace

        /// A human-readable name for the stage, shown in the About pane's "Stage: …" line. Phrased as
        /// the activity that failed ("downloading", "verification") rather than the bare enum case.
        public var displayName: String {
            switch self {
            case .download: return "downloading"
            case .unzip:    return "unzipping"
            case .verify:   return "verification"
            case .replace:  return "installing"
            }
        }
    }

    /// The release tag whose auto-install failed (e.g. `"v0.54.0"`).
    public let tag: String
    /// The stage the install broke at.
    public let stage: Stage
    /// The raw reason string carried by the failing `UpdateInstallOutcome` case (e.g.
    /// `"http status 404"`, `"team id mismatch (expected …)"`). Technical by design — shown verbatim so
    /// the maintainer can act on it; never localized.
    public let reason: String

    public init(tag: String, stage: Stage, reason: String) {
        self.tag = tag
        self.stage = stage
        self.reason = reason
    }

    /// Whether a stored failure record is now **stale** and should be cleared, given the newest release
    /// tag currently known. A failure is stale once its tag no longer denotes the newest known release —
    /// either a *newer* release has since appeared (that version, not the failed one, is what matters
    /// now) or the installed build has caught up so nothing newer is known (`latestKnownTag == nil`).
    ///
    /// This mirrors how the red `updateFailed` menu item only matches `lastFailedInstallVersion`
    /// against the current latest (`UpdateMenuState`): the About pane must not show a failure for a
    /// version that has already been superseded.
    ///
    /// - Parameters:
    ///   - failedTag: The tag of the stored failure record.
    ///   - latestKnownTag: The newest release tag currently known, or `nil` if none is newer than the
    ///     installed build.
    public static func shouldClear(failedTag: String, latestKnownTag: String?) -> Bool {
        guard let latest = latestKnownTag else { return true }
        return !UpdateMenuState.sameVersion(failedTag, latest)
    }
}
