import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fake app-server

/// A `codex app-server` stand-in: a shell script written to a temp directory and run as the binary.
///
/// A script rather than a Swift helper because the transport spawns an executable path, and a test
/// must not need `codex` installed, signed in, or on any particular plan. The silent scripts keep
/// reading stdin so they stay alive instead of exiting on EOF — a live server that says nothing is
/// exactly the state the transport has to survive.
private struct FakeServer {
    let path: String
    private let directory: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        path = script.path
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// The `initialize` reply, carrying the userAgent the version is parsed out of.
    static let initializeReply =
        #"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"codex/0.148.0 (Mac OS 15.7.9; arm64)"}}"#

    /// One 7-day window — the `account/rateLimits/read` shape the live server sends today.
    static let rateLimitsReply = #"{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1787500000},"secondary":null},"planType":"plus"}}"#
}

/// Whether a pid still names a live process. `Process` reaps its own child, so once it is gone the
/// pid is unassigned rather than a zombie, and `ESRCH` here is a real answer.
private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

/// Wait out the SIGTERM→SIGKILL escalation before calling a child leaked.
private func waitUntilGone(_ pid: Int32, within seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !isAlive(pid) { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return !isAlive(pid)
}

// MARK: - Transport

/// The transport rather than the payload: what a silent server, a half-written line and an early
/// EOF do to a read, and whether the child is gone once the read returns.
///
/// These spawn real processes, so each case passes a short `timeout` — the production 20 s is a
/// budget, not something to sit through. The budgets are generous against that timeout because the
/// full suite runs its cases in parallel: measured, a child that answered in 127 ms had its
/// continuation resumed 11 s later under that load, so a tight wall-clock assertion here would be
/// testing the machine rather than the transport.
@Suite("Codex RPC transport", .serialized)
struct CodexRPCSessionTests {

    // MARK: happy path

    @Test("a server that answers both requests yields a decodable payload")
    func happyPath() async throws {
        let server = try FakeServer("""
        while read -r line; do
          case "$line" in
            *initialize*) echo '\(FakeServer.initializeReply)' ;;
            *rateLimits*) echo '\(FakeServer.rateLimitsReply)' ;;
          esac
        done
        """)
        defer { server.remove() }

        let outcome = try await CodexAppServer.exchange(binary: server.path, timeout: 60)
        #expect(outcome.version == "0.148.0")
        let decoded = try JSONDecoder().decode(CodexRateLimitsResult.self, from: outcome.payload)
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decoded)
        #expect(snapshot.windows.first?.utilization == 41)
    }

    // MARK: the defect

    /// The case that hung forever: `initialize` answered, then silence. The read must end at the
    /// deadline **and** the child must be gone — the leak was the cleanup sitting inside the very
    /// read that never returned.
    @Test("a silent server times out inside the budget and leaves no child behind")
    func silentServerTimesOutAndReapsTheChild() async throws {
        let server = try FakeServer("""
        read -r line
        echo '\(FakeServer.initializeReply)'
        while read -r line; do :; done
        sleep 600
        """)
        defer { server.remove() }

        let pid = try await pidOfTimedOutRead(binary: server.path, timeout: 1.5, budget: 30)
        #expect(waitUntilGone(pid, within: CodexAppServer.killGrace + 20),
                "the child survived the read that abandoned it")
    }

    /// A response cut mid-line: the newline never arrives, and the blocking read parked on the pipe
    /// waiting for it.
    @Test("a half-written line times out rather than parking on the pipe")
    func partialLineTimesOut() async throws {
        let server = try FakeServer("""
        read -r line
        echo '\(FakeServer.initializeReply)'
        read -r line
        printf '{"jsonrpc":"2.0","id":2,"result":{"rate'
        while read -r line; do :; done
        sleep 600
        """)
        defer { server.remove() }

        let pid = try await pidOfTimedOutRead(binary: server.path, timeout: 1.5, budget: 30)
        #expect(waitUntilGone(pid, within: CodexAppServer.killGrace + 20),
                "the child survived the read that abandoned it")
    }

    // MARK: framing

    /// `remoteControl/status/changed` arrives before `initialize`'s own response on the live server,
    /// so a reader taking "the next line" hands a notification back as the handshake result.
    @Test("an unsolicited notification ahead of the reply is not mistaken for it")
    func notificationBeforeTheReply() async throws {
        let server = try FakeServer("""
        while read -r line; do
          case "$line" in
            *initialize*)
              echo '{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{"status":"idle"}}'
              echo 'this line is not JSON at all'
              echo '{"jsonrpc":"2.0","id":99,"result":{"userAgent":"codex/9.9.9 (wrong)"}}'
              echo '\(FakeServer.initializeReply)' ;;
            *rateLimits*) echo '\(FakeServer.rateLimitsReply)' ;;
          esac
        done
        """)
        defer { server.remove() }

        let outcome = try await CodexAppServer.exchange(binary: server.path, timeout: 60)
        #expect(outcome.version == "0.148.0")
    }

    @Test("a server that closes its stdout reports the child as gone, not as a timeout")
    func earlyEOFIsProcessDied() async throws {
        let server = try FakeServer("exit 0\n")
        defer { server.remove() }

        await #expect(throws: CodexQuotaError.processDied) {
            _ = try await CodexAppServer.exchange(binary: server.path, timeout: 60)
        }
    }

    // MARK: one deadline for both calls

    /// The budget covers `initialize` and the rate-limits read together. Given a deadline per
    /// request, a server spending nearly the whole budget on the handshake still got a fresh one for
    /// the second call, so a 20 s read could take 40.
    @Test("the handshake and the read share one budget")
    func oneDeadlineSpansBothCalls() async throws {
        let server = try FakeServer("""
        read -r line
        sleep 1.4
        echo '\(FakeServer.initializeReply)'
        while read -r line; do :; done
        sleep 600
        """)
        defer { server.remove() }

        // The deadline is the observable, not the wall clock: a loaded pool inflates elapsed time
        // for reasons of its own, while the deadline the transport enforces is exact. The handshake
        // answers at 1.4 s of a 2 s budget; given a deadline per request the second call would start
        // a fresh 2 s from ~1.4 s and expire near 3.4 s. Shared, it expires at the one deadline.
        let session = try CodexRPCSession(binary: server.path)
        defer { session.shutDown() }
        let budget: TimeInterval = 2
        let deadline = Date().addingTimeInterval(budget)
        _ = try await session.handshake(clientVersion: "0.0.0", before: deadline)
        #expect(Date() < deadline, "the handshake alone already spent the budget")

        await #expect(throws: CodexQuotaError.timedOut) {
            _ = try await session.call(
                method: CodexAppServer.rateLimitsMethod, before: deadline)
        }
        // The second call ended at the deadline the first one shared. A deadline of its own would
        // have been set after the handshake returned — 1.4 s in — and expired ~1.4 s past this one.
        // The margin allows for scheduling delay while staying well under that.
        let overshoot = Date().timeIntervalSince(deadline)
        #expect(overshoot < 1, "the second call started a budget of its own (+\(overshoot)s)")
    }

    // MARK: helpers

    /// One exchange against a server expected to time out, returning the child's pid so the caller
    /// can prove it was reaped. The pid is read off the session before the race, because after
    /// `shutDown()` the `Process` no longer names a live child.
    private func pidOfTimedOutRead(binary: String, timeout: TimeInterval, budget: TimeInterval)
        async throws -> Int32 {
        let session = try CodexRPCSession(binary: binary)
        let pid = session.processIdentifier
        #expect(isAlive(pid), "the fake server never started")

        let started = Date()
        do {
            defer { session.shutDown() }
            let deadline = Date().addingTimeInterval(timeout)
            _ = try await session.handshake(clientVersion: "0.0.0", before: deadline)
            _ = try await session.call(method: CodexAppServer.rateLimitsMethod, before: deadline)
            Issue.record("the read returned a result where a timeout was expected")
        } catch let error as CodexQuotaError {
            #expect(error == .timedOut)
        }
        #expect(Date().timeIntervalSince(started) < budget, "the read overran its own deadline")
        return pid
    }
}
