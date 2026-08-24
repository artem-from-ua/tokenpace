import Foundation
import TokenPaceKit

// MARK: - CodexQuotaSource

/// Where a Codex quota read comes from. The seam a stub replaces, so **no process is spawned under
/// any stub** — a verification scenario must never depend on the maintainer having `codex` installed,
/// signed in, and on a particular plan.
protocol CodexQuotaSource: Sendable {
    func read() async throws -> CodexQuotaSnapshot
    /// What the Troubleshoot window says about this source: the binary in use, the version, the last
    /// successful read. Never the account email, never `codexHome`, never a response body.
    func diagnostics() async -> CodexQuotaDiagnostics
}

// MARK: - CodexQuotaDiagnostics

/// The facts Troubleshoot shows about the Codex collector.
struct CodexQuotaDiagnostics: Sendable, Equatable {
    /// The raw `resetsAt` of every window the last successful read reported, in report order.
    ///
    /// Kept because a window that has not started draws **no** countdown, so this is the only surface
    /// left carrying what the server actually sent — and that value is the evidence for the
    /// not-started reading in the first place.
    var lastResets: [Date?] = []
    /// The executable actually used, or `nil` when none was found — the candidates are then listed
    /// instead, so "not found" names the paths that were tried rather than leaving the user guessing.
    var binaryPath: String?
    /// Parsed out of `initialize`'s `userAgent`. `nil` until the first handshake.
    var version: String?
    /// When the last read succeeded, and how long it took.
    var lastSuccess: Date?
    var lastLatency: TimeInterval?
    /// The last failure, already reduced to a sentence.
    var lastError: String?
}

// MARK: - CodexAppServer

/// Reads the Codex subscription quota by running `codex app-server` and speaking JSON-RPC over its
/// stdio.
///
/// An `actor` because a tick's restart-and-retry, the cooldown clock and the diagnostics are shared
/// mutable state that the poll loop and the Troubleshoot window both reach for.
///
/// ## One process per read, not one held open
///
/// Measured on codex-cli 0.148.0, this machine: **spawn through the `initialize` response is 0.03 s**
/// (median of 3), while one `account/rateLimits/read` on an already-warm process is **0.44 s** (median
/// of 6) — the read is a network round trip and the spawn is not. Holding a child process open
/// between polls would therefore save about 6 % of one read, three minutes apart, in exchange for a
/// permanent subprocess on the user's machine plus the sleep/wake and orphan handling that comes with
/// owning one. The process is started for a read and gone before the function returns.
actor CodexAppServer: CodexQuotaSource {

    /// The app runs under launchd, whose PATH is minimal, so an explicit list beats a `$PATH` lookup —
    /// the same reason the `claude` and `gh` spawners carry one.
    static let binaryCandidates = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.local/bin/codex",
        "~/.codex/bin/codex",
    ]

    /// The subcommand that speaks JSON-RPC over stdio.
    static let arguments = ["app-server"]

    /// Hard cap on one read, start to finish. The measured cost is ~0.5 s; 20 s leaves room for a cold
    /// filesystem and a slow network without letting a wedged child hold the tick.
    static let timeout: TimeInterval = 20

    /// How long a terminated child gets to exit before the SIGKILL escalation.
    static let killGrace: TimeInterval = 3

    /// How long the collector stays quiet after a tick has already spent its one retry. Without it a
    /// broken install — a `codex` that dies on start, say — becomes a process spawn every poll, for
    /// as long as the app runs.
    static let cooldown: TimeInterval = 300

    /// The method whose absence means "this Codex predates the feature". Named once so the detection
    /// and the error carry the same string.
    static let rateLimitsMethod = "account/rateLimits/read"

    private var diag = CodexQuotaDiagnostics()
    /// When set, no read is attempted before this instant.
    private var cooldownUntil: Date?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func diagnostics() -> CodexQuotaDiagnostics {
        var d = diag
        if d.binaryPath == nil { d.binaryPath = Self.locateBinary() }
        return d
    }

    /// One tick's read: **one attempt, one retry, then a cooldown.**
    ///
    /// The retry exists because the failure this most often sees is a child that dies during start-up,
    /// which a second attempt clears. Anything that survives two attempts is a condition a third would
    /// not fix either, so the collector stands down for ``cooldown`` rather than spawning again in
    /// three minutes.
    func read() async throws -> CodexQuotaSnapshot {
        if let until = cooldownUntil, now() < until { throw CodexQuotaError.processDied }

        do {
            return try await attempt()
        } catch let first as CodexQuotaError {
            // A missing binary and an out-of-date Codex are both stable facts about the install; a
            // second spawn re-learns them at the cost of another process.
            if case .cliNotFound = first { record(first); throw first }
            if case .methodUnsupported = first { record(first); throw first }
            do {
                return try await attempt()
            } catch {
                cooldownUntil = now().addingTimeInterval(Self.cooldown)
                record(error)
                throw error
            }
        }
    }

    private func record(_ error: any Error) {
        diag.lastError = (error as? CodexQuotaError).map(Self.describe) ?? "\(error)"
    }

    /// The Troubleshoot sentence for a failure. Deliberately narrow: an `rpc` message is the server's
    /// own text and is shown, but no branch here can reach a response body or an account identifier.
    static func describe(_ error: CodexQuotaError) -> String {
        switch error {
        case .cliNotFound:      return "codex not found"
        case .handshakeFailed:  return "handshake failed"
        case .processDied:      return "codex exited during the read"
        case .timedOut:         return "timed out after \(Int(timeout))s"
        case let .methodUnsupported(method):
            return "this codex has no \(method) — update it"
        case .notSignedIn:      return "not signed in to codex"
        case let .rpc(code, message): return "codex error \(code): \(message)"
        case .malformedResponse: return "unreadable response"
        }
    }

    // MARK: One attempt

    private func attempt() async throws -> CodexQuotaSnapshot {
        guard let binary = Self.locateBinary() else {
            diag.binaryPath = nil
            throw CodexQuotaError.cliNotFound
        }
        diag.binaryPath = binary
        let started = now()
        let clientVersion = TokenPaceKit.version

        // **Off the actor, and off the main thread.** The session's pipe reads block the calling
        // thread; run on the actor's executor they would stall it, and this app's actors are reached
        // from `@MainActor`, so a blocked read freezes the UI for the length of the round trip.
        // `Task.detached` puts the whole exchange on a background thread, and only its value comes
        // back — the session itself never crosses the boundary.
        let outcome = try await Task.detached(priority: .utility) {
            () throws -> (version: String?, payload: Data) in
            let session = try CodexRPCSession(binary: binary)
            defer { session.shutDown() }
            // The Codex version rides in `initialize`'s `userAgent`; there is no protocol version and
            // no capability list to negotiate against. That is also why nothing runs `codex
            // --version` — a second spawn to learn what the first already said.
            let version = try session.handshake(
                clientVersion: clientVersion, timeout: Self.timeout)
            // `initialized` is deliberately not sent: probed, `account/*` answers without it.
            let payload = try session.call(method: Self.rateLimitsMethod, timeout: Self.timeout)
            return (version, payload)
        }.value

        diag.version = outcome.version
        guard let decoded = try? JSONDecoder()
            .decode(CodexRateLimitsResult.self, from: outcome.payload) else {
            throw CodexQuotaError.malformedResponse
        }
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decoded)
        diag.lastResets = snapshot.windows.map(\.resetsAt)
        diag.lastSuccess = now()
        diag.lastLatency = diag.lastSuccess?.timeIntervalSince(started)
        diag.lastError = nil
        cooldownUntil = nil
        return snapshot
    }

    /// The version out of `TokenPace/0.148.0 (Mac OS 15.7.9; arm64) …` — the first slash-separated
    /// token's tail, up to the first space.
    static func version(fromUserAgent userAgent: String) -> String? {
        guard let slash = userAgent.firstIndex(of: "/") else { return nil }
        let tail = userAgent[userAgent.index(after: slash)...]
        let version = tail.prefix { !$0.isWhitespace }
        return version.isEmpty ? nil : String(version)
    }

    static func locateBinary() -> String? {
        binaryCandidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - CodexRPCSession

/// One `codex app-server` process and the framing around its stdio.
///
/// Not an actor: it is created, used and shut down inside a single ``CodexAppServer/attempt()``, so it
/// is already confined to that one task. `@unchecked Sendable` for the same reason
/// `ClaudeCLIRefresher.ProcessBox` is — `Process`'s `terminate()`/`isRunning`/`processIdentifier` are
/// documented thread-safe and only one task drives this.
final class CodexRPCSession: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var pending = Data()
    private var nextID = 1

    init(binary: String) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = CodexAppServer.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        // stderr to /dev/null: it is the child's own diagnostics, it can name paths inside
        // `codexHome`, and nothing here reads it.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CodexQuotaError.processDied
        }
    }

    func shutDown() {
        guard process.isRunning else { return }
        try? stdin.fileHandleForWriting.close()
        process.terminate()
        let pid = process.processIdentifier
        // SIGTERM, then SIGKILL if it lingers — the escalation `ClaudeCLIRefresher` uses. Only ever
        // aimed at the pid this object itself spawned.
        Task.detached {
            try? await Task.sleep(for: .seconds(CodexAppServer.killGrace))
            kill(pid, SIGKILL)
        }
    }

    /// Send one request and wait for **the response carrying its id**.
    ///
    /// **Matching by id is required, not defensive.** The server emits unsolicited notifications —
    /// `remoteControl/status/changed` arrives within milliseconds of `initialize`, before that
    /// method's own response — so a reader that took "the next line" would hand a notification back as
    /// a result. A line whose id is not the one awaited is **dropped silently**; logging it would let
    /// a chatty server fill the log with traffic no one asked for.
    func call(method: String, params: [String: Any] = [:], timeout: TimeInterval) throws -> Data {
        let id = nextID
        nextID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else {
            throw CodexQuotaError.malformedResponse
        }
        line.append(0x0A)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: line)
        } catch {
            throw CodexQuotaError.processDied
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let object = try readLine(before: deadline) else { continue }
            guard let responseID = object["id"] as? Int, responseID == id else { continue }
            if let error = object["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? 0
                let message = error["message"] as? String ?? ""
                if CodexQuotaError.isUnsupportedMethod(
                    code: code, message: message, method: method) {
                    throw CodexQuotaError.methodUnsupported(method: method)
                }
                throw CodexQuotaError.rpc(code: code, message: message)
            }
            guard let result = object["result"],
                  let encoded = try? JSONSerialization.data(withJSONObject: result) else {
                throw method == "initialize"
                    ? CodexQuotaError.handshakeFailed : CodexQuotaError.malformedResponse
            }
            return encoded
        }
        throw CodexQuotaError.timedOut
    }

    /// `initialize`, returning the Codex version parsed out of the reply's `userAgent`.
    func handshake(clientVersion: String, timeout: TimeInterval) throws -> String? {
        let result = try call(
            method: "initialize",
            params: ["clientInfo": ["name": "TokenPace", "title": "TokenPace",
                                    "version": clientVersion]],
            timeout: timeout)
        struct Handshake: Decodable { let userAgent: String? }
        // `codexHome` is in this reply and is deliberately not decoded — it is a path into the user's
        // home directory and nothing here has a use for it.
        let decoded = try? JSONDecoder().decode(Handshake.self, from: result)
        return decoded?.userAgent.flatMap(CodexAppServer.version(fromUserAgent:))
    }

    /// One decoded JSON line, or `nil` when this poll of the pipe produced no complete line yet.
    private func readLine(before deadline: Date) throws -> [String: Any]? {
        while let newline = pending.firstIndex(of: 0x0A) {
            let raw = pending[..<newline]
            pending.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                return object
            }
            // A line that is not JSON-RPC at all is dropped like an unmatched id — the server owns its
            // stdout and may print something we do not model.
        }
        guard Date() < deadline else { throw CodexQuotaError.timedOut }
        let chunk = stdout.fileHandleForReading.availableData
        guard !chunk.isEmpty else {
            // EOF: the child closed stdout, which for this server means it is gone.
            throw CodexQuotaError.processDied
        }
        pending.append(chunk)
        return nil
    }
}


// MARK: - StubCodexQuotaSource

/// A canned ``CodexQuotaSource`` for the verification scenarios. **Spawns nothing** — a stub must
/// render identically on a machine that has never installed `codex`.
struct StubCodexQuotaSource: CodexQuotaSource {

    enum Outcome: Sendable {
        /// `(usedPercent, windowDurationSeconds)` per window, in report order.
        case windows([(Double, Int)])
        /// Windows that have not started: `usedPercent 0` and a reset the server recomputes as `now`
        /// plus the window's own length on every read, so it never ticks down. The stub reproduces
        /// that by deriving the reset from its own clock at read time, exactly as the server does.
        case notStarted([Int])
        /// The same not-started shape with the account flagged reached — the one combination a live
        /// account cannot be put into on demand, and the one the flags exist to catch: every window
        /// reads spotless while the server has already said no.
        case notStartedReached([Int])
        case failure(CodexQuotaError)
    }

    let outcome: Outcome
    let now: @Sendable () -> Date

    init(_ outcome: Outcome, now: @escaping @Sendable () -> Date) {
        self.outcome = outcome
        self.now = now
    }

    func read() async throws -> CodexQuotaSnapshot {
        switch outcome {
        case let .failure(error):
            throw error
        case let .windows(specs):
            let base = now()
            return CodexQuotaSnapshot(
                windows: specs.map { used, duration in
                    // The reset sits 45 % of the window ahead, so the elapsed fraction lands
                    // mid-window and each scenario's pacing verdict is the one its name promises.
                    CodexQuotaWindow(
                        utilization: used,
                        durationSeconds: duration,
                        resetsAt: base.addingTimeInterval(Double(duration) * 0.45))
                },
                planLabel: "Plus")
        case let .notStarted(durations):
            return notStartedSnapshot(durations, reachedType: nil)
        // `rateLimitReachedType` carries the server's own word; `spendControlReached` stays `nil`, so
        // the scenario also proves the string alone gates the row — a stub setting both would pass
        // even if only the Bool were consulted.
        case let .notStartedReached(durations):
            return notStartedSnapshot(durations, reachedType: "primary")
        }
    }

    private func notStartedSnapshot(_ durations: [Int], reachedType: String?) -> CodexQuotaSnapshot {
        let base = now()
        return CodexQuotaSnapshot(
            windows: durations.map { duration in
                CodexQuotaWindow(
                    utilization: 0,
                    durationSeconds: duration,
                    resetsAt: base.addingTimeInterval(Double(duration)))
            },
            planLabel: "Plus",
            rateLimitReachedType: reachedType)
    }

    func diagnostics() async -> CodexQuotaDiagnostics {
        var d = CodexQuotaDiagnostics(binaryPath: "/opt/homebrew/bin/codex", version: "0.148.0")
        switch outcome {
        case .windows, .notStarted, .notStartedReached:
            d.lastSuccess = now()
            d.lastLatency = 0.44
            // A second read, so a `notStarted` scenario recomputes its reset from `now` here exactly
            // as the server does per request — which is what makes the creep visible in Troubleshoot.
            d.lastResets = (try? await read())?.windows.map(\.resetsAt) ?? []
        case let .failure(error):
            if case .cliNotFound = error { d.binaryPath = nil; d.version = nil }
            d.lastError = CodexAppServer.describe(error)
        }
        return d
    }
}
