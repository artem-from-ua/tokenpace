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

    @Test func installsWhenAllGatesPass() {
        let decision = UpdateInstallPlan.decide(
            release: newerWithAsset(), currentVersion: "0.30.0",
            isAppBundle: true, autoInstallEnabled: true)
        #expect(decision == .install(asset: zip, targetVersion: "v0.31.0"))
    }

    @Test func skipsWhenAutoInstallOff() {
        let decision = UpdateInstallPlan.decide(
            release: newerWithAsset(), currentVersion: "0.30.0",
            isAppBundle: true, autoInstallEnabled: false)
        #expect(decision == .skipAutoInstallOff)
    }

    @Test func skipsWhenNotNewer() {
        let decision = UpdateInstallPlan.decide(
            release: newerWithAsset(), currentVersion: "0.31.0",   // equal
            isAppBundle: true, autoInstallEnabled: true)
        #expect(decision == .skipNotNewer)
    }

    @Test func skipsOnDowngrade() {
        let decision = UpdateInstallPlan.decide(
            release: newerWithAsset(), currentVersion: "0.40.0",   // running is newer
            isAppBundle: true, autoInstallEnabled: true)
        #expect(decision == .skipNotNewer)
    }

    @Test func skipsWhenNotAppBundle() {
        let decision = UpdateInstallPlan.decide(
            release: newerWithAsset(), currentVersion: "0.30.0",
            isAppBundle: false, autoInstallEnabled: true)
        #expect(decision == .skipNotAppBundle)
    }

    @Test func skipsWhenNoAsset() {
        let noAsset = GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [])
        let decision = UpdateInstallPlan.decide(
            release: noAsset, currentVersion: "0.30.0",
            isAppBundle: true, autoInstallEnabled: true)
        #expect(decision == .skipNoAsset)
    }

    @Test func offBeatsNotNewer() {
        // Gate order: opt-in is checked before "newer", so a disabled feature reports skipAutoInstallOff
        // even for a stale release.
        let decision = UpdateInstallPlan.decide(
            release: newerWithAsset(), currentVersion: "0.40.0",
            isAppBundle: false, autoInstallEnabled: false)
        #expect(decision == .skipAutoInstallOff)
    }

    @Test func notNewerBeatsBundleAndAsset() {
        // An equal version returns skipNotNewer before the bundle/asset gates are consulted.
        let noAsset = GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [])
        let decision = UpdateInstallPlan.decide(
            release: noAsset, currentVersion: "0.31.0",
            isAppBundle: false, autoInstallEnabled: true)
        #expect(decision == .skipNotNewer)
    }
}
