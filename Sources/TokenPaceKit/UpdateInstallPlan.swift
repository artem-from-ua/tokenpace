import Foundation

// MARK: - UpdateInstallDecision

/// The outcome of ``UpdateInstallPlan/decide(release:currentVersion:isAppBundle:autoInstallEnabled:onACPower:networkIsMetered:)``
/// (#122): whether to auto-install `release`, and if not, why not. The non-`install` cases are
/// distinct so the shell can log a precise reason and, where relevant, keep the manual "Download"
/// fallback visible.
///
/// Two flavours of "not now": a **skip** is a settled no for this release (opt-out, not newer, dev
/// build, no asset); a **defer** is a *temporary* no on an otherwise-installable release because the
/// environment is unfavourable (on battery, or a metered network). A deferred release is re-evaluated
/// on the next update heartbeat, so it installs as soon as conditions improve — no state to persist.
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
    /// Installable, but the Mac is on battery — **defer** until it is plugged into AC power, so an
    /// interrupted download/replace can't be caused by a drained battery (retried next heartbeat).
    case deferOnBattery(asset: GitHubReleaseAsset, targetVersion: String)
    /// Installable, but the network is metered (expensive / constrained — cellular, hotspot, Low Data
    /// Mode) — **defer** until an unmetered network, so a ~10 MB download isn't spent on a capped link
    /// (retried next heartbeat).
    case deferMeteredNetwork(asset: GitHubReleaseAsset, targetVersion: String)
    /// Installable, but downloading the asset would leave less than the required free-space headroom
    /// (``UpdateInstallPlan/minFreeBytesAfterDownload``) on the volume — **defer** until enough space
    /// frees up, so the update never fills the disk (retried next heartbeat).
    case deferInsufficientSpace(asset: GitHubReleaseAsset, targetVersion: String)
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
/// 5. **free space** — downloading must leave ≥ ``minFreeBytesAfterDownload`` free; else *defer*.
/// 6. **AC power** — on battery, *defer* (don't risk a mid-install battery drain).
/// 7. **unmetered** — on a metered link, *defer* (don't spend a capped connection on the download).
///
/// The order is deliberate. The settled-no gates (1–4) come first, cheapest and most fundamental
/// first, so a user who has the feature off, is already current, or has no installable asset gets an
/// early return naming the reason they'd expect. The environment gates (5–7) come last, because they
/// only make sense on an otherwise-installable release and are *temporary* — they carry the chosen
/// `asset` so the shell need not re-select, and produce a `defer…` the next heartbeat re-evaluates.
/// Free space is checked before power/metered: a full disk is the hardest physical blocker, and there
/// is no point deferring "for AC" if the download couldn't land anyway.
///
/// A caller performing a **forced** install (a deliberate dry run, or a manual "install now") passes
/// `onACPower: true, networkIsMetered: false` to bypass gates 6–7 — the user has explicitly asked, so
/// the environment courtesy does not apply. The free-space gate is **not** bypassed: no amount of user
/// intent makes it safe to fill the disk.
public enum UpdateInstallPlan {

    /// The free space that must remain **after** downloading the asset: 5 GB. Keeps an auto-update from
    /// pushing the volume to the brink even when the archive itself is small.
    public static let minFreeBytesAfterDownload = 5 * 1_000_000_000   // 5 GB (decimal, matching Finder)

    /// Decide whether to auto-install `release`.
    ///
    /// - Parameters:
    ///   - release: The release the update check surfaced (already known-newer by `checkForUpdate`,
    ///     but re-guarded here so this decision is self-contained and testable in isolation).
    ///   - currentVersion: The running build's version (`TokenPaceKit.version`), injected for tests.
    ///   - isAppBundle: Whether the process is a real installed `.app` (`LaunchAtLoginController
    ///     .isAppBundle`), injected so this stays pure.
    ///   - autoInstallEnabled: The `PersistedConfig.installUpdatesAutomatically` opt-in.
    ///   - freeDiskBytes: Free space on the download/install volume, injected so this stays pure.
    ///   - onACPower: Whether the Mac is on AC power (adapter connected). A desktop Mac is always
    ///     `true`; injected so this stays pure. `true` for a forced install.
    ///   - networkIsMetered: Whether the current network is expensive/constrained (cellular, hotspot,
    ///     Low Data Mode). Injected so this stays pure. `false` for a forced install.
    public static func decide(
        release: GitHubRelease,
        currentVersion: String,
        isAppBundle: Bool,
        autoInstallEnabled: Bool,
        freeDiskBytes: Int,
        onACPower: Bool,
        networkIsMetered: Bool
    ) -> UpdateInstallDecision {
        guard autoInstallEnabled else { return .skipAutoInstallOff }
        guard UpdateComparison.isNewer(tag: release.tagName, than: currentVersion) else {
            return .skipNotNewer
        }
        guard isAppBundle else { return .skipNotAppBundle }
        guard let asset = UpdateAssetSelector.selectZIP(from: release) else { return .skipNoAsset }
        // Environment gates last — the release is installable, only the conditions aren't right yet.
        // Free space first among them (hardest physical blocker); not bypassed by a forced install.
        guard freeDiskBytes - asset.size >= minFreeBytesAfterDownload else {
            return .deferInsufficientSpace(asset: asset, targetVersion: release.tagName)
        }
        guard onACPower else { return .deferOnBattery(asset: asset, targetVersion: release.tagName) }
        guard !networkIsMetered else {
            return .deferMeteredNetwork(asset: asset, targetVersion: release.tagName)
        }
        return .install(asset: asset, targetVersion: release.tagName)
    }
}
