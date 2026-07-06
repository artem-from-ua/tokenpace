import Foundation
import TokenPaceKit

// MARK: - ClaudeCLIRefresher

/// Production ``DelegatedRefresher`` (ADR-0017): spawns the `claude` CLI so Claude Code refreshes
/// and rewrites its **own** Keychain credentials, then judges success by whether the stored
/// `expiresAt` moved forward. TokenPace itself never writes the Keychain and never touches the
/// `refreshToken` — Claude Code owns the rotation.
///
/// The command (verified in the issue #8 spike): `claude --model haiku -p '/usage'`.
/// `/usage` is handled by a local command handler — nothing is sent to a model and no
/// subscription usage is consumed (confirmed both by an isolated before/after utilization
/// measurement and by the session transcript containing zero assistant/API entries);
/// `--model haiku` is a guard in case a future CLI ever forwards the prompt after all.
/// `--bare` must NOT be used: it disables OAuth/Keychain entirely, so no refresh would happen.
///
/// This is the codebase's only subprocess spawn — a shell-side platform seam like
/// `ProcessClaudeActivityProbe`, injected into `PollingEngine` behind the kit protocol.
struct ClaudeCLIRefresher: DelegatedRefresher {

    /// Locations probed for the `claude` binary, in order. The app runs under launchd, whose
    /// PATH is minimal, so an explicit list beats a `$PATH` lookup (the analogs probe the same
    /// spots; `~/.claude/local` is the CLI's self-managed install).
    static let binaryCandidates = [
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
    ]

    /// Arguments for the refresh run — see the type doc for why exactly these.
    static let arguments = ["--model", "haiku", "-p", "/usage"]

    /// Hard cap on the CLI run, after which it is terminated (SIGTERM, then SIGKILL after
    /// ``killGrace``). The spike measured ~1.5 s normally; 30 s leaves room for a cold start.
    static let timeout: TimeInterval = 30

    /// How long a terminated CLI gets to exit before the SIGKILL escalation.
    static let killGrace: TimeInterval = 5

    func refresh() async -> DelegatedRefreshOutcome {
        guard let binary = Self.locateBinary() else {
            AppLogger.keychain.error("delegated refresh: claude binary not found")
            return .cliNotFound
        }
        // `credentials()` decodes a stale-but-readable item fine; an unreadable store yields nil
        // and any post-run credentials then count as "appeared" (still a successful refresh).
        let before = (try? TokenProvider.credentials())?.expiresAt

        AppLogger.keychain.notice("delegated refresh: launching cli, path=\(binary, privacy: .public)")
        switch await Self.run(binary: binary) {
        case .timedOut:
            AppLogger.keychain.error("delegated refresh: cli timed out after \(Int(Self.timeout), privacy: .public)s")
            return .timedOut
        case let .failed(exitCode):
            AppLogger.keychain.error("delegated refresh: cli exited status=\(exitCode.map(String.init) ?? "unknown", privacy: .public)")
            return .failed(exitCode: exitCode)
        case .completed:
            break
        }

        let after = (try? TokenProvider.credentials())?.expiresAt
        let advanced: Bool
        switch (before, after) {
        case let (before?, after?): advanced = after > before
        case (nil, .some):          advanced = true
        default:                    advanced = false
        }
        if advanced {
            AppLogger.keychain.notice("delegated refresh: expiresAt advanced")
            return .refreshed
        }
        AppLogger.keychain.error("delegated refresh: cli exited 0 but keychain unchanged")
        return .unchanged
    }

    // MARK: binary discovery

    /// The first existing executable among ``binaryCandidates``, tilde-expanded.
    private static func locateBinary() -> String? {
        binaryCandidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: subprocess

    private enum RunResult: Sendable {
        case completed
        case timedOut
        case failed(exitCode: Int32?)
    }

    /// `Process` is not `Sendable`; this box hands one instance to the termination continuation,
    /// the timeout race and the kill escalation. Safe: `terminate()`, `isRunning` and
    /// `processIdentifier` are documented thread-safe, and only one task mutates the process.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    /// Run the CLI to completion or ``timeout``, whichever comes first.
    ///
    /// stdin/stdout/stderr all go to `/dev/null`: stdin so the CLI skips its "waiting for piped
    /// input" grace period, the outputs because only the Keychain side-effect matters (and the
    /// report could mention account details). The working directory is a fresh empty scratch dir
    /// so the CLI picks up no project context (CLAUDE.md, hooks) from wherever the app started.
    /// The token itself never appears in arguments, environment, or logs.
    private static func run(binary: String) async -> RunResult {
        let box = ProcessBox()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenpace-refresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        box.process.executableURL = URL(fileURLWithPath: binary)
        box.process.arguments = arguments
        box.process.currentDirectoryURL = scratch
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = FileHandle.nullDevice

        return await withTaskGroup(of: RunResult.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    // The handler is installed before run() so an instant exit cannot be missed.
                    box.process.terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus == 0
                            ? .completed
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
                return Task.isCancelled ? .completed : .timedOut
            }

            let first = await group.next() ?? .failed(exitCode: nil)
            if case .timedOut = first {
                // SIGTERM now; SIGKILL if it lingers. The group then waits for the termination
                // continuation, so this function returns only once the process is truly gone.
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
