import Foundation

// MARK: - UpdateInstallDecision

/// The outcome of ``UpdateInstallPlan/decide(release:currentVersion:isAppBundle:autoInstallEnabled:)``
/// (#122): whether to auto-install `release`, and if not, why not. The non-`install` cases are
/// distinct so the shell can log a precise reason and, where relevant, keep the manual "Download"
/// fallback visible.
public enum UpdateInstallDecision: Sendable, Equatable {
    /// Install now: `asset` is the verified-name installable `.zip`, `targetVersion` its release tag.
    case install(asset: GitHubReleaseAsset, targetVersion: String)
    /// The user has not opted into automatic installation — only the signal path runs.
    case skipAutoInstallOff
    /// The release is not strictly newer than the running build (downgrade / same version / unparsable
    /// tag) — the replay/downgrade guard.
    case skipNotNewer
    /// This build is not a real `.app` bundle (a `swift run` dev binary), so replacement is impossible.
    case skipNotAppBundle
    /// The release is newer but carries no installable asset (no `TokenPace-<version>.zip`, or the only
    /// match was not HTTPS) — fall back to the manual "Download" link.
    case skipNoAsset
}

// MARK: - UpdateInstallPlan

/// The pure "should we auto-install this release right now?" decision (#122) — no clock, no I/O,
/// unit-tested with literals (ADR-0009). Collapses every gate into one verdict so the shell
/// (`UpdateInstaller`) only *executes*; it never re-derives the branching.
///
/// The gates, in order (first failing gate wins, so the returned reason is the most fundamental):
/// 1. **opt-in** — `autoInstallEnabled` (default-OFF via `PersistedConfig`); off → signal only.
/// 2. **newer** — ``UpdateComparison/isNewer(tag:than:)`` guards downgrade/replay/unparsable tags.
/// 3. **real bundle** — `isAppBundle` (a `swift run` binary cannot be swapped in place).
/// 4. **asset** — ``UpdateAssetSelector`` finds the version-named HTTPS `.zip`.
///
/// The order is deliberate: opt-in and "newer" are checked before the bundle/asset gates so that a
/// user who has the feature off, or is already current, gets a cheap early return without inspecting
/// assets — and so the logged reason names the *why-not* the user would most expect.
public enum UpdateInstallPlan {

    /// Decide whether to auto-install `release`.
    ///
    /// - Parameters:
    ///   - release: The release the update check surfaced (already known-newer by `checkForUpdate`,
    ///     but re-guarded here so this decision is self-contained and testable in isolation).
    ///   - currentVersion: The running build's version (`TokenPaceKit.version`), injected for tests.
    ///   - isAppBundle: Whether the process is a real installed `.app` (`LaunchAtLoginController
    ///     .isAppBundle`), injected so this stays pure.
    ///   - autoInstallEnabled: The `PersistedConfig.installUpdatesAutomatically` opt-in.
    public static func decide(
        release: GitHubRelease,
        currentVersion: String,
        isAppBundle: Bool,
        autoInstallEnabled: Bool
    ) -> UpdateInstallDecision {
        guard autoInstallEnabled else { return .skipAutoInstallOff }
        guard UpdateComparison.isNewer(tag: release.tagName, than: currentVersion) else {
            return .skipNotNewer
        }
        guard isAppBundle else { return .skipNotAppBundle }
        guard let asset = UpdateAssetSelector.selectZIP(from: release) else { return .skipNoAsset }
        return .install(asset: asset, targetVersion: release.tagName)
    }
}
