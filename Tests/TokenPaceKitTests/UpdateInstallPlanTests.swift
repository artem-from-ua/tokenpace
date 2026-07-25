import Testing
import Foundation
@testable import TokenPaceKit

@Suite("UpdateInstallPlan.decide")
struct UpdateInstallPlanTests {

    private let zip = GitHubReleaseAsset(
        name: "TokenPace-0.31.0.zip",
        browserDownloadURL: "https://github.com/artem-from-ua/tokenpace/releases/download/v0.31.0/TokenPace-0.31.0.zip")

    /// A newer release (v0.31.0) carrying the installable zip.
    private func newerWithAsset() -> GitHubRelease {
        GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [zip])
    }

    /// Decide with favourable environment defaults (AC power, unmetered), so a test overrides only the
    /// gate it exercises.
    private func decide(
        release: GitHubRelease, current: String,
        isAppBundle: Bool = true, autoInstall: Bool = true,
        onACPower: Bool = true, metered: Bool = false
    ) -> UpdateInstallDecision {
        UpdateInstallPlan.decide(
            release: release, currentVersion: current,
            isAppBundle: isAppBundle, autoInstallEnabled: autoInstall,
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
