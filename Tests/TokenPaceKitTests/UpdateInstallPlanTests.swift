import Testing
import Foundation
@testable import TokenPaceKit

@Suite("UpdateInstallPlan.decide")
struct UpdateInstallPlanTests {

    private let zip = GitHubReleaseAsset(
        name: "TokenPace-0.31.0.zip",
        browserDownloadURL: "https://github.com/artem-from-ua/tokenpace/releases/download/v0.31.0/TokenPace-0.31.0.zip",
        size: 900_000)   // ~0.9 MB, like the real archive

    /// A newer release (v0.31.0) carrying the installable zip.
    private func newerWithAsset() -> GitHubRelease {
        GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [zip])
    }

    /// Ample free space (100 GB) — the default so a test overrides only the gate it exercises.
    private let ampleSpace = 100 * 1_000_000_000

    /// Decide with favourable environment defaults (ample space, AC power, unmetered), so a test
    /// overrides only the gate it exercises.
    private func decide(
        release: GitHubRelease, current: String,
        isAppBundle: Bool = true, autoInstall: Bool = true,
        freeDiskBytes: Int? = nil, onACPower: Bool = true, metered: Bool = false
    ) -> UpdateInstallDecision {
        UpdateInstallPlan.decide(
            release: release, currentVersion: current,
            isAppBundle: isAppBundle, autoInstallEnabled: autoInstall,
            freeDiskBytes: freeDiskBytes ?? ampleSpace,
            onACPower: onACPower, networkIsMetered: metered)
    }

    @Test func installsWhenAllGatesPass() {
        #expect(decide(release: newerWithAsset(), current: "0.30.0")
            == .install(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func skipsWhenAutoInstallOff() {
        #expect(decide(release: newerWithAsset(), current: "0.30.0", autoInstall: false)
            == .skipAutoInstallOff)
    }

    @Test func skipsWhenNotNewer() {
        #expect(decide(release: newerWithAsset(), current: "0.31.0") == .skipNotNewer)   // equal
    }

    @Test func skipsOnDowngrade() {
        #expect(decide(release: newerWithAsset(), current: "0.40.0") == .skipNotNewer)   // running newer
    }

    @Test func skipsWhenNotAppBundle() {
        #expect(decide(release: newerWithAsset(), current: "0.30.0", isAppBundle: false)
            == .skipNotAppBundle)
    }

    @Test func skipsWhenNoAsset() {
        let noAsset = GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [])
        #expect(decide(release: noAsset, current: "0.30.0") == .skipNoAsset)
    }

    // MARK: environment (defer) gates

    @Test func defersOnBattery() {
        #expect(decide(release: newerWithAsset(), current: "0.30.0", onACPower: false)
            == .deferOnBattery(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func defersOnMeteredNetwork() {
        #expect(decide(release: newerWithAsset(), current: "0.30.0", metered: true)
            == .deferMeteredNetwork(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func batteryTakesPrecedenceOverMetered() {
        // Both unfavourable: the AC gate is checked first, so battery is the reported reason.
        #expect(decide(release: newerWithAsset(), current: "0.30.0", onACPower: false, metered: true)
            == .deferOnBattery(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func defersWhenInsufficientSpace() {
        // Only ~4 GB free, asset ~0.9 MB → less than the 5 GB headroom would remain.
        #expect(decide(release: newerWithAsset(), current: "0.30.0", freeDiskBytes: 4 * 1_000_000_000)
            == .deferInsufficientSpace(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func installsAtExactlyTheSpaceThreshold() {
        // free - assetSize == 5 GB exactly → passes (>=).
        let free = UpdateInstallPlan.minFreeBytesAfterDownload + zip.size
        #expect(decide(release: newerWithAsset(), current: "0.30.0", freeDiskBytes: free)
            == .install(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func spaceCheckCountsTheAssetSize() {
        // free is 5 GB + a hair, but the asset eats past the threshold → defer.
        let free = UpdateInstallPlan.minFreeBytesAfterDownload + zip.size - 1
        #expect(decide(release: newerWithAsset(), current: "0.30.0", freeDiskBytes: free)
            == .deferInsufficientSpace(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func spaceIsCheckedBeforePowerAndMetered() {
        // Disk full AND on battery AND metered → the space reason wins (checked first).
        #expect(decide(release: newerWithAsset(), current: "0.30.0",
                       freeDiskBytes: 1_000_000_000, onACPower: false, metered: true)
            == .deferInsufficientSpace(asset: zip, targetVersion: "v0.31.0"))
    }

    // MARK: gate ordering — settled skips beat environment defers

    @Test func offBeatsNotNewer() {
        // opt-in is checked before "newer": a disabled feature reports skipAutoInstallOff even for a
        // stale release.
        #expect(decide(release: newerWithAsset(), current: "0.40.0", isAppBundle: false, autoInstall: false)
            == .skipAutoInstallOff)
    }

    @Test func notNewerBeatsBundleAndAsset() {
        let noAsset = GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [])
        #expect(decide(release: noAsset, current: "0.31.0", isAppBundle: false) == .skipNotNewer)
    }

    @Test func noAssetBeatsBattery() {
        // A settled skip (no asset) wins over an environment defer, even on battery — there is nothing
        // installable to defer.
        let noAsset = GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [])
        #expect(decide(release: noAsset, current: "0.30.0", onACPower: false) == .skipNoAsset)
    }

    @Test func forcedEnvironmentBypassesDefers() {
        // A forced install passes onACPower:true, metered:false regardless of the real environment —
        // modeled here by the caller supplying favourable values, which yields .install.
        #expect(decide(release: newerWithAsset(), current: "0.30.0", onACPower: true, metered: false)
            == .install(asset: zip, targetVersion: "v0.31.0"))
    }
}
