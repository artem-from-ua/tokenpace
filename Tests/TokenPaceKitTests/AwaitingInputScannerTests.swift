import Testing
import Foundation
@testable import TokenPaceKit

/// A throwaway `~/.claude`-shaped fixture tree on disk, so the scanner runs against real files
/// (it reads via `FileManager`, and the mtime cache needs genuine modification dates).
private final class ClaudeFixture {
    let home: URL
    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tp-awaiting-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent("jobs"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: home) }

    /// Write a `sessions/<pid>.json` file (compact, like Claude Code writes it).
    @discardableResult
    func session(_ pid: String, status: String, jobId: String? = nil) -> URL {
        var s = #"{"pid":\#(pid),"status":"\#(status)""#
        if let jobId { s += #","jobId":"\#(jobId)""# }
        s += "}"
        let url = home.appendingPathComponent("sessions/\(pid).json")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a `jobs/<jobId>/state.json` file (pretty-printed with spaces, like the daemon writes it).
    func job(_ jobId: String, state: String = "working", tempo: String = "active", needs: String? = nil) {
        let dir = home.appendingPathComponent("jobs/\(jobId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let needsLine = needs.map { #",\#n  "needs": "\#($0)""# } ?? #",\#n  "needs": null"#
        let body = #"""
        {
          "state": "\#(state)",
          "tempo": "\#(tempo)"\#(needsLine)
        }
        """#
        try? body.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    func scanner() -> AwaitingInputScanner { AwaitingInputScanner(claudeHome: home) }
}

@Suite("AwaitingInputScanner")
struct AwaitingInputScannerTests {

    // MARK: status == "waiting" (direct signal)

    @Test func waitingStatusCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        #expect(fx.scanner().scan() == 1)
    }

    @Test func busyAndIdleDoNotCountOnStatusAlone() {
        let fx = ClaudeFixture()
        fx.session("1", status: "busy")
        fx.session("2", status: "idle")   // no jobId → no state.json to rescue it
        #expect(fx.scanner().scan() == 0)
    }

    // MARK: jobs/<id>/state.json rescue (idle session that is actually blocked)

    @Test func idleSessionWithNeedsCounts() {
        // The key ADR-0066 case: sessions/*.json still says "idle", but state.json knows `needs`.
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked", needs: "confirm the edit looks good")
        #expect(fx.scanner().scan() == 1)
    }

    @Test func idleSessionWithTempoBlockedCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "working", tempo: "blocked", needs: nil)
        #expect(fx.scanner().scan() == 1)
    }

    @Test func idleSessionWithNullNeedsAndActiveTempoDoesNotCount() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "working", tempo: "active", needs: nil)
        #expect(fx.scanner().scan() == 0)
    }

    @Test func missingStateJsonFallsBackToNotAwaiting() {
        // jobId points at a job dir that has no state.json (fresh session) — must not crash, count 0.
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "ghost")
        #expect(fx.scanner().scan() == 0)
    }

    // MARK: aggregation & edge cases

    @Test func countsAcrossMultipleSessions() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        fx.session("2", status: "idle", jobId: "j2"); fx.job("j2", needs: "approve plan")
        fx.session("3", status: "busy")
        fx.session("4", status: "idle")
        #expect(fx.scanner().scan() == 2)
    }

    @Test func missingSessionsDirIsZero() {
        let scanner = AwaitingInputScanner(
            claudeHome: FileManager.default.temporaryDirectory
                .appendingPathComponent("tp-none-\(UUID().uuidString)"))
        #expect(scanner.scan() == 0)
    }

    @Test func nonJSONFilesAreIgnored() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        try? "junk".write(to: fx.home.appendingPathComponent("sessions/notes.txt"),
                          atomically: true, encoding: .utf8)
        #expect(fx.scanner().scan() == 1)
    }

    // MARK: re-scan reflects live changes (stateless — no cache)

    @Test func rescanReflectsStatusRewrite() {
        let fx = ClaudeFixture()
        let url = fx.session("1", status: "waiting")
        let scanner = fx.scanner()
        #expect(scanner.scan() == 1)
        try? #"{"pid":1,"status":"idle"}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(scanner.scan() == 0)          // stateless: next scan just re-reads the new content
    }

    @Test func rescanReflectsVanishedSession() {
        let fx = ClaudeFixture()
        let url = fx.session("1", status: "waiting")
        let scanner = fx.scanner()
        #expect(scanner.scan() == 1)
        try? FileManager.default.removeItem(at: url)
        #expect(scanner.scan() == 0)
    }
}
