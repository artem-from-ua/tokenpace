import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Shared fixtures

/// A fixed "current time" so all reset arithmetic is deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// Render `now + offset` seconds as the ISO-8601 string the API emits, so a fixture window's
/// `resets_at` parses back through `ResetClock.parse` to the same instant. Built independently of
/// `ResetClock`'s own `isoString` so the assertion does not depend on the code under test.
private func iso(_ offset: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: now.addingTimeInterval(offset))
}

/// The next-window instant `ResetClock` synthesizes for `window` at `now` (`now + duration`, ceil to
/// 10 min), as the raw ISO string. Used to assert the rolled-forward `resets_at`.
private func synthesized(_ window: LimitWindow) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: ResetClock.nextReset(now: now, window: window))
}

// MARK: - optimisticReset

@Suite("ResetClock.optimisticReset")
struct OptimisticResetTests {

    /// Idle 5h stays idle: no synthesized reset, `sessionIdle` preserved. 7d in the future untouched.
    @Test func idleStaysIdle() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 40, resetsAt: iso(3600)),
            sessionIdle: true)
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out == snapshot)   // completely unchanged
    }

    /// An active 5h window past its reset → 0% and a fresh `now + 5h` reset; `sessionIdle` stays false.
    @Test func activeFiveHourPastResetRollsForward() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 60, resetsAt: iso(-1)),
            sevenDay: UsageWindow(utilization: 40, resetsAt: iso(3600)))
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out.fiveHour == UsageWindow(utilization: 0, resetsAt: synthesized(.fiveHour)))
        #expect(out.sevenDay == snapshot.sevenDay)   // 7d still future → untouched
        #expect(out.sessionIdle == false)
    }

    /// A 5h reset still in the future → the window is left exactly as-is.
    @Test func fiveHourFutureUnchanged() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 60, resetsAt: iso(3600)),
            sevenDay: UsageWindow(utilization: 40, resetsAt: iso(7200)))
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out == snapshot)
    }

    /// A 7d window past its reset → 0% and a fresh `now + 7d` reset.
    @Test func sevenDayPastResetRollsForward() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 60, resetsAt: iso(3600)),
            sevenDay: UsageWindow(utilization: 80, resetsAt: iso(-1)))
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out.fiveHour == snapshot.fiveHour)   // 5h still future → untouched
        #expect(out.sevenDay == UsageWindow(utilization: 0, resetsAt: synthesized(.sevenDay)))
    }

    /// Sub-windows reset with the 7d window, borrowing its new `resets_at`.
    @Test func subWindowsBorrowNewSevenDayReset() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: iso(3600)),
            sevenDay: UsageWindow(utilization: 80, resetsAt: iso(-1)),
            sevenDayOpus: UsageWindow(utilization: 50, resetsAt: iso(-1)),
            sevenDaySonnet: UsageWindow(utilization: 30, resetsAt: iso(-1)))
        let out = ResetClock.optimisticReset(snapshot, now: now)
        let newSeven = synthesized(.sevenDay)
        #expect(out.sevenDayOpus == UsageWindow(utilization: 0, resetsAt: newSeven))
        #expect(out.sevenDaySonnet == UsageWindow(utilization: 0, resetsAt: newSeven))
    }

    /// Sub-windows are left untouched while the 7d window is still in the future.
    @Test func subWindowsUntouchedWhenSevenDayFuture() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: iso(3600)),
            sevenDay: UsageWindow(utilization: 80, resetsAt: iso(7200)),
            sevenDayOpus: UsageWindow(utilization: 50, resetsAt: iso(7200)))
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out == snapshot)
    }

    /// Both windows past their reset → both roll forward in a single call.
    @Test func bothWindowsResetTogether() {
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 60, resetsAt: iso(-1)),
            sevenDay: UsageWindow(utilization: 80, resetsAt: iso(-1)))
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out.fiveHour == UsageWindow(utilization: 0, resetsAt: synthesized(.fiveHour)))
        #expect(out.sevenDay == UsageWindow(utilization: 0, resetsAt: synthesized(.sevenDay)))
    }

    /// `limits` are carried through unchanged — the overlay is transient; the next poll replaces them.
    @Test func limitsPreserved() {
        let limit = UsageLimit(
            kind: "session", group: "", percent: 60, severity: "warning",
            resetsAt: iso(-1), isActive: true)
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 60, resetsAt: iso(-1)),
            sevenDay: UsageWindow(utilization: 40, resetsAt: iso(3600)),
            limits: [limit])
        let out = ResetClock.optimisticReset(snapshot, now: now)
        #expect(out.limits == [limit])
    }
}

// MARK: - nextResetInstant

@Suite("ResetClock.nextResetInstant")
struct NextResetInstantTests {

    @Test func pastFiveHourFutureSevenDayPicksSevenDay() {
        let instant = ResetClock.nextResetInstant(
            fiveHourResetsAt: iso(-1), sevenDayResetsAt: iso(3600), now: now)
        #expect(instant == now.addingTimeInterval(3600))
    }

    @Test func bothFuturePicksNearer() {
        let instant = ResetClock.nextResetInstant(
            fiveHourResetsAt: iso(1800), sevenDayResetsAt: iso(3600), now: now)
        #expect(instant == now.addingTimeInterval(1800))
    }

    @Test func bothPastReturnsNil() {
        let instant = ResetClock.nextResetInstant(
            fiveHourResetsAt: iso(-10), sevenDayResetsAt: iso(-1), now: now)
        #expect(instant == nil)
    }

    /// Idle 5h (`resets_at == ""`) drops out; the 7d reset is scheduled.
    @Test func idleFiveHourPicksSevenDay() {
        let instant = ResetClock.nextResetInstant(
            fiveHourResetsAt: "", sevenDayResetsAt: iso(7200), now: now)
        #expect(instant == now.addingTimeInterval(7200))
    }
}
