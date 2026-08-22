import Foundation
import TokenPaceKit

// MARK: - ClaudeCLIRefresher

/// Production ``DelegatedRefresher`` (ADR-0017): spawns the `claude` CLI so Claude Code refreshes
/// and rewrites its **own** Keychain credentials, then judges success by whether the stored
/// `expiresAt` moved forward. TokenPace itself never writes the Keychain and never touches the
/// `refreshToken` — Claude Code owns the rotation.
///
/// The command: `claude --model haiku -p '/usage'`. `/usage` is a local command handler — nothing is
/// sent to a model and no subscription usage is consumed; `--model haiku` guards against a future
/// CLI forwarding the prompt after all. **`--safe-mode` is required**: it disables the user's
/// customizations (hooks, plugins, MCP servers, CLAUDE.md) while keeping auth/Keychain, because the
/// spawned `claude` runs under this GUI app's TCC responsibility — without it, a user's SessionStart
/// hook touching a File Provider domain triggers a permission prompt attributed to *TokenPace*
/// (#183). **`--bare` must NOT be used**: it disables OAuth/Keychain entirely, so no refresh happens.
///
/// This is the codebase's only `claude` spawn, injected into `PollingEngine` behind the kit protocol.
struct ClaudeCLIRefresher: DelegatedRefresher {

    /// The app runs under launchd, whose PATH is minimal, so an explicit list beats a `$PATH` lookup.
    static let binaryCandidates = [
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
    ]

    /// See the type doc for why exactly these — `--safe-mode` first so the spawn can't run arbitrary
    /// user code under this app's TCC responsibility (#183).
    static let arguments = ["--safe-mode", "--model", "haiku", "-p", "/usage"]

    /// Hard cap on the CLI run, after which it is terminated (SIGTERM, then SIGKILL after
    /// ``killGrace``). ~1.5 s normally; 30 s leaves room for a cold start.
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

    /// stdin/stdout/stderr all go to `/dev/null`: stdin so the CLI skips its "waiting for piped
    /// input" grace period, the outputs because only the Keychain side-effect matters. The working
    /// directory is a fresh empty scratch dir so the CLI picks up no *project-local* context (a
    /// stray CLAUDE.md) — cwd does NOT suppress *global* hooks/plugins, those are disabled by
    /// `--safe-mode` (#183). The token itself never appears in arguments, environment, or logs.
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
