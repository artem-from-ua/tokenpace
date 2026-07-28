import Testing
import Foundation
@testable import TokenPaceKit

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
    sonnet: (util: Double, resetsIn: TimeInterval)? = nil,
    limits: [UsageLimit] = [],
    spend: SpendInfo? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: fiveHourUtil, resetsAt: resetsAt(inSeconds: fiveHourResetsIn)),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: sevenDayResetsIn)),
        sevenDayOpus: opus.map { UsageWindow(utilization: $0.util, resetsAt: resetsAt(inSeconds: $0.resetsIn)) },
        sevenDaySonnet: sonnet.map { UsageWindow(utilization: $0.util, resetsAt: resetsAt(inSeconds: $0.resetsIn)) },
        limits: limits,
        spend: spend
    )
}

/// A EUR ``Money`` in minor units (e.g. `eur(1077)` == €10.77).
private func eur(_ minor: Int) -> Money { Money(amountMinor: minor, currency: "EUR", exponent: 2) }

/// A `weekly_scoped` limits[] entry for a named model — the only API shape carrying models
/// without a top-level window (e.g. Fable, #65).
private func scopedLimit(name: String, percent: Double, resetsIn: TimeInterval) -> UsageLimit {
    UsageLimit(
        kind: "weekly_scoped", group: "weekly", percent: percent, severity: "normal",
        resetsAt: resetsAt(inSeconds: resetsIn), isActive: false, modelDisplayName: name)
}

/// A **session-idle** snapshot (#100): the 5h window does not exist (`sessionIdle: true`); the 7-day
/// window is normal, and an optional Fable `weekly_scoped` row can be attached.
private func idleSnapshot(
    sevenDayUtil: Double = 31,
    sevenDayResetsIn: TimeInterval = 4 * 24 * 3600,
    limits: [UsageLimit] = []
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: sevenDayResetsIn)),
        limits: limits,
        sessionIdle: true)
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
        #expect(p.rows[0].title == "5-hour")
        #expect(p.rows[1].title == "7-day")
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
        #expect(p.rows[2].subdivisions == 7)   // Opus (per-model, 7-day paced)
        #expect(p.rows[3].subdivisions == 7)   // Sonnet (per-model, 7-day paced)
    }
}

// MARK: - Unified reset line (one format for every row — #167)

@Suite("PopupLayout reset line")
struct PopupLayoutResetTests {

    @Test func fiveHourWithinDayShowsClock() {
        // 5h resets within 24 h by definition → the "Nh at hh:mm" clock band.
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, fiveHourResetsIn: 4 * 3600))
        let line = p.rows[0].resetLine
        #expect(line != nil)
        #expect(line?.contains(" at ") == true)
        #expect(line?.contains(" on ") == false)
    }

    @Test func sevenDayFarOffShowsWeekday() {
        // 7d resets 3 days out → the "Nd on <weekday>" band (no clock).
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, sevenDayResetsIn: 3 * 24 * 3600))
        let line = p.rows[1].resetLine
        #expect(line?.contains(" on ") == true)
        #expect(line?.contains(" at ") == false)
    }

    @Test func sevenDayWithinDayShowsClockNotWeekday() {
        // 7d in its final hours (< 24 h) → clock time appears, no weekday.
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, sevenDayResetsIn: 5 * 3600))
        let line = p.rows[1].resetLine
        #expect(line?.contains(" at ") == true)
        #expect(line?.contains(" on ") == false)
    }

    @Test func lineMatchesResetClock() {
        // The row carries exactly what the pure formatter produces (same `now`/defaults) — the layout
        // adds no arithmetic of its own.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30, sevenDayResetsIn: 3 * 24 * 3600)
        let p = layout(from: snap)
        let expected = ResetClock.resetLine(resetsAt: ResetClock.parse(snap.sevenDay.resetsAt)!, now: now)
        #expect(p.rows[1].resetLine == expected)
    }

    @Test func unparseableResetGivesNilLine() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "null")
        )
        let p = layout(from: snap)
        #expect(p.rows[0].resetLine == nil)
        #expect(p.rows[1].resetLine == nil)
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
        #expect(p.rows[2].title == "Opus")
        #expect(p.rows[2].utilization == 5)
        #expect(p.rows[3].title == "Sonnet")
        #expect(p.rows[3].utilization == 2)
    }

    @Test func onlySonnetPresentDoesNotCrash() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            sonnet: (util: 2, resetsIn: 3 * 24 * 3600)
        )
        let p = layout(from: snap)
        #expect(p.rows.count == 3)
        #expect(p.rows[2].title == "Sonnet")
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

// MARK: - Scoped models from limits[] (#65)

@Suite("PopupLayout scoped-model rows")
struct PopupLayoutScopedModelTests {

    @Test func fableRowAppendedAfterLegacyRows() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            opus: (util: 5, resetsIn: 3 * 24 * 3600),
            sonnet: (util: 2, resetsIn: 3 * 24 * 3600),
            limits: [scopedLimit(name: "Fable", percent: 12, resetsIn: 3 * 24 * 3600)]
        )
        let p = layout(from: snap)
        #expect(p.rows.count == 5)
        #expect(p.rows[4].title == "Fable")
        #expect(p.rows[4].utilization == 12)
    }

    @Test func fableRowWithoutLegacyModels() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            limits: [scopedLimit(name: "Fable", percent: 5, resetsIn: 3 * 24 * 3600)]
        )
        let p = layout(from: snap)
        #expect(p.rows.count == 3)
        #expect(p.rows[2].title == "Fable")
    }

    @Test func scopedRowPacedAsSevenDay() {
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            limits: [scopedLimit(name: "Fable", percent: 95, resetsIn: 3 * 24 * 3600)]
        )
        let p = layout(from: snap)
        let parsed = ResetClock.parse(snap.scopedModelWindows[0].window.resetsAt)!
        let expected = PacingModel.barLayout(utilization: 95, resetsAt: parsed, now: now, window: .sevenDay)
        #expect(p.rows[2].bar == expected)
        #expect(p.rows[2].subdivisions == 7)
    }

    @Test func scopedSonnetSkippedWhenLegacySonnetPresent() {
        // Live bodies carry Sonnet in both forms at once — exactly one row must render.
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            sonnet: (util: 2.5, resetsIn: 3 * 24 * 3600),
            limits: [
                scopedLimit(name: "Sonnet", percent: 2, resetsIn: 3 * 24 * 3600),
                scopedLimit(name: "Fable", percent: 5, resetsIn: 3 * 24 * 3600),
            ]
        )
        let p = layout(from: snap)
        #expect(p.rows.count == 4)   // 5h, 7d, Sonnet (legacy), Fable (scoped)
        #expect(p.rows.filter { $0.title.contains("Sonnet") }.count == 1)
        #expect(p.rows[2].utilization == 2.5)   // the legacy window's decimal value won
        #expect(p.rows[3].title == "Fable")
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

    @Test func intervalReflectsBackoffHold() {
        let backoff = PollingBackoff().honoring(retryAfter: 6 * 60)   // Retry-After hold
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

    @Test func brokenActiveResetSurfacesServerProblemWarningAndNoRows() {
        // A healthy poll whose active window has a non-empty, unparseable `resets_at` is a malformed
        // 200 body → the popup shows **only** the red warning banner (`.serverProblem`) with **no** rows
        // or credits — the current snapshot is corrupt, so nothing is rendered (like a cold-start
        // failure), symmetric with the menu bar's ⚠️ error state (#167, ADR-0043).
        let broken = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: "not-a-date"),
            sevenDay: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let p = PopupLayout.make(from: broken, health: health(failingFor: nil), now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.warning == .serverProblem)
        #expect(p.rows.isEmpty)         // corrupt data → render nothing but the banner
        #expect(p.credits == nil)
        #expect(p.blockingReset == nil)
    }

    @Test func blankOrValidResetHasNoServerProblemWarning() {
        // A blank date (boundary/synthesis) or a valid date is not a malformed value → no warning.
        let valid = PopupLayout.make(from: snap, health: health(failingFor: nil), now: now,
                                     interval: PollingBackoff.defaultInterval)
        #expect(valid.warning == nil)
        let blank = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)),
            sessionIdle: true)
        let p = PopupLayout.make(from: blank, health: health(failingFor: nil), now: now,
                                 interval: PollingBackoff.defaultInterval)
        #expect(p.warning == nil)
    }

    @Test func realFailureReasonWinsOverBrokenReset() {
        // When the poll is genuinely failing, its own reason wins over the broken-reset .serverProblem.
        let broken = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 100, resetsAt: "not-a-date"),
            sevenDay: UsageWindow(utilization: 20, resetsAt: resetsAt(inSeconds: 3 * 24 * 3600)))
        let p = PopupLayout.make(from: broken, health: health(failingFor: 5, reason: .tokenExpired),
                                 now: now, interval: PollingBackoff.defaultInterval)
        #expect(p.warning == .tokenExpired)
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
        let status = StatusHealth.from(StatusSummary(components: [
            StatusComponent(name: "Claude API (api.anthropic.com)", status: "operational"),
            StatusComponent(name: "Claude Code", status: "degraded_performance"),
        ]), config: .default)
        let p = PopupLayout.make(from: snap, health: healthy, now: now,
                                 interval: PollingBackoff.defaultInterval, serviceStatus: status)
        #expect(p.serviceStatus == status)
    }

    @Test func independentOfUsageWarning() {
        // A failing usage poll still carries the (separately-polled) service status.
        let failing = UsageHealth(lastSuccess: now, failingSince: now.addingTimeInterval(-60), reason: .timeout)
        let status = StatusHealth.unknown(for: .default)
        let p = PopupLayout.make(from: snap, health: failing, now: now,
                                 interval: PollingBackoff.defaultInterval, serviceStatus: status)
        #expect(p.warning == .timeout)
        #expect(p.serviceStatus == status)
    }
}

// MARK: - session-idle 5-hour row (#100, ADR-0027)

@Suite("PopupLayout session-idle row")
struct PopupLayoutIdleTests {

    @Test func idleFiveHourRowHasNoResetLine() {
        let p = layout(from: idleSnapshot())
        let five = p.rows[0]
        #expect(five.title == "5-hour")
        #expect(five.sessionIdle)
        #expect(five.resetLine == nil)
        #expect(five.subdivisions == LimitWindow.fiveHour.subdivisions)   // ruler stays in family
    }

    @Test func idleLeavesOtherRowsNormal() {
        // The 7-day row and a Fable scoped row are unaffected — only the 5h row goes idle.
        let p = layout(from: idleSnapshot(limits: [
            scopedLimit(name: "Fable", percent: 15, resetsIn: 4 * 24 * 3600)]))
        let seven = p.rows[1]
        #expect(seven.title == "7-day")
        #expect(!seven.sessionIdle)
        #expect(seven.utilization == 31)
        #expect(seven.resetLine != nil)

        let fable = p.rows.first { $0.title == "Fable" }
        #expect(fable != nil)
        #expect(fable?.sessionIdle == false)
        #expect(fable?.utilization == 15)
    }

    @Test func normalRowDefaultsToNotIdle() {
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30))
        #expect(!p.rows[0].sessionIdle)
        #expect(!p.rows[1].sessionIdle)
    }

    // MARK: idle-blocked (#158)

    /// An idle snapshot with an explicit 7-day utilisation and optional spend, for the blocked-state
    /// tests (`idleSnapshot` cannot carry spend).
    private func idleBlockedSnapshot(sevenDayUtil: Double, spend: SpendInfo?) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: 4 * 24 * 3600)),
            sessionIdle: true, spend: spend)
    }

    @Test func plainIdleIsNotBlocked() {
        let p = layout(from: idleSnapshot())
        #expect(p.rows[0].sessionIdle)
        #expect(!p.rows[0].sessionBlocked)
        #expect(p.blockingReset == nil)
    }

    @Test func idleBlockedFlagsRowAndPointsAtSevenDay() {
        // 7d exhausted, no credits → idle row is blocked and the blocking reset is the 7-day row.
        // 7-day is popup row index 1.
        let p = layout(from: idleBlockedSnapshot(sevenDayUtil: 100, spend: nil))
        #expect(p.rows[0].sessionBlocked)
        guard case let .token(id, _)? = p.blockingReset else {
            Issue.record("expected a token blocking reset, got \(String(describing: p.blockingReset))")
            return
        }
        #expect(id == 1)   // the 7-day row
        #expect(p.rows[id].title == "7-day")
    }

    @Test func idleWithCreditsCoverIsNotBlocked() {
        let cover = SpendInfo(enabled: true, spendLimitReached: false)
        let p = layout(from: idleBlockedSnapshot(sevenDayUtil: 100, spend: cover))
        #expect(!p.rows[0].sessionBlocked)
        #expect(p.blockingReset == nil)
    }

    @Test func idleWithCappedCreditsPointsAtSevenDay() {
        // Both 7d and credits exhausted; 7-day reset (4d) is far sooner than the monthly credits reset,
        // so the blocking reset is the 7-day row (last-stand rule), not the credits section.
        let capped = SpendInfo(limit: eur(500), enabled: false, spendLimitReached: true)
        let p = layout(from: idleBlockedSnapshot(sevenDayUtil: 100, spend: capped))
        #expect(p.rows[0].sessionBlocked)
        guard case let .token(id, _)? = p.blockingReset else {
            Issue.record("expected a token blocking reset, got \(String(describing: p.blockingReset))")
            return
        }
        #expect(id == 1)
    }

    @Test func activeFullyExhaustedBadgesSevenDayNotIdle() {
        // The `both-red` screen: active session, 5h and 7d both at 100 %, no credits. Not idle → the 5h
        // row is a normal "limit reached" row (NOT sessionBlocked), but the blocking reset still points
        // at the 7-day row (index 1, its reset is later than 5h) so the red badge shows there.
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 100,
                            fiveHourResetsIn: 2 * 3600, sevenDayResetsIn: 4 * 24 * 3600)
        let p = layout(from: snap)
        #expect(!p.rows[0].sessionIdle)
        #expect(!p.rows[0].sessionBlocked)
        guard case let .token(id, _)? = p.blockingReset else {
            Issue.record("expected a token blocking reset, got \(String(describing: p.blockingReset))")
            return
        }
        #expect(id == 1)   // 7-day, the later reset
    }

    @Test func activeFiveExhaustedBadgesFiveDayNotIdle() {
        // 5h at 100 %, 7d still has room → the 5h window blocks on its own (#177). Not idle → the 5h row
        // is a normal "limit reached" row (NOT sessionBlocked); only 5h is a candidate (≥100), so the
        // red badge points at the 5-hour row (index 0).
        let snap = snapshot(fiveHourUtil: 100, sevenDayUtil: 40)
        let p = layout(from: snap)
        #expect(!p.rows[0].sessionIdle)
        #expect(!p.rows[0].sessionBlocked)
        guard case let .token(id, _)? = p.blockingReset else {
            Issue.record("expected a token blocking reset, got \(String(describing: p.blockingReset))")
            return
        }
        #expect(id == 0)   // 5-hour, the only exhausted window
        #expect(p.rows[id].title == "5-hour")
    }

    @Test func activeSevenExhaustedFiveHasQuotaBadgesSevenDay() {
        // Артем's #177 bug: active session, 7d at 100 % but 5h still below (48 %), no credits. Before the
        // fix isBlocked was false → no red badge. Now the weekly cap blocks: only 7d is a candidate, so
        // the badge points at the 7-day row (index 1). The 5h row stays a normal (non-blocked) row.
        let snap = snapshot(fiveHourUtil: 48, sevenDayUtil: 100)
        let p = layout(from: snap)
        #expect(!p.rows[0].sessionIdle)
        #expect(!p.rows[0].sessionBlocked)
        guard case let .token(id, _)? = p.blockingReset else {
            Issue.record("expected a token blocking reset, got \(String(describing: p.blockingReset))")
            return
        }
        #expect(id == 1)   // the 7-day row
        #expect(p.rows[id].title == "7-day")
    }
}

// MARK: - Extra usage (money-credits) row (#145)

@Suite("PopupLayout credits row")
struct PopupLayoutCreditsTests {

    /// No `spend` block → no credits section (the pre-credits path).
    @Test func absentWhenNoSpend() {
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30))
        #expect(p.credits == nil)
    }

    /// `spend` present but inactive (not enabled, cap not reached) → no section — the dropdown gate is
    /// `CreditsPacing.isActive`.
    @Test func absentWhenInactive() {
        let spend = SpendInfo(used: eur(1077), limit: eur(1500), enabled: false, spendLimitReached: false)
        let p = layout(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30, spend: spend))
        #expect(p.credits == nil)
    }

    /// Dropdown gate is **softer** than the menu-bar icon's: credits enabled is enough — no base limit
    /// need be exhausted (the icon requires that, the detail view does not).
    @Test func shownWhenEnabledEvenWithNoBaseLimitExhausted() {
        let spend = SpendInfo(used: eur(1077), limit: eur(1500), enabled: true)
        // Both base windows low → no base limit exhausted; the section must still appear.
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 20, spend: spend))
        #expect(p.credits != nil)
    }

    /// Limit set: spent/limit carried verbatim, a bar present, and a reset countdown to month end.
    @Test func limitSetCarriesRawFieldsAndBar() {
        let spend = SpendInfo(used: eur(1077), limit: eur(1500), enabled: true)
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 20, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.spent == eur(1077))
        #expect(credits.limit == eur(1500))
        #expect(credits.bar == CreditsPacing.barLayout(for: spend, now: now))
        #expect(credits.bar != nil)
        // Reset line matches the unified formatter fed the month-end instant — the same "Nd on <weekday>"
        // shape every other row uses (#167), no longer a bare relative "6d".
        let monthEnd = CreditsPacing.monthEnd(now: now)!
        #expect(credits.resetLine == ResetClock.resetLine(resetsAt: monthEnd, now: now))
    }

    /// Cap reached: `spend_limit_reached` forces a full bar (red rung) even below the raw fraction.
    @Test func limitReachedForcesFullBar() {
        let spend = SpendInfo(
            used: eur(1077), limit: eur(500), enabled: false, spendLimitReached: true)
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 20, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.bar?.usageFraction == 1)
    }

    /// Unlimited (`limit == nil`): a spent amount, but **no** bar and **no** reset line.
    @Test func unlimitedHasNoBarNoReset() {
        let spend = SpendInfo(used: eur(1077), limit: nil, enabled: true)
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 20, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.spent == eur(1077))
        #expect(credits.limit == nil)
        #expect(credits.bar == nil)
        #expect(credits.resetLine == nil)
    }

    /// When `spend.used` is absent, the amount is reconstructed from the `used_credits` scalar +
    /// currency/decimal_places so the line still shows a value.
    @Test func spentReconstructedFromScalarWhenUsedAbsent() {
        let spend = SpendInfo(
            used: nil, limit: eur(1500), enabled: true,
            usedCredits: 1077.0, currency: "EUR", decimalPlaces: 2)
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 20, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.spent == eur(1077))
    }

    /// `inUse` (the blue "in use" badge, #146) is `false` when the section shows only because credits
    /// are enabled but **no** base limit is exhausted — credits are armed, not actually spending yet.
    @Test func inUseFalseWhenNoBaseLimitExhausted() {
        let spend = SpendInfo(used: eur(1077), limit: eur(1500), enabled: true)
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 20, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.inUse == false)
    }

    /// `inUse` is `true` once a base limit is exhausted (here 7-day at 100 %) — the same gate as the
    /// menu-bar icon, so credits are genuinely covering an overflowing plan limit.
    @Test func inUseTrueWhenBaseLimitExhausted() {
        let spend = SpendInfo(used: eur(1077), limit: eur(1500), enabled: true)
        let p = layout(from: snapshot(fiveHourUtil: 10, sevenDayUtil: 100, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.inUse == true)
    }

    /// `inUse` is **`false`** once the money cap is reached (`spend_limit_reached` → the server sets
    /// `enabled: false`): credits are no longer covering anything (Claude is blocked), so the "active"
    /// badge must not show — even though the section (and the red menu-bar icon) still appear.
    @Test func inUseFalseWhenSpendLimitReached() {
        let spend = SpendInfo(
            used: eur(1077), limit: eur(500), enabled: false, spendLimitReached: true)
        let p = layout(from: snapshot(fiveHourUtil: 100, sevenDayUtil: 30, spend: spend))
        let credits = try! #require(p.credits)
        #expect(credits.inUse == false)
    }
}

// MARK: - CreditsPacing.monthEnd (#145)

@Suite("CreditsPacing.monthEnd")
struct CreditsPacingMonthEndTests {

    /// Month end is the next 00:00 UTC on the 1st, and it is > now.
    @Test func isNextMonthStartInUTC() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // A fixed mid-month instant: 2026-03-15 12:00 UTC.
        let comps = DateComponents(year: 2026, month: 3, day: 15, hour: 12)
        let mid = cal.date(from: comps)!
        let end = CreditsPacing.monthEnd(now: mid)!
        let expected = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        #expect(end == expected)
        #expect(end > mid)
    }
}
