import Testing
import Foundation
@testable import TokenPaceKit

/// Covers the explanatory counterpart to `decide` (#221): which environment gates are reported as
/// blocking, and how they read as one sentence. `decide` stops at the first closed gate, so the
/// multi-reason cases below are exactly what it cannot express.
@Suite("UpdateInstallPlan.deferralReasons")
struct UpdateDeferralReasonTests {

    private let zip = GitHubReleaseAsset(
        name: "TokenPace-0.31.0.zip",
        browserDownloadURL: "https://github.com/artem-from-ua/tokenpace/releases/download/v0.31.0/TokenPace-0.31.0.zip",
        size: 900_000)   // ~0.9 MB, like the real archive

    private func newerWithAsset() -> GitHubRelease {
        GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [zip])
    }

    /// Ample free space (100 GB) — the default so a test overrides only the gate it exercises.
    private let ampleSpace = 100 * 1_000_000_000

    /// Below the 5 GB post-download headroom, so the space gate closes.
    private let crampedSpace = 1 * 1_000_000_000

    /// Reasons with favourable environment defaults, so a test overrides only what it exercises.
    private func reasons(
        release: GitHubRelease? = nil, current: String = "0.30.0",
        isAppBundle: Bool = true, autoInstall: Bool = true,
        freeDiskBytes: Int? = nil, onACPower: Bool = true, metered: Bool = false
    ) -> [UpdateDeferralReason] {
        UpdateInstallPlan.deferralReasons(
            release: release ?? newerWithAsset(), currentVersion: current,
            isAppBundle: isAppBundle, autoInstallEnabled: autoInstall,
            freeDiskBytes: freeDiskBytes ?? ampleSpace,
            onACPower: onACPower, networkIsMetered: metered)
    }

    // MARK: nothing blocking

    @Test("All gates pass → no reasons")
    func noneWhenInstallable() {
        #expect(reasons().isEmpty)
    }

    // MARK: one reason each

    @Test("On battery → onBattery")
    func battery() {
        #expect(reasons(onACPower: false) == [.onBattery])
    }

    @Test("Metered network → meteredNetwork")
    func metered() {
        #expect(reasons(metered: true) == [.meteredNetwork])
    }

    @Test("Not enough free space → insufficientSpace")
    func space() {
        #expect(reasons(freeDiskBytes: crampedSpace) == [.insufficientSpace])
    }

    // MARK: several at once — the cases `decide` cannot report

    @Test("Battery + metered → both, in allCases order")
    func batteryAndMetered() {
        #expect(reasons(onACPower: false, metered: true) == [.onBattery, .meteredNetwork])
    }

    @Test("All three gates closed → all three, in allCases order")
    func allThree() {
        #expect(reasons(freeDiskBytes: crampedSpace, onACPower: false, metered: true)
            == [.onBattery, .meteredNetwork, .insufficientSpace])
    }

    /// The order is `allCases`, not `decide`'s gate order (space first) — so the sentence the UI
    /// composes doesn't reshuffle between renders.
    @Test("Order follows allCases, not the gate order of decide")
    func stableOrder() {
        #expect(reasons(freeDiskBytes: crampedSpace, onACPower: false).first == .onBattery)
    }

    // MARK: settled-no cases report nothing

    @Test("Auto-install off → no reasons (settled no, not a deferral)")
    func autoInstallOff() {
        #expect(reasons(autoInstall: false, onACPower: false).isEmpty)
    }

    @Test("Not newer → no reasons")
    func notNewer() {
        #expect(reasons(current: "0.31.0", onACPower: false).isEmpty)
    }

    @Test("Dev build (not an .app bundle) → no reasons")
    func notAppBundle() {
        #expect(reasons(isAppBundle: false, onACPower: false).isEmpty)
    }

    @Test("Release without an installable asset → no reasons")
    func noAsset() {
        let assetless = GitHubRelease(tagName: "v0.31.0", htmlURL: "https://example.com/x", assets: [])
        #expect(reasons(release: assetless, onACPower: false).isEmpty)
    }

    // MARK: space gate counts the asset, like decide

    @Test("Space gate counts the asset size, matching decide")
    func spaceCountsAsset() {
        // Exactly the threshold plus the asset → fits, so space is not reported.
        let exact = UpdateInstallPlan.minFreeBytesAfterDownload + zip.size
        #expect(reasons(freeDiskBytes: exact).isEmpty)
        #expect(reasons(freeDiskBytes: exact - 1) == [.insufficientSpace])
    }
}

// MARK: - pendingExplanation

@Suite("UpdateDeferralReason.pendingExplanation")
struct PendingExplanationTests {

    @Test("No reasons → nil (nothing to explain)")
    func none() {
        #expect(UpdateDeferralReason.pendingExplanation(for: []) == nil)
    }

    @Test("One reason → single clause")
    func one() {
        #expect(UpdateDeferralReason.pendingExplanation(for: [.onBattery])
            == "Update pending because your Mac is on battery.")
    }

    @Test("Two reasons → joined with 'and', no comma")
    func two() {
        #expect(UpdateDeferralReason.pendingExplanation(for: [.onBattery, .meteredNetwork])
            == "Update pending because your Mac is on battery and the network is metered.")
    }

    @Test("Three reasons → comma-separated, 'and' before the last")
    func three() {
        #expect(UpdateDeferralReason.pendingExplanation(
            for: [.onBattery, .meteredNetwork, .insufficientSpace])
            == "Update pending because your Mac is on battery, the network is metered "
             + "and there isn't enough free disk space.")
    }
}
