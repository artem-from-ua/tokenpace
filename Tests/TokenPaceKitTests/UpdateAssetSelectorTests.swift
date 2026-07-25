import Testing
import Foundation
@testable import TokenPaceKit

@Suite("UpdateAssetSelector.selectZIP")
struct UpdateAssetSelectorTests {

    private func asset(_ name: String, _ url: String) -> GitHubReleaseAsset {
        GitHubReleaseAsset(name: name, browserDownloadURL: url)
    }

    private func release(tag: String, assets: [GitHubReleaseAsset]) -> GitHubRelease {
        GitHubRelease(tagName: tag, htmlURL: "https://example.com/\(tag)", assets: assets)
    }

    /// A canonical GitHub download URL for a version-named zip.
    private func downloadURL(_ tag: String, _ name: String) -> String {
        "https://github.com/artem-from-ua/tokenpace/releases/download/\(tag)/\(name)"
    }

    @Test func picksVersionNamedZip() {
        let a = asset("TokenPace-0.31.0.zip", downloadURL("v0.31.0", "TokenPace-0.31.0.zip"))
        let r = release(tag: "v0.31.0", assets: [a])
        #expect(UpdateAssetSelector.selectZIP(from: r) == a)
    }

    @Test func picksTheZipAmongSeveralAssets() {
        let zip = asset("TokenPace-0.31.0.zip", downloadURL("v0.31.0", "TokenPace-0.31.0.zip"))
        let r = release(tag: "v0.31.0", assets: [
            asset("TokenPace-0.31.0.zip.sha256", downloadURL("v0.31.0", "TokenPace-0.31.0.zip.sha256")),
            zip,
            asset("Source code (zip)", downloadURL("v0.31.0", "src.zip")),
        ])
        #expect(UpdateAssetSelector.selectZIP(from: r) == zip)
    }

    @Test func normalizesVPrefixedTag() {
        // Tag carries the `v`, asset name does not — they must still line up.
        let a = asset("TokenPace-0.31.0.zip", downloadURL("v0.31.0", "TokenPace-0.31.0.zip"))
        #expect(UpdateAssetSelector.selectZIP(from: release(tag: "v0.31.0", assets: [a])) == a)
        #expect(UpdateAssetSelector.selectZIP(from: release(tag: "0.31.0", assets: [a])) == a)
    }

    @Test func nilWhenNoZipAsset() {
        let r = release(tag: "v0.31.0", assets: [
            asset("notes.txt", downloadURL("v0.31.0", "notes.txt")),
        ])
        #expect(UpdateAssetSelector.selectZIP(from: r) == nil)
    }

    @Test func nilWhenAssetNameMismatchesVersion() {
        // A zip that isn't ours / for a different version must not be picked.
        let r = release(tag: "v0.31.0", assets: [
            asset("TokenPace-0.30.0.zip", downloadURL("v0.31.0", "TokenPace-0.30.0.zip")),
            asset("SomethingElse-0.31.0.zip", downloadURL("v0.31.0", "SomethingElse-0.31.0.zip")),
        ])
        #expect(UpdateAssetSelector.selectZIP(from: r) == nil)
    }

    @Test func rejectsNonHTTPSURL() {
        // Correct name, but a plain-http (or other-scheme) URL must never be selected.
        let r = release(tag: "v0.31.0", assets: [
            asset("TokenPace-0.31.0.zip", "http://github.com/.../TokenPace-0.31.0.zip"),
        ])
        #expect(UpdateAssetSelector.selectZIP(from: r) == nil)
    }

    @Test func nilWhenTagUnparsable() {
        let a = asset("TokenPace-0.31.0.zip", downloadURL("v0.31.0", "TokenPace-0.31.0.zip"))
        #expect(UpdateAssetSelector.selectZIP(from: release(tag: "nightly", assets: [a])) == nil)
    }

    @Test func nilWhenNoAssets() {
        #expect(UpdateAssetSelector.selectZIP(from: release(tag: "v0.31.0", assets: [])) == nil)
    }

    @Test func expectedAssetNameFromTag() {
        #expect(UpdateAssetSelector.expectedAssetName(forTag: "v0.31.0") == "TokenPace-0.31.0.zip")
        #expect(UpdateAssetSelector.expectedAssetName(forTag: "1.2.3") == "TokenPace-1.2.3.zip")
        #expect(UpdateAssetSelector.expectedAssetName(forTag: "not-a-version") == nil)
    }
}
