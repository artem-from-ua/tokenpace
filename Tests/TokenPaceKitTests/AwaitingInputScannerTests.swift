import Testing
import Foundation
@testable import TokenPaceKit

private let refNow = Date(timeIntervalSince1970: 1_800_000_000)   // fixed "now" for age math

/// A ``ProcessLiveness`` driven by a fixture table instead of the real process table (#275), so a
/// test never depends on which pids happen to exist on the machine running it.
///
/// `startTimes` maps pid → kernel start time (epoch seconds); an absent pid reads as dead.
/// ``alwaysAlive`` is the default the fixture uses, so the 30-odd tests written before the liveness
/// filter existed keep exercising exactly what they were written to exercise.
private struct StubLiveness: ProcessLiveness {
    var startTimes: [Int32: Double] = [:]
    var alwaysAlive = false

    func startTime(ofPID pid: Int32) -> Double? {
        if alwaysAlive { return startTimes[pid] ?? 0 }
        return startTimes[pid]
    }
}

/// A throwaway `~/.claude`-shaped fixture tree on disk, so the scanner runs against real files.
private final class ClaudeFixture {
    let home: URL
    /// Process table backing ``scanner()``. Defaults to "every pid is alive" so tests that predate
    /// the liveness filter (#275) are unaffected; liveness tests override it explicitly.
    var liveness = StubLiveness(alwaysAlive: true)
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
                 ageDays: Double = 0, cwd: String = "/repo/app",
                 procStart: String? = nil, name: String? = nil,
                 sessionId: String? = nil) -> URL {
        let updatedMs = Int((refNow.timeIntervalSince1970 - ageDays * 86_400) * 1000)
        // Both `updatedAt` and `statusUpdatedAt` are set to the same instant, as Claude Code does; the
        // freshness guard prefers `statusUpdatedAt`, and age math reads `updatedAt`.
        var s = #"{"pid":\#(pid),"status":"\#(status)","cwd":"\#(cwd)","updatedAt":\#(updatedMs),"statusUpdatedAt":\#(updatedMs)"#
        if let jobId { s += #","jobId":"\#(jobId)""# }
        if let procStart { s += #","procStart":"\#(procStart)""# }
        if let name { s += #","name":"\#(name)""# }
        if let sessionId { s += #","sessionId":"\#(sessionId)""# }
        s += "}"
        let url = home.appendingPathComponent("sessions/\(pid).json")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a `jobs/<jobId>/state.json` file (pretty-printed with spaces, like the daemon writes it).
    ///
    /// `updatedAtDaysBeforeNow` sets the ISO `updatedAt` field the freshness guard reads: `nil` omits
    /// it entirely (guard fails open — the pre-guard behavior most tests exercise), `0` writes
    /// `refNow`, a positive value writes that many days *before* `refNow` (a stale worktree state).
    func job(_ jobId: String, state: String = "working", tempo: String = "active",
             needs: String? = nil, originCwd: String? = nil,
             updatedAtDaysBeforeNow: Double? = nil) {
        let dir = home.appendingPathComponent("jobs/\(jobId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let needsLine = needs.map { #",\#n  "needs": "\#($0)""# } ?? #",\#n  "needs": null"#
        let originLine = originCwd.map { #",\#n  "originCwd": "\#($0)""# } ?? ""
        let updatedLine = updatedAtDaysBeforeNow.map {
            #",\#n  "updatedAt": "\#(Self.iso(daysBeforeNow: $0))""#
        } ?? ""
        let body = #"""
        {
          "state": "\#(state)",
          "tempo": "\#(tempo)"\#(needsLine)\#(originLine)\#(updatedLine)
        }
        """#
        try? body.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    /// Format an ISO-8601 `updatedAt` (`…T…:…:….sssZ`) `days` before `refNow`, matching the shape
    /// Claude Code's daemon emits — so the guard's parser exercises the real format.
    private static func iso(daysBeforeNow days: Double) -> String {
        let date = Date(timeIntervalSince1970: refNow.timeIntervalSince1970 - days * 86_400)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.000Z",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// Write `settings.json` with a `cleanupPeriodDays` value.
    func settings(cleanupPeriodDays: Int) {
        let body = #"{ "cleanupPeriodDays": \#(cleanupPeriodDays) }"#
        try? body.write(to: home.appendingPathComponent("settings.json"),
                        atomically: true, encoding: .utf8)
    }

    func scanner() -> AwaitingInputScanner {
        AwaitingInputScanner(claudeHome: home, liveness: liveness)
    }
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

    // MARK: status == "busy" (running a turn — never awaiting)

    /// The post-approval stall: right after a plan is approved the daemon leaves
    /// `needs:"approve plan"` in the job state while the session runs the next turn, and freezes
    /// both timestamps together so the freshness guard still sees a "fresh" pair. The session file
    /// reports the truth (`busy`), which must win over the stale job state.
    @Test func busySessionWithStaleApprovePlanNeedsDoesNotCount() {
        let fx = ClaudeFixture()
        fx.session("1", status: "busy", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked",
               needs: "approve plan", updatedAtDaysBeforeNow: 0)   // fresh by the guard's measure
        #expect(fx.count() == 0)
    }

    /// Same stall expressed only as `tempo:"blocked"` — also outranked by a `busy` session.
    @Test func busySessionWithTempoBlockedDoesNotCount() {
        let fx = ClaudeFixture()
        fx.session("1", status: "busy", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked", needs: nil, updatedAtDaysBeforeNow: 0)
        #expect(fx.count() == 0)
    }

    /// The `busy` shortcut must not shadow step 1: a session with an *active* prompt reports
    /// `waiting`, and that is a direct real-time signal which still counts.
    @Test func waitingStatusWinsOverBusyShortcut() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", jobId: "job1")
        fx.job("job1", state: "working", tempo: "active", needs: nil, updatedAtDaysBeforeNow: 0)
        #expect(fx.count() == 1)
    }

    /// A `busy` session must not suppress a *different* session that genuinely awaits input.
    @Test func busySessionDoesNotMaskAnotherAwaitingSession() {
        let fx = ClaudeFixture()
        fx.session("1", status: "busy", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked", needs: "approve plan",
               updatedAtDaysBeforeNow: 0)
        fx.session("2", status: "idle", jobId: "job2")
        fx.job("job2", state: "blocked", tempo: "blocked", needs: "confirm the edit",
               updatedAtDaysBeforeNow: 0)
        #expect(fx.count() == 1)
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

    // MARK: freshness guard (stale worktree state.json — the phantom-hand bug)

    /// The core bug: a worktree session whose `state.json` froze on `needs:"approve plan"` hours ago,
    /// while the session file itself is fresh and idle. The frozen job state must be ignored.
    @Test func staleStateWithNeedsDoesNotCount() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")          // session fresh (age 0)
        fx.job("job1", state: "blocked", tempo: "blocked",
               needs: "approve plan", updatedAtDaysBeforeNow: 0.1)   // state ~2.4h old → stale
        #expect(fx.count() == 0)
    }

    /// Same freeze but expressed only as `tempo:"blocked"` — also suppressed when stale.
    @Test func staleStateWithTempoBlockedDoesNotCount() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "working", tempo: "blocked", needs: nil,
               updatedAtDaysBeforeNow: 1)                        // a full day stale
        #expect(fx.count() == 0)
    }

    /// A genuinely-awaiting session: `state.json` is fresh (same instant as the session), so its
    /// `needs` is trusted and the session counts.
    @Test func freshStateWithNeedsCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked",
               needs: "confirm the edit", updatedAtDaysBeforeNow: 0)   // fresh
        #expect(fx.count() == 1)
    }

    /// `status == "waiting"` is a direct real-time signal (step 1) and must win even when the job
    /// state is stale — the guard only gates the state-derived step 2.
    @Test func waitingStatusCountsEvenWithStaleState() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked",
               needs: "approve plan", updatedAtDaysBeforeNow: 2)
        #expect(fx.count() == 1)
    }

    /// A small lag (within the tolerance) is normal cross-process skew, not a freeze — still counts.
    @Test func slightlyLaggingStateStillCounts() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        // 30 s ≈ 0.000347 days, under the 60 s tolerance.
        fx.job("job1", state: "blocked", tempo: "blocked",
               needs: "approve plan", updatedAtDaysBeforeNow: 30.0 / 86_400)
        #expect(fx.count() == 1)
    }

    /// When `state.json` has no `updatedAt` at all, the guard fails open (pre-guard behavior): we
    /// can't prove staleness, so the signal is trusted. This keeps older/edge state files working.
    @Test func stateWithoutTimestampFailsOpen() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "job1")
        fx.job("job1", state: "blocked", tempo: "blocked",
               needs: "approve plan", updatedAtDaysBeforeNow: nil)   // no updatedAt written
        #expect(fx.count() == 1)
    }

    // MARK: ISO timestamp parsing (guard internals)

    @Test func parseISOmsWithFractionalSeconds() {
        // 2026-08-04T01:27:32.234Z → known epoch ms.
        let ms = AwaitingInputScanner.parseISOms("2026-08-04T01:27:32.234Z")
        #expect(ms != nil)
        // Reconstruct expected value independently.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = DateComponents(year: 2026, month: 8, day: 4, hour: 1, minute: 27, second: 32)
        let expected = cal.date(from: c)!.timeIntervalSince1970 * 1000 + 234
        #expect(abs(ms! - expected) < 0.5)
    }

    @Test func parseISOmsWithoutFractionalSeconds() {
        #expect(AwaitingInputScanner.parseISOms("2026-08-04T01:27:32Z") != nil)
    }

    @Test func parseISOmsRejectsGarbage() {
        #expect(AwaitingInputScanner.parseISOms("not a date") == nil)
        #expect(AwaitingInputScanner.parseISOms("") == nil)
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
        #expect(per[0].projectName == "app")
        #expect(per[0].red == 1 && per[0].orange == 0 && per[0].recent == 1)
        #expect(per[0].sessions.count == 2)
        #expect(per[1].projectName == "lib")
        #expect(per[1].orange == 1 && per[1].red == 0 && per[1].recent == 0)
    }

    /// Projects sort by **name**, not by urgency (#438) — the heading no longer shows the chips that
    /// ranking was based on.
    ///
    /// `aaa` deliberately holds the only red session and still sorts first only because of its name,
    /// while `zzz` — which under the old most-urgent-first comparator would have led — sorts last.
    /// A two-project fixture cannot tell the comparators apart when the urgent project also happens
    /// to be alphabetically first, which is exactly why the case above proves nothing on its own.
    @Test func projectsSortByNameNotUrgency() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", ageDays: 1, cwd: "/repo/aaa")    // 29 left → neutral
        fx.session("2", status: "waiting", ageDays: 26, cwd: "/repo/zzz")   // 4 left → red
        fx.session("3", status: "waiting", ageDays: 20, cwd: "/repo/mmm")   // 10 left → orange
        #expect(fx.scan().perProject.map(\.projectName) == ["aaa", "mmm", "zzz"])
    }

    /// Sessions inside a project run freshest first (#438): `daysUntilDeletion` descending is the same
    /// order as `updatedAt` descending, since one `cleanupDays` applies to the whole scan.
    @Test func sessionsWithinAProjectRunFreshestFirst() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", ageDays: 20, cwd: "/repo/app", name: "oldest")
        fx.session("2", status: "waiting", ageDays: 1, cwd: "/repo/app", name: "freshest")
        fx.session("3", status: "waiting", ageDays: 9, cwd: "/repo/app", name: "middle")
        let sessions = fx.scan().perProject.first!.sessions
        #expect(sessions.map(\.name) == ["freshest", "middle", "oldest"])
    }

    // MARK: session name (#438)

    @Test func sessionNameIsRead() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", name: "refactor popup layout")
        #expect(fx.scan().sessions.first!.name == "refactor popup layout")
    }

    @Test func missingNameFieldReadsAsUnnamed() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting")
        #expect(fx.scan().sessions.first!.name == nil)
    }

    @Test func emptyNameReadsAsUnnamed() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", name: "")
        #expect(fx.scan().sessions.first!.name == nil)
    }

    @Test func blankNameReadsAsUnnamed() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", name: "   ")
        #expect(fx.scan().sessions.first!.name == nil)
    }

    /// The shape Claude Code actually writes for a session that was never titled: `name` **is** the
    /// jobId. Showing it would put an 8-char id on screen that `--resume` refuses.
    @Test func namePlaceholderEqualToJobIdReadsAsUnnamed() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", jobId: "04c0e8f2", name: "04c0e8f2")
        fx.job("04c0e8f2", needs: "approve plan")
        #expect(fx.scan().sessions.first!.name == nil)
    }

    /// Same placeholder reached without a `jobId` to compare against — the sessionId's 8-char prefix
    /// is the same string by another route.
    @Test func namePlaceholderEqualToSessionIdPrefixReadsAsUnnamed() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", name: "c8db2514",
                   sessionId: "c8db2514-d0a7-4a2a-b2c8-ac7008ec04d3")
        #expect(fx.scan().sessions.first!.name == nil)
    }

    /// Detection is equality with *this* session's own ids, never a guess at the shape. A title that
    /// merely looks like a job id is a title — a `^[0-9a-f]{8}$` test would have eaten it.
    @Test func nameThatMerelyLooksLikeAJobIdIsKept() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", jobId: "04c0e8f2", name: "deadbeef")
        fx.job("04c0e8f2", needs: "approve plan")
        #expect(fx.scan().sessions.first!.name == "deadbeef")
    }

    @Test func cyrillicNameSurvivesIntact() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", name: "рефакторинг індикатора")
        #expect(fx.scan().sessions.first!.name == "рефакторинг індикатора")
    }

    @Test func nameWithSpacesAndPunctuationIsRead() {
        let fx = ClaudeFixture()
        fx.session("1", status: "waiting", name: "fix: popup — layout (v2)")
        #expect(fx.scan().sessions.first!.name == "fix: popup — layout (v2)")
    }

    /// The name is read from the session file while the project still resolves through the job state —
    /// `jobId` serves both, and hoisting it out of the project branch must not have coupled them.
    @Test func nameIsIndependentOfProjectResolution() {
        let fx = ClaudeFixture()
        fx.session("1", status: "idle", jobId: "j1", cwd: "/repo/app/.claude/worktrees/x",
                   name: "worktree session")
        fx.job("j1", needs: "approve plan", originCwd: "/repo/app")
        let s = fx.scan().sessions.first!
        #expect(s.projectName == "app")
        #expect(s.name == "worktree session")
    }

    // MARK: liveness — dead sessions never count (#275)

    /// The core of #275: `claude` killed while a prompt was on screen leaves `status:"waiting"` on
    /// disk with nobody left to rewrite it. Before the filter that hand never went down.
    @Test func deadSessionDoesNotCount() {
        let fx = ClaudeFixture()
        fx.liveness = StubLiveness(startTimes: [:])          // process table is empty → pid is gone
        fx.session("4242", status: "waiting")
        #expect(fx.count() == 0)
    }

    @Test func liveSessionCounts() {
        let fx = ClaudeFixture()
        fx.liveness = StubLiveness(startTimes: [4242: 1_700_000_000])
        fx.session("4242", status: "waiting")
        #expect(fx.count() == 1)
    }

    /// A dead session must not be resurrected by an unrelated process that the kernel later handed
    /// the same pid to: the recorded `procStart` and the actual start time disagree.
    @Test func reusedPIDDoesNotResurrectDeadSession() {
        let fx = ClaudeFixture()
        // The live process with this pid started long after the session recorded its own start.
        fx.liveness = StubLiveness(startTimes: [4242: 1_800_000_000])
        fx.session("4242", status: "waiting", procStart: "Tue Aug  4 22:00:24 2026")
        #expect(fx.count() == 0)
    }

    /// The matching-process case: same pid, and `procStart` agrees with the kernel (to the second).
    @Test func matchingProcStartCounts() {
        let fx = ClaudeFixture()
        // "Tue Aug  4 22:00:24 2026" UTC == 1_785_880_824.
        fx.liveness = StubLiveness(startTimes: [4242: 1_785_880_824.5])
        fx.session("4242", status: "waiting", procStart: "Tue Aug  4 22:00:24 2026")
        #expect(fx.count() == 1)
    }

    /// Fail-open #1: a live pid whose `procStart` we cannot read still counts — the filter only ever
    /// removes sessions it can positively prove are dead.
    @Test func unparseableProcStartFailsOpen() {
        let fx = ClaudeFixture()
        fx.liveness = StubLiveness(startTimes: [4242: 1_700_000_000])
        fx.session("4242", status: "waiting", procStart: "not a date")
        #expect(fx.count() == 1)
    }

    /// Fail-open #2: a session file with no `pid` field at all (a format change on Claude Code's
    /// side) must not silently vanish from the count.
    @Test func missingPIDFailsOpen() {
        let fx = ClaudeFixture()
        fx.liveness = StubLiveness(startTimes: [:])
        let url = fx.home.appendingPathComponent("sessions/nopid.json")
        try? #"{"status":"waiting","cwd":"/repo/app","updatedAt":1800000000000}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(fx.count() == 1)
    }

    /// A dead session must not count even when its job state advertises `needs` — the liveness gate
    /// runs before the status/job-state join, so no branch can smuggle it back in.
    @Test func deadSessionWithNeedsDoesNotCount() {
        let fx = ClaudeFixture()
        fx.liveness = StubLiveness(startTimes: [:])
        fx.session("4242", status: "idle", jobId: "j1")
        fx.job("j1", needs: "approve plan", updatedAtDaysBeforeNow: 0)
        #expect(fx.count() == 0)
    }

    // MARK: procStart parsing

    @Test func parseProcStartReadsCtimeAsUTC() {
        // ctime format, and written in UTC despite carrying no zone marker (verified against
        // `p_starttime` on Claude Code v2.1.220).
        #expect(AwaitingInputScanner.parseProcStart("Tue Aug  4 22:00:24 2026") == 1_785_880_824)
    }

    /// Single-digit days are space-padded to two columns by `ctime` ("Aug  4"), double-digit days are
    /// not ("Jul 28") — the parser has to accept both.
    @Test func parseProcStartHandlesTwoDigitDay() {
        #expect(AwaitingInputScanner.parseProcStart("Tue Jul 28 21:26:15 2026") == 1_785_273_975)
    }

    @Test func parseProcStartRejectsGarbage() {
        #expect(AwaitingInputScanner.parseProcStart("2026-08-04T22:00:24Z") == nil)
        #expect(AwaitingInputScanner.parseProcStart("") == nil)
    }
}
