import Testing
import Foundation
@testable import CCTimerKit

// MARK: - Shared fixtures

/// A fixed "current time" so reset countdowns and the data-age math are deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// An ISO-8601 `resets_at` string `seconds` in the future relative to ``now``.
private func resetsAt(inSeconds seconds: TimeInterval) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    return iso.string(from: now.addingTimeInterval(seconds))
}

/// A snapshot with explicit utilisations + resets and optional per-model windows. The 7-day
/// window defaults to 3 days out (so its absolute time is omitted unless a test brings it inside
/// 24 h); the 5-hour window defaults to 4 h out (always within 24 h).
private func snapshot(
    fiveHourUtil: Double,
    sevenDayUtil: Double,
    fiveHourResetsIn: TimeInterval = 4 * 3600,
    sevenDayResetsIn: TimeInterval = 3 * 24 * 3600,
    opus: (util: Double, resetsIn: TimeInterval)? = nil,
    sonnet: (util: Double, resetsIn: TimeInterval)? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: fiveHourUtil, resetsAt: resetsAt(inSeconds: fiveHourResetsIn)),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: sevenDayResetsIn)),
        sevenDayOpus: opus.map { UsageWindow(utilization: $0.util, resetsAt: resetsAt(inSeconds: $0.resetsIn)) },
        sevenDaySonnet: sonnet.map { UsageWindow(utilization: $0.util, resetsAt: resetsAt(inSeconds: $0.resetsIn)) }
    )
}

private func layout(from snap: UsageSnapshot) -> PopupLayout {
    PopupLayout.make(from: snap, now: now, lastUpdate: now, interval: PollingBackoff.defaultInterval)
}

// MARK: - Rows: order and identity

@Suite("PopupLayout rows")
struct PopupLayoutRowsTests {

    @Test func primaryRowsComeFirstInOrder() {
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30))
        #expect(p.rows.count == 2)
        #expect(p.rows[0].title == "5-hour limit")
        #expect(p.rows[1].title == "7-day limit")
    }

    @Test func utilizationAndPacingPassThrough() {
        let snap = snapshot(fiveHourUtil: 42.5, sevenDayUtil: 73.0)
        let p = layout(from: snap)
        #expect(p.rows[0].utilization == 42.5)
        #expect(p.rows[1].utilization == 73.0)

        let expected = PacingModel.barLayout(
            utilization: 42.5, resetsAt: ResetClock.parse(snap.fiveHour.resetsAt)!, now: now, window: .fiveHour
        )
        #expect(p.rows[0].pacing == expected.pacing)
        #expect(p.rows[0].bar == expected)
        #expect(p.rows[0].indicator == PacingModel.limitIndicator(
            utilization: 42.5, timePercent: expected.timeFraction * 100
        ))
    }

    @Test func criticalUtilizationSurfacesIndicator() {
        let p = layout(from: snapshot(fiveHourUtil: 100, sevenDayUtil: 30))
        #expect(p.rows[0].indicator == .critical)
    }
}

// MARK: - Tick-ruler subdivisions (issue #38)

@Suite("PopupLayout tick subdivisions")
struct PopupLayoutSubdivisionsTests {

    @Test func fiveHourSplitsIntoFive() {
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30))
        #expect(p.rows[0].subdivisions == 5)   // 5-hour limit → hour boundaries
    }

    @Test func sevenDaySplitsIntoSeven() {
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30))
        #expect(p.rows[1].subdivisions == 7)   // 7-day limit → day boundaries
    }

    @Test func perModelRowsUseSevenDaySubdivisions() {
        // Opus/Sonnet windows are paced as `.sevenDay`, so their ruler also splits into 7.
        let p = layout(from: snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            opus: (util: 5, resetsIn: 3 * 24 * 3600),
            sonnet: (util: 2, resetsIn: 3 * 24 * 3600)
        ))
        #expect(p.rows[2].subdivisions == 7)   // Opus (7-day)
        #expect(p.rows[3].subdivisions == 7)   // Sonnet (7-day)
    }
}

// MARK: - Reset split: relative always, absolute only within 24 h

@Suite("PopupLayout reset split")
struct PopupLayoutResetTests {

    @Test func fiveHourAlwaysHasAbsolute() {
        // 5h resets within 24 h by definition → "@ hh:mm" shown.
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, fiveHourResetsIn: 4 * 3600))
        #expect(p.rows[0].resetRelative != nil)
        #expect(p.rows[0].resetAbsolute != nil)
    }

    @Test func sevenDayFarOffOmitsAbsolute() {
        // 7d resets 3 days out → relative only, no clock time.
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, sevenDayResetsIn: 3 * 24 * 3600))
        #expect(p.rows[1].resetRelative != nil)
        #expect(p.rows[1].resetAbsolute == nil)
    }

    @Test func sevenDayWithinDayShowsAbsolute() {
        // 7d in its final hours (< 24 h) → clock time appears.
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, sevenDayResetsIn: 5 * 3600))
        #expect(p.rows[1].resetAbsolute != nil)
    }

    @Test func relativeMatchesResetClock() {
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30, sevenDayResetsIn: 3 * 24 * 3600)
        let p = layout(from: snap)
        let expected = ResetClock.relativeRounded(resetsAt: ResetClock.parse(snap.sevenDay.resetsAt)!, now: now)
        #expect(p.rows[1].resetRelative == expected)
    }

    @Test func unparseableResetGivesNilStrings() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "null")
        )
        let p = layout(from: snap)
        #expect(p.rows[0].resetRelative == nil && p.rows[0].resetAbsolute == nil)
        #expect(p.rows[1].resetRelative == nil && p.rows[1].resetAbsolute == nil)
    }
}

// MARK: - Per-model breakdown

@Suite("PopupLayout per-model breakdown")
struct PopupLayoutModelTests {

    @Test func noModelRowsWhenAbsent() {
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)
        #expect(snap.sevenDayOpus == nil && snap.sevenDaySonnet == nil)
        let p = layout(from: snap)
        #expect(p.rows.count == 2)   // only 5h + 7d
    }

    @Test func modelRowsAppendedWithTitles() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            opus: (util: 5, resetsIn: 3 * 24 * 3600),
            sonnet: (util: 2, resetsIn: 3 * 24 * 3600)
        )
        let p = layout(from: snap)
        #expect(p.rows.count == 4)
        #expect(p.rows[2].title == "Opus (7-day)")
        #expect(p.rows[2].utilization == 5)
        #expect(p.rows[3].title == "Sonnet (7-day)")
        #expect(p.rows[3].utilization == 2)
    }

    @Test func onlySonnetPresentDoesNotCrash() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            sonnet: (util: 2, resetsIn: 3 * 24 * 3600)
        )
        let p = layout(from: snap)
        #expect(p.rows.count == 3)
        #expect(p.rows[2].title == "Sonnet (7-day)")
    }

    @Test func modelPacedAsSevenDay() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            sonnet: (util: 95, resetsIn: 3 * 24 * 3600)
        )
        let p = layout(from: snap)
        let parsed = ResetClock.parse(snap.sevenDaySonnet!.resetsAt)!
        let expected = PacingModel.barLayout(utilization: 95, resetsAt: parsed, now: now, window: .sevenDay)
        #expect(p.rows[2].bar == expected)
        #expect(p.rows[2].pacing == expected.pacing)
    }
}

// MARK: - Service line

@Suite("PopupLayout service line")
struct PopupLayoutServiceTests {

    @Test func ageIsNowMinusLastUpdate() {
        let p = PopupLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now,
            lastUpdate: now.addingTimeInterval(-120), interval: PollingBackoff.defaultInterval
        )
        #expect(p.lastUpdateAge == 120)
    }

    @Test func ageClampsToZeroOnClockSkew() {
        let p = PopupLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now,
            lastUpdate: now.addingTimeInterval(60), interval: PollingBackoff.defaultInterval
        )
        #expect(p.lastUpdateAge == 0)
    }

    @Test func intervalPassesThroughHealthy() {
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30))
        #expect(p.intervalSeconds == 180)
    }

    @Test func intervalReflectsBackoffStep() {
        let backoff = PollingBackoff().escalated().escalated()   // 3 → 6 min
        let p = PopupLayout.make(
            from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now,
            lastUpdate: now, interval: backoff.interval
        )
        #expect(p.intervalSeconds == 6 * 60)
    }
}

// MARK: - health-aware make (warning banner, issue #12)

@Suite("PopupLayout.make health-aware")
struct PopupLayoutHealthTests {

    private let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)

    private func health(failingFor age: TimeInterval?, reason: FailureReason = .notSignedIn) -> UsageHealth {
        guard let age else { return .healthy(lastSuccess: now) }
        return UsageHealth(
            lastSuccess: now.addingTimeInterval(-age),
            failingSince: now.addingTimeInterval(-age),
            reason: reason
        )
    }

    @Test func healthyHasNoWarning() {
        let p = PopupLayout.make(from: snap, health: health(failingFor: nil), now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.warning == nil)
    }

    @Test func warningAppearsImmediatelyOnFailure() {
        // Even 1 s of failure surfaces the popup warning — no 30-min wait (acceptance #2).
        let p = PopupLayout.make(from: snap, health: health(failingFor: 1), now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.warning == .notSignedIn)
    }

    @Test func warningCarriesReasonAndBody() {
        let p = PopupLayout.make(
            from: snap, health: health(failingFor: 5, reason: .authHTTP(status: 401, body: "Bad token")),
            now: now, interval: PollingBackoff.defaultInterval)
        #expect(p.warning == .authHTTP(status: 401, body: "Bad token"))
    }

    @Test func staleRowsComeFromLastSnapshot() {
        // While failing, the last known snapshot still populates the sections (stale display).
        let p = PopupLayout.make(from: snap, health: health(failingFor: 10 * 60), now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.rows.count == 2)
        #expect(p.warning != nil)
    }

    @Test func coldStartFailureHasEmptyRowsButWarning() {
        // No snapshot yet → the warning stands alone, no sections.
        let coldHealth = UsageHealth(lastSuccess: nil, failingSince: now.addingTimeInterval(-60), reason: .notSignedIn)
        let p = PopupLayout.make(from: nil, health: coldHealth, now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.rows.isEmpty)
        #expect(p.warning == .notSignedIn)
        #expect(p.lastUpdateAge == 0)   // never succeeded → 0, not negative
    }

    @Test func lastUpdateAgeMeasuresFromLastSuccess() {
        // Service line shows staleness from the last 200 (acceptance #3): 20 min ago → 1200 s.
        let p = PopupLayout.make(from: snap, health: health(failingFor: 20 * 60), now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.lastUpdateAge == 20 * 60)
    }
}

// MARK: - Service status pass-through (#31)

@Suite("PopupLayout service status")
struct PopupLayoutServiceStatusTests {

    private let healthy = UsageHealth.healthy(lastSuccess: now)
    private let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)

    @Test func nilByDefault() {
        // Cold start / not passed → no status lines.
        let p = PopupLayout.make(from: snap, health: healthy, now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.serviceStatus == nil)
    }

    @Test func passesThroughUnchanged() {
        let status = StatusHealth(claudeCode: .operational, claudeAPI: .degraded)
        let p = PopupLayout.make(from: snap, health: healthy, now: now,
                                 interval: PollingBackoff.defaultInterval, serviceStatus: status)
        #expect(p.serviceStatus == status)
    }

    @Test func independentOfUsageWarning() {
        // A failing usage poll still carries the (separately-polled) service status.
        let failing = UsageHealth(lastSuccess: now, failingSince: now.addingTimeInterval(-60), reason: .timeout)
        let status = StatusHealth.unknown
        let p = PopupLayout.make(from: snap, health: failing, now: now,
                                 interval: PollingBackoff.defaultInterval, serviceStatus: status)
        #expect(p.warning == .timeout)
        #expect(p.serviceStatus == .unknown)
    }
}
