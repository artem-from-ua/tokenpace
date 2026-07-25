import Testing
@testable import TokenPaceKit

@Suite("UpdateMenuState.evaluate")
struct UpdateMenuStateTests {

    /// The installed build under test throughout.
    private let installed = "0.34.0"

    /// Evaluate with sensible defaults, so each test overrides only the axis it exercises.
    private func evaluate(
        latest: String? = nil,
        autoInstall: Bool = true,
        deferred: Bool = false,
        failed: String? = nil,
        pendingWhatsNew: String? = nil
    ) -> UpdateMenuState.Item {
        UpdateMenuState.evaluate(
            installedVersion: installed,
            latestKnownVersion: latest,
            autoInstallEnabled: autoInstall,
            installDeferred: deferred,
            lastFailedInstallVersion: failed,
            pendingWhatsNewVersion: pendingWhatsNew)
    }

    // MARK: hidden

    @Test("No newer version and nothing pending → hidden")
    func nothingToShow() {
        #expect(evaluate() == .hidden)
        #expect(evaluate(latest: "0.34.0") == .hidden)          // same version
        #expect(evaluate(latest: "0.33.0") == .hidden)          // older tag (downgrade guard)
        #expect(evaluate(latest: "not-a-version") == .hidden)   // unparsable → no phantom signal
    }

    @Test("Auto on, newer, not deferred, not failed → hidden (install runs silently)")
    func silentWhileInstalling() {
        #expect(evaluate(latest: "0.35.0", autoInstall: true, deferred: false, failed: nil) == .hidden)
    }

    // MARK: priority 1 — updateFailed (red)

    @Test("Newer + this tag's install failed → updateFailed, regardless of auto/deferred")
    func failedTagWins() {
        #expect(evaluate(latest: "0.35.0", failed: "0.35.0") == .updateFailed)
        // A v-prefixed failed marker still matches a bare latest (parsed compare).
        #expect(evaluate(latest: "0.35.0", failed: "v0.35.0") == .updateFailed)
        // updateFailed pre-empts the "off" and "deferred" branches.
        #expect(evaluate(latest: "0.35.0", autoInstall: false, failed: "0.35.0") == .updateFailed)
        #expect(evaluate(latest: "0.35.0", deferred: true, failed: "0.35.0") == .updateFailed)
    }

    @Test("A failed *older* tag does not gate a newer release — the newer one is retried")
    func failedOlderTagDoesNotGateNewer() {
        // 0.35.0 failed earlier, now 0.36.0 is out: not the failed tag, so it installs silently.
        #expect(evaluate(latest: "0.36.0", autoInstall: true, deferred: false, failed: "0.35.0") == .hidden)
        // With auto off, the newer non-failed tag is a plain "available".
        #expect(evaluate(latest: "0.36.0", autoInstall: false, failed: "0.35.0") == .updateAvailable)
    }

    // MARK: priority 2 — updateAvailable (blue, auto off)

    @Test("Newer + auto install off → updateAvailable")
    func autoOff() {
        #expect(evaluate(latest: "0.35.0", autoInstall: false) == .updateAvailable)
        // Deferred is irrelevant when auto is off (there is no auto-install to defer).
        #expect(evaluate(latest: "0.35.0", autoInstall: false, deferred: true) == .updateAvailable)
    }

    // MARK: priority 3 — updatePending (blue, auto on, deferred)

    @Test("Newer + auto on + deferred (battery/metered/disk) → updatePending")
    func deferred() {
        #expect(evaluate(latest: "0.35.0", autoInstall: true, deferred: true) == .updatePending)
    }

    // MARK: priority 4 — whatsNew (blue) + pre-emption

    @Test("Installed is newest + pending what's new → whatsNew")
    func whatsNew() {
        #expect(evaluate(latest: nil, pendingWhatsNew: "0.34.0") == .whatsNew)
        #expect(evaluate(latest: "0.34.0", pendingWhatsNew: "0.34.0") == .whatsNew)   // latest == installed
    }

    @Test("A newer release pre-empts what's new — only 'New version available' shows")
    func newerPreEmptsWhatsNew() {
        // The user never opened what's new for 0.34.0, and 0.35.0 shipped: newer wins.
        #expect(
            evaluate(latest: "0.35.0", autoInstall: false, pendingWhatsNew: "0.34.0") == .updateAvailable)
        // Same with auto on + failed: the newer-tag failure still wins over the stale what's new.
        #expect(
            evaluate(latest: "0.35.0", failed: "0.35.0", pendingWhatsNew: "0.34.0") == .updateFailed)
    }
}
