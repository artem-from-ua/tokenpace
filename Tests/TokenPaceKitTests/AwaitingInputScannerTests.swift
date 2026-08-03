import Testing
import Foundation
@testable import TokenPaceKit

private let refNow = Date(timeIntervalSince1970: 1_800_000_000)   // fixed "now" for age math

/// A throwaway `~/.claude`-shaped fixture tree on disk, so the scanner runs against real files.
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

    /// Write a `sessions/<pid>.json` file (compact, like Claude Code writes it). `ageDays` sets
    /// `updatedAt` to that many days before `refNow`; `cwd` is the project fallback.
    @discardableResult
    func session(_ pid: String, status: String, jobId: String? = nil,
                 ageDays: Double = 0, cwd: String = "/repo/app") -> URL {
        let updatedMs = Int((refNow.timeIntervalSince1970 - ageDays * 86_400) * 1000)
        var s = #"{"pid":\#(pid),"status":"\#(status)","cwd":"\#(cwd)","updatedAt":\#(updatedMs)"#
        if let jobId { s += #","jobId":"\#(jobId)""# }
        s += "}"
        let url = home.appendingPathComponent("sessions/\(pid).json")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a `jobs/<jobId>/state.json` file (pretty-printed with spaces, like the daemon writes it).
    func job(_ jobId: String, state: String = "working", tempo: String = "active",
             needs: String? = nil, originCwd: String? = nil) {
        let dir = home.appendingPathComponent("jobs/\(jobId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let needsLine = needs.map { #",\#n  "needs": "\#($0)""# } ?? #",\#n  "needs": null"#
        let originLine = originCwd.map { #",\#n  "originCwd": "\#($0)""# } ?? ""
        let body = #"""
        {
          "state": "\#(state)",
          "tempo": "\#(tempo)"\#(needsLine)\#(originLine)
        }
        """#
        try? body.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    /// Write `settings.json` with a `cleanupPeriodDays` value.
    func settings(cleanupPeriodDays: Int) {
        let body = #"{ "cleanupPeriodDays": \#(cleanupPeriodDays) }"#
        try? body.write(to: home.appendingPathComponent("settings.json"),
                        atomically: true, encoding: .utf8)
    }

    func scanner() -> AwaitingInputScanner { AwaitingInputScanner(claudeHome: home) }
    func count() -> Int { scanner().count(now: refNow) }
    func scan() -> AwaitingSessions { scanner().scan(now: refNow) }
}

@Suite("AwaitingInputScanner")
struct AwaitingInputScannerTests {

    // MARK: status == "waiting" (direct signal)

    @Test func waitingStatusCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        #expect(fx.count() == 1)
    }

    @Test func busyAndIdleDoNotCountOnStatusAlone() {
        let fx = ClaudeFixture()
        fx.session("1", status: "busy")
        fx.session("2", status: "idle")   // no jobId → no state.json to rescue it
        #expect(fx.count() == 0)
    }

    // MARK: jobs/<id>/state.json rescue (idle session that is actually blocked)

    @Test func idleSessionWithNeedsCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked", needs: "confirm the edit looks good")
        #expect(fx.count() == 1)
    }

    @Test func idleSessionWithTempoBlockedCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "working", tempo: "blocked", needs: nil)
        #expect(fx.count() == 1)
    }

    @Test func idleSessionWithNullNeedsAndActiveTempoDoesNotCount() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "working", tempo: "active", needs: nil)
        #expect(fx.count() == 0)
    }

    @Test func missingStateJsonFallsBackToNotAwaiting() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "ghost")
        #expect(fx.count() == 0)
    }

    // MARK: aggregation & edge cases

    @Test func countsAcrossMultipleSessions() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        fx.session("2", status: "idle", jobId: "j2"); fx.job("j2", needs: "approve plan")
        fx.session("3", status: "busy")
        fx.session("4", status: "idle")
        #expect(fx.count() == 2)
    }

    @Test func missingSessionsDirIsZero() {
        let scanner = AwaitingInputScanner(
            claudeHome: FileManager.default.temporaryDirectory
                .appendingPathComponent("tp-none-\(UUID().uuidString)"))
        #expect(scanner.scan(now: refNow) == .none)
    }

    @Test func nonJSONFilesAreIgnored() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        try? "junk".write(to: fx.home.appendingPathComponent("sessions/notes.txt"),
                          atomically: true, encoding: .utf8)
        #expect(fx.count() == 1)
    }

    // MARK: re-scan reflects live changes (stateless)

    @Test func rescanReflectsStatusRewrite() {
        let fx = ClaudeFixture()
        let url = fx.session("1", status: "waiting")
        #expect(fx.count() == 1)
        try? #"{"pid":1,"status":"idle"}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(fx.count() == 0)
    }

    @Test func rescanReflectsVanishedSession() {
        let fx = ClaudeFixture()
        let url = fx.session("1", status: "waiting")
        #expect(fx.count() == 1)
        try? FileManager.default.removeItem(at: url)
        #expect(fx.count() == 0)
    }

    // MARK: age → days-until-deletion & urgency (#233/#234)

    @Test func daysUntilDeletionUsesDefaultCleanup30() {
        // No settings.json → cleanup defaults to 30. A 10-day-old session has 20 days left.
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", ageDays: 10)
        let s = fx.scan().sessions.first!
        #expect(abs(s.daysUntilDeletion - 20) < 0.01)
        #expect(s.urgency == .neutral)   // 20 > 15
    }

    @Test func urgencyOrangeUnder15DaysLeft() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", ageDays: 20)   // 30-20 = 10 left → orange
        #expect(fx.scan().sessions.first!.urgency == .orange)
        #expect(fx.scan().urgency == .orange)
    }

    @Test func urgencyRedUnder7DaysLeft() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", ageDays: 25)   // 30-25 = 5 left → red
        #expect(fx.scan().sessions.first!.urgency == .red)
        #expect(fx.scan().urgency == .red)
    }

    @Test func cleanupPeriodDaysReadFromSettings() {
        let fx = ClaudeFixture()
        fx.settings(cleanupPeriodDays: 7)
        fx.session("1", status: "waiting", ageDays: 3)   // 7-3 = 4 left → red
        #expect(fx.scan().sessions.first!.urgency == .red)
    }

    @Test func overallUrgencyIsMostUrgentSession() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", ageDays: 1)    // 29 left → neutral
        fx.session("2", status: "waiting", ageDays: 26)   // 4 left → red
        #expect(fx.scan().urgency == .red)
    }

    // MARK: project grouping (originCwd, worktrees collapse)

    @Test func projectUsesOriginCwdFromState() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "j1", cwd: "/repo/app/.claude/worktrees/x")
        fx.job("j1", needs: "approve plan", originCwd: "/repo/app")
        let s = fx.scan().sessions.first!
        #expect(s.project == "/repo/app")
        #expect(s.projectName == "app")
    }

    @Test func projectFallsBackToCwdWithoutOrigin() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", cwd: "/repo/solo")
        #expect(fx.scan().sessions.first!.projectName == "solo")
    }

    @Test func perProjectBreakdownBucketsByUrgency() {
        let fx = ClaudeFixture()
        // project "app": one red (26d old → 4 left), one recent (1d → 29 left)
        fx.session("1", status: "waiting", ageDays: 26, cwd: "/repo/app")
        fx.session("2", status: "waiting", ageDays: 1, cwd: "/repo/app")
        // project "lib": one orange (20d → 10 left)
        fx.session("3", status: "waiting", ageDays: 20, cwd: "/repo/lib")
        let per = fx.scan().perProject
        #expect(per.count == 2)
        // "app" sorts first (has a red)
        #expect(per[0].projectName == "app")
        #expect(per[0].red == 1 && per[0].orange == 0 && per[0].recent == 1)
        #expect(per[1].projectName == "lib")
        #expect(per[1].orange == 1 && per[1].red == 0 && per[1].recent == 0)
    }
}
