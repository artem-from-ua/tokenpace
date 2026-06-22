import Testing
import Foundation
@testable import CCTimerKit

// MARK: - Shared fixtures

/// A fixed "current time" so the idle decision and reset countdown are deterministic.
private let now = Date(timeIntervalSince1970: 1_000_000)

/// An ISO-8601 `resets_at` string `seconds` in the future relative to ``now`` — the same shape the
/// API emits (the microsecond fraction is irrelevant to `ResetClock.parse`, which strips it).
private func resetsAt(inSeconds seconds: TimeInterval) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    return iso.string(from: now.addingTimeInterval(seconds))
}

/// A snapshot with explicit utilisations and resets, defaulting both windows to a far-off reset
/// (well over 90 min) so the countdown is the absolute branch unless a test overrides it.
private func snapshot(
    fiveHourUtil: Double,
    sevenDayUtil: Double,
    fiveHourResetsIn: TimeInterval = 4 * 3600,
    sevenDayResetsIn: TimeInterval = 3 * 24 * 3600
) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: fiveHourUtil, resetsAt: resetsAt(inSeconds: fiveHourResetsIn)),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: resetsAt(inSeconds: sevenDayResetsIn))
    )
}

// MARK: - idle vs expanded

@Suite("MenuBarLayout.make")
struct MenuBarLayoutMakeTests {

    @Test func bothWindowsLowIsIdle() {
        // Both under 5 % and far from any cap → compact glyph.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 2, sevenDayUtil: 1), now: now)
        #expect(layout.mode == .idle)
    }

    @Test func zeroUtilizationIsIdle() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 0, sevenDayUtil: 0), now: now)
        #expect(layout.mode == .idle)
    }

    @Test func fiveHourAboveThresholdExpands() {
        // One window crossing the threshold is enough to expand.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 12, sevenDayUtil: 1), now: now)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return
        }
    }

    @Test func sevenDayAboveThresholdExpands() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 1, sevenDayUtil: 40), now: now)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return
        }
    }

    @Test func exactlyThresholdExpands() {
        // Boundary: utilisation == 5.0 is NOT idle (strict `<`), so the widget expands.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 5, sevenDayUtil: 5), now: now)
        guard case .expanded = layout.mode else {
            Issue.record("expected .expanded at exactly 5%, got \(layout.mode)")
            return
        }
    }

    @Test func justBelowThresholdIsIdle() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 4.999, sevenDayUtil: 4.999), now: now)
        #expect(layout.mode == .idle)
    }
}

// MARK: - expanded content

@Suite("MenuBarLayout expanded content")
struct MenuBarLayoutExpandedTests {

    /// Pull the associated values out of an expanded mode, or fail the test.
    private func expanded(
        _ layout: MenuBarLayout
    ) -> (five: BarView, seven: BarView, reset: TimeToReset, which: LimitWindow)? {
        guard case let .expanded(five, seven, reset, which) = layout.mode else {
            Issue.record("expected .expanded, got \(layout.mode)")
            return nil
        }
        return (five, seven, reset, which)
    }

    @Test func barsCarryTheirWindows() {
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 50, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.window == .fiveHour)
        #expect(e.seven.window == .sevenDay)
    }

    @Test func barLayoutMatchesPacingModel() {
        // The view's geometry must be exactly what PacingModel produces — no re-derivation.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30, fiveHourResetsIn: 4 * 3600)
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }

        let expectedFive = PacingModel.barLayout(
            utilization: 50,
            resetsAt: ResetClock.parse(snap.fiveHour.resetsAt)!,
            now: now,
            window: .fiveHour
        )
        #expect(e.five.layout == expectedFive)
    }

    @Test func resetMatchesResetClock() {
        // `which`/`reset` must equal a direct ResetClock.resetDisplay call on the same inputs.
        let snap = snapshot(
            fiveHourUtil: 50, sevenDayUtil: 30,
            fiveHourResetsIn: 30 * 60,        // 30 min → nearest, relative branch
            sevenDayResetsIn: 3 * 24 * 3600
        )
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }

        let expected = ResetClock.resetDisplay(
            fiveHourResetsAt: snap.fiveHour.resetsAt,
            sevenDayResetsAt: snap.sevenDay.resetsAt,
            now: now
        )!
        #expect(e.which == expected.which)
        #expect(e.reset == expected.display)
        #expect(e.which == .fiveHour)                 // 5h resets first here
    }

    @Test func criticalUtilizationSurfacesIndicator() {
        // utilisation == 100 → .critical on that bar (PacingModel), and the widget is expanded.
        let layout = MenuBarLayout.make(from: snapshot(fiveHourUtil: 100, sevenDayUtil: 30), now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.five.indicator == .critical)
    }

    @Test func unparseableResetsFallBackToResetNow() {
        // Both resets_at malformed → resetDisplay returns nil → fallback (.fiveHour, .resetNow).
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 50, resetsAt: "garbage"),
            sevenDay: UsageWindow(utilization: 30, resetsAt: "null")
        )
        let layout = MenuBarLayout.make(from: snap, now: now)
        guard let e = expanded(layout) else { return }
        #expect(e.reset == .resetNow)
        #expect(e.which == .fiveHour)
    }

    @Test func missingPerModelWindowsDoNotBreakLayout() {
        // seven_day_opus / _sonnet absent (the common case) — layout still builds.
        let snap = snapshot(fiveHourUtil: 50, sevenDayUtil: 30)
        #expect(snap.sevenDayOpus == nil && snap.sevenDaySonnet == nil)
        let layout = MenuBarLayout.make(from: snap, now: now)
        #expect(expanded(layout) != nil)
    }
}
