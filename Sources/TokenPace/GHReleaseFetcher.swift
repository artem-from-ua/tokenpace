import Foundation
import TokenPaceKit

// MARK: - GHReleaseFetcher

/// The maintainer-path ``UpdateFetcher`` (#37): spawns `gh api …/releases/latest` so the locally
/// authenticated `gh` reads the **private** repo's latest release from its own keyring credentials.
/// Selected at runtime when `TOKENPACE_GH_AUTH` is set; users without it take the anonymous
/// ``HTTPUpdateFetcher`` instead.
///
/// Stdout is the raw REST JSON, flowing through the **same** pure ``GitHubReleaseDecoder`` as the
/// HTTP path. Differs from ``ClaudeCLIRefresher`` in three ways: stdout is **captured**; the child
/// **inherits the environment** (`gh` needs `HOME`/keyring); no scratch working directory (`gh` reads
/// no project context). The token never appears in our arguments, environment, or logs.
struct GHReleaseFetcher: UpdateFetcher {

    /// The app runs under launchd, whose PATH is minimal, so an explicit list beats a `$PATH` lookup.
    static let binaryCandidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "~/.local/bin/gh",
    ]

    /// `gh api repos/<owner>/<repo>/releases/latest` — prints the raw REST response to stdout.
    static let arguments = ["api", "repos/\(GitHubReleaseClient.owner)/\(GitHubReleaseClient.repo)/releases/latest"]

    /// Hard cap on the `gh` run (SIGTERM, then SIGKILL after ``killGrace``). A local `gh api` call
    /// is sub-second; 20 s leaves room for a slow network.
    static let timeout: TimeInterval = 20

    /// How long a terminated `gh` gets to exit before the SIGKILL escalation.
    static let killGrace: TimeInterval = 5

    func fetchLatestReleaseJSON() async throws -> Data {
        guard let binary = Self.locateBinary() else {
            throw UpdateFetchError.unavailable("gh binary not found")
        }
        AppLogger.network.notice("update: gh path, launching \(binary, privacy: .public)")
        switch await Self.run(binary: binary) {
        case let .completed(data):
            return data
        case .timedOut:
            throw UpdateFetchError.unavailable("gh timed out")
        case let .failed(exitCode):
            // `gh api` exits non-zero for a missing release / HTTP error; we do not parse its stderr
            // for the status code (brittle) — the shell treats `.unavailable` like `.notFound`.
            throw UpdateFetchError.unavailable("gh exited status=\(exitCode.map(String.init) ?? "unknown")")
        }
    }

    // MARK: binary discovery

    /// Also used by ``UpdateInstaller`` to locate `gh` for private-repo asset downloads.
    static func locateBinary() -> String? {
        binaryCandidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: subprocess

    private enum RunResult: Sendable {
        case completed(Data)
        case timedOut
        case failed(exitCode: Int32?)
    }

    /// `Process`/`Pipe` are not `Sendable`; this box hands one instance to the termination
    /// continuation, the stdout reader, the timeout race and the kill escalation. Safe:
    /// `terminate()`, `isRunning` and `processIdentifier` are documented thread-safe.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()
    }

    /// The reader unblocks once the child closes the pipe at exit, draining the full payload without
    /// a separate reader task, so a payload larger than the pipe buffer can never deadlock. stdin
    /// goes to `/dev/null` so `gh` never waits on input; environment is inherited for `HOME`/keyring.
    private static func run(binary: String) async -> RunResult {
        let box = ProcessBox()
        box.process.executableURL = URL(fileURLWithPath: binary)
        box.process.arguments = arguments
        box.process.currentDirectoryURL = FileManager.default.temporaryDirectory
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = box.stdout
        box.process.standardError = FileHandle.nullDevice
        // Inherit the environment verbatim (gh needs HOME + its config/keyring); do not null it out.

        return await withTaskGroup(of: RunResult.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
                    // Install the handler before run() so an instant exit cannot be missed.
                    box.process.terminationHandler = { process in
                        let data = (try? box.stdout.fileHandleForReading.readToEnd()) ?? Data()
                        continuation.resume(returning: process.terminationStatus == 0
                            ? .completed(data)
                            : .failed(exitCode: process.terminationStatus))
                    }
                    do {
                        try box.process.run()
                    } catch {
                        box.process.terminationHandler = nil
                        continuation.resume(returning: .failed(exitCode: nil))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return Task.isCancelled ? .completed(Data()) : .timedOut
            }

            let first = await group.next() ?? .failed(exitCode: nil)
            if case .timedOut = first {
                // SIGTERM now; SIGKILL if it lingers. The group then waits for the termination
                // continuation, so this returns only once the process is truly gone.
                box.process.terminate()
                Task.detached {
                    try? await Task.sleep(for: .seconds(killGrace))
                    if box.process.isRunning {
                        kill(box.process.processIdentifier, SIGKILL)
                    }
                }
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - StubUpdateFetcher (verification only — TOKENPACE_FAKE_LATEST)

/// A canned `/releases/latest` JSON with a caller-supplied tag, without any network or process.
/// Selected under `TOKENPACE_FAKE_LATEST`, so the "update available" / "up to date" UI branches can
/// be exercised on demand. Never used in normal runs.
struct StubUpdateFetcher: UpdateFetcher {
    let tag: String
    func fetchLatestReleaseJSON() async throws -> Data {
        let url = "https://github.com/\(GitHubReleaseClient.owner)/\(GitHubReleaseClient.repo)/releases/tag/\(tag)"
        return Data(#"{"tag_name": "\#(tag)", "html_url": "\#(url)"}"#.utf8)
    }
}
