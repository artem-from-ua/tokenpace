import AppKit
import Foundation
import TokenPaceKit

// MARK: - UpdateInstallOutcome

/// The result of an auto-install attempt (#123, ADR-0033) — a fail-safe enum, never a thrown error,
/// so the caller can always fall back to the manual "Download" link on any failure. Phase 2 stops at
/// ``dryRunVerified`` (download + verify + unzip proven, no replacement); Phase 3 (#124) adds the
/// terminal ``installedRelaunching`` / ``replaceFailed`` cases.
enum UpdateInstallOutcome: Sendable, Equatable {
    /// Not applicable: not a real `.app` bundle (a `swift run` dev build) — installation is impossible.
    case notApplicable
    /// The download failed (network / HTTP status / write error).
    case downloadFailed(String)
    /// Signature/notarization/Team-ID verification of the downloaded bundle failed — the strongest
    /// safety gate. The bundle is discarded; nothing is replaced.
    case verifyFailed(String)
    /// Unzipping the downloaded archive failed.
    case unzipFailed(String)
    /// **Phase 2 terminal success**: downloaded, verified, and unzipped into a temp directory, but
    /// deliberately **not** installed (no `/Applications` replacement, no relaunch). Carries the temp
    /// path of the verified bundle so the maintainer can inspect it. This is what
    /// `TOKENPACE_UPDATE_DRYRUN` always yields until Phase 3 wires the real replacement.
    case dryRunVerified(bundlePath: String)
}

// MARK: - AppUpdateInstalling

/// The seam the app calls to install a downloaded release (#123) — a protocol so a stub can drive the
/// UI/flow in tests without any network, process, or filesystem side effects (mirrors ``UpdateFetcher``).
@MainActor
protocol AppUpdateInstalling: Sendable {
    /// Download `asset`, verify it is our notarized build, unzip it, and (Phase 3) replace + relaunch.
    /// Returns a fail-safe ``UpdateInstallOutcome``; never throws.
    ///
    /// - Parameters:
    ///   - asset: The installable `.zip` asset chosen by ``UpdateAssetSelector`` (pure, in the kit).
    ///   - expectedTag: The release tag being installed, for logging and the dry-run summary.
    func install(_ asset: GitHubReleaseAsset, expectedTag: String) async -> UpdateInstallOutcome
}

// MARK: - UpdateInstaller

/// The real auto-installer (#123, ADR-0033): downloads the notarized `.zip`, verifies its code
/// signature / notarization / Team ID, and unzips it into a temp directory. **Phase 2 stops there**
/// — the `/Applications` replacement and relaunch land in Phase 3 (#124). Until then every run behaves
/// as a dry run, and `TOKENPACE_UPDATE_DRYRUN` makes that explicit in the logs.
///
/// This is a thin **shell** type, not kit: it does file I/O and spawns `ditto`/`codesign`/`spctl`
/// (platform side-effects, per ADR-0009). The *decision* of whether to install lives in the pure
/// ``UpdateInstallPlan``; this type only executes an already-made decision. All work is gated on
/// ``LaunchAtLoginController/isAppBundle`` — a dev build returns ``notApplicable`` immediately.
///
/// Off-actor discipline mirrors ``UpdateNotifier``: the download uses `URLSession`, and the
/// subprocess/file steps run on a detached task; the `@MainActor` entry point only orchestrates.
@MainActor
struct UpdateInstaller: AppUpdateInstalling {

    /// The Developer ID Team Identifier every legitimate TokenPace build is signed with. The verify
    /// step rejects any downloaded bundle whose signing Team ID is not exactly this — the primary
    /// defense against a substituted (even validly-signed-by-someone-else) archive.
    static let expectedTeamID = "S5A4U9798Y"

    /// Whether the caller forced a dry run via `TOKENPACE_UPDATE_DRYRUN`. In Phase 2 the installer is
    /// *always* a dry run (there is no replace step yet), but reading the flag now lets the same code
    /// path be driven deliberately, and keeps the log wording honest ("dry-run") when it is set.
    private let dryRunForced: Bool

    /// Whether to download the asset through `gh` (the maintainer path) instead of anonymous HTTPS.
    /// Passed in from `AppDelegate.ghAuthEnabled` — the repo is private, so its release assets need the
    /// maintainer's `gh` credentials, mirroring how `GHReleaseFetcher` reads the release JSON. Once the
    /// repo is public the anonymous HTTPS path works and this is `false`.
    private let ghAuthEnabled: Bool

    init(
        ghAuthEnabled: Bool,
        dryRunForced: Bool = ProcessInfo.processInfo.environment["TOKENPACE_UPDATE_DRYRUN"] == "1"
    ) {
        self.ghAuthEnabled = ghAuthEnabled
        self.dryRunForced = dryRunForced
    }

    func install(_ asset: GitHubReleaseAsset, expectedTag: String) async -> UpdateInstallOutcome {
        guard LaunchAtLoginController.isAppBundle else {
            AppLogger.lifecycle.notice("update-install: skip (not an .app bundle)")
            return .notApplicable
        }
        guard let url = URL(string: asset.browserDownloadURL), url.scheme?.lowercased() == "https" else {
            // Should never happen — UpdateAssetSelector already enforces HTTPS — but re-guard before
            // any network I/O rather than trust the caller.
            AppLogger.lifecycle.error("update-install: refusing non-https asset url")
            return .downloadFailed("asset url is not https")
        }

        AppLogger.network.notice(
            "update-install: download started tag=\(expectedTag, privacy: .public) asset=\(asset.name, privacy: .public)")

        // The download (URLSession) and the verify/unzip (subprocesses + file I/O) all happen on a
        // detached task off the main actor; the returned outcome is Sendable, so resuming on the main
        // actor here is safe.
        let teamID = Self.expectedTeamID
        let dryRun = dryRunForced
        let ghAuth = ghAuthEnabled
        return await Task.detached {
            await Self.runPipeline(url: url, assetName: asset.name, tag: expectedTag,
                                   expectedTeamID: teamID, dryRunForced: dryRun, ghAuth: ghAuth)
        }.value
    }

    // MARK: pipeline (off-actor)

    /// The full download → verify → unzip pipeline, off the main actor. Returns a fail-safe outcome;
    /// each step logs its own success/failure. Phase 2 ends at ``dryRunVerified``.
    private nonisolated static func runPipeline(
        url: URL, assetName: String, tag: String, expectedTeamID: String, dryRunForced: Bool, ghAuth: Bool
    ) async -> UpdateInstallOutcome {
        // A scratch directory for this attempt; removed on any exit. Placed under the system temp dir
        // (Phase 3 will instead stage on the /Applications volume for an atomic same-volume rename).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenpace-update-\(tag)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .downloadFailed("scratch dir: \(error.localizedDescription)")
        }

        // 1. Download the zip — via `gh` when GH-auth is on (the repo is private: its assets need the
        //    maintainer's credentials, exactly like the release-JSON fetch in `GHReleaseFetcher`),
        //    otherwise anonymous HTTPS (works once the repo is public).
        let zipURL = scratch.appendingPathComponent(assetName)
        if let failure = await downloadZip(url: url, tag: tag, assetName: assetName, into: zipURL, ghAuth: ghAuth) {
            AppLogger.network.error("update-install: download failed \(failure, privacy: .public)")
            return .downloadFailed(failure)
        }

        // 2. Unzip into the scratch dir (ditto -x -k, the counterpart of the release-time ditto -c -k).
        let unpackDir = scratch.appendingPathComponent("unpacked", isDirectory: true)
        if let failure = unzip(zipURL, into: unpackDir) {
            AppLogger.lifecycle.error("update-install: unzip failed \(failure, privacy: .public)")
            return .unzipFailed(failure)
        }
        guard let bundleURL = firstAppBundle(in: unpackDir) else {
            AppLogger.lifecycle.error("update-install: unzip produced no .app bundle")
            return .unzipFailed("no .app in archive")
        }
        AppLogger.lifecycle.notice("update-install: unzip ok path=\(bundleURL.path, privacy: .public)")

        // 3. Verify signature + notarization + Team ID BEFORE it could ever replace anything.
        if let failure = verify(bundleURL, expectedTeamID: expectedTeamID) {
            AppLogger.lifecycle.error("update-install: verify FAILED reason=\(failure, privacy: .public)")
            return .verifyFailed(failure)
        }
        AppLogger.lifecycle.notice(
            "update-install: verify ok teamID=\(expectedTeamID, privacy: .public) gatekeeper=accepted")

        // 4. Phase 2 stops here — no replacement, no relaunch. Copy the verified bundle out of the
        // auto-removed scratch dir so the maintainer can inspect it after the run.
        let keptBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenPace-update-\(tag).app", isDirectory: true)
        try? FileManager.default.removeItem(at: keptBundle)
        try? FileManager.default.copyItem(at: bundleURL, to: keptBundle)
        AppLogger.lifecycle.notice(
            "update-install: dry-run — would replace /Applications/TokenPace.app with \(tag, privacy: .public) (verified OK)\(dryRunForced ? " [TOKENPACE_UPDATE_DRYRUN]" : "")")
        return .dryRunVerified(bundlePath: keptBundle.path)
    }

    // MARK: download

    /// Fetch the asset into `dest`. `gh` path when `ghAuth` (private-repo assets need credentials),
    /// else anonymous HTTPS. Returns a failure string, or `nil` on success.
    private nonisolated static func downloadZip(
        url: URL, tag: String, assetName: String, into dest: URL, ghAuth: Bool
    ) async -> String? {
        AppLogger.network.notice(
            "update-install: download started tag=\(tag, privacy: .public) asset=\(assetName, privacy: .public) via=\(ghAuth ? "gh" : "https", privacy: .public)")
        let failure = ghAuth
            ? downloadViaGH(tag: tag, assetName: assetName, into: dest)
            : await downloadViaHTTPS(url: url, into: dest)
        if failure == nil {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
            AppLogger.network.notice("update-install: download ok bytes=\(bytes ?? -1, privacy: .public)")
        }
        return failure
    }

    /// Anonymous HTTPS download (works once the repo is public). Returns a failure string, or `nil`.
    private nonisolated static func downloadViaHTTPS(url: URL, into dest: URL) async -> String? {
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return "http status \(http.statusCode)"
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Download a private-repo asset via `gh release download` (uses the maintainer's local `gh`
    /// credentials, like `GHReleaseFetcher`). `--clobber` so a retry overwrites a partial file. Returns
    /// a failure string, or `nil` on success. `gh` binary located the same way `GHReleaseFetcher` does.
    private nonisolated static func downloadViaGH(tag: String, assetName: String, into dest: URL) -> String? {
        guard let gh = GHReleaseFetcher.locateBinary() else { return "gh binary not found" }
        let args = [
            "release", "download", tag,
            "--repo", "\(GitHubReleaseClient.owner)/\(GitHubReleaseClient.repo)",
            "--pattern", assetName,
            "--output", dest.path,
            "--clobber",
        ]
        // Process inherits the environment by default — `gh` needs HOME/keyring to find its token.
        return runTool(gh, args)
    }

    // MARK: subprocess steps

    /// `ditto -x -k <zip> <dest>` — extract a zip archive, preserving the code signature (the inverse
    /// of the release-time `ditto -c -k --keepParent`). Returns a failure string, or `nil` on success.
    private nonisolated static func unzip(_ zip: URL, into dest: URL) -> String? {
        runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path])
    }

    /// Verify the downloaded bundle is our notarized, correctly-signed build. Three checks, all must
    /// pass: `codesign --verify --deep --strict` (signature integrity), the signing authority's Team
    /// ID equals ``expectedTeamID`` (identity), and `spctl --assess --type execute` (Gatekeeper /
    /// notarization). Returns a failure string, or `nil` when all pass.
    private nonisolated static func verify(_ bundle: URL, expectedTeamID: String) -> String? {
        if let failure = runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path]) {
            return "codesign: \(failure)"
        }
        guard let info = runToolCapturing("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path]) else {
            return "codesign -dv failed"
        }
        // `codesign -dv` prints `TeamIdentifier=XXXXXXXXXX` to stderr; match it exactly.
        guard info.contains("TeamIdentifier=\(expectedTeamID)") else {
            return "team id mismatch (expected \(expectedTeamID))"
        }
        if let failure = runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", bundle.path]) {
            return "gatekeeper: \(failure)"
        }
        return nil
    }

    // MARK: helpers

    /// The first `.app` bundle directly inside `dir`, or `nil`. The release archive holds exactly one
    /// (`--keepParent` wraps `TokenPace.app`), so first-match is unambiguous.
    private nonisolated static func firstAppBundle(in dir: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    /// Run a command to completion, discarding output. Returns `nil` on exit code 0, else a short
    /// failure string. Synchronous — callers are already off the main actor.
    private nonisolated static func runTool(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "spawn failed: \(error.localizedDescription)"
        }
        return process.terminationStatus == 0 ? nil : "exit \(process.terminationStatus)"
    }

    /// Run a command and capture its combined stdout+stderr as a string (used to read `codesign -dv`'s
    /// Team-ID line). Returns `nil` if the process could not be spawned.
    private nonisolated static func runToolCapturing(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
