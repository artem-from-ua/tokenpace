import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - WorkAvailability.canWork

/// A workable base window (well under 100%).
private func lowWindow() -> UsageWindow { UsageWindow(utilization: 40, resetsAt: "") }
/// An exhausted base window (server caps utilization at 100).
private func fullWindow() -> UsageWindow { UsageWindow(utilization: 100, resetsAt: "") }

@Suite("WorkAvailability.canWork")
struct WorkAvailabilityTests {

    @Test func bothWindowsLowIsWorkable() {
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: lowWindow())
        #expect(WorkAvailability.canWork(snap) == true)
    }

    @Test func sevenDayExhaustedNoCreditsIsBlocked() {
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: nil)
        #expect(WorkAvailability.canWork(snap) == false)
    }

    @Test func fiveHourExhaustedNoCreditsIsBlocked() {
        let snap = UsageSnapshot(fiveHour: fullWindow(), sevenDay: lowWindow(), spend: nil)
        #expect(WorkAvailability.canWork(snap) == false)
    }

    @Test func baseExhaustedButCreditsActivelySpendingIsWorkable() {
        // enabled && !spend_limit_reached && baseLimitExhausted → isSpending == true → workable.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(WorkAvailability.canWork(snap) == true)
    }

    @Test func baseExhaustedAndCreditsCappedIsBlocked() {
        // At the money cap the server sends enabled:false + spend_limit_reached:true → not spending.
        let spend = SpendInfo(enabled: false, spendLimitReached: true)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(WorkAvailability.canWork(snap) == false)
    }

    @Test func creditsResetAfterCapIsWorkableAgain() {
        // After the extra-usage window resets: spend_limit_reached flips back to false, enabled true.
        // This is the "extra usage reset" unblock edge — must read as workable.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(WorkAvailability.canWork(snap) == true)
    }

    @Test func idleFiveHourWithLowSevenDayIsWorkable() {
        // sessionIdle: the 5h window carries utilization 0 → not exhausted → "ready to start".
        let idle = UsageWindow(utilization: 0, resetsAt: "")
        let snap = UsageSnapshot(fiveHour: idle, sevenDay: lowWindow(), sessionIdle: true)
        #expect(WorkAvailability.canWork(snap) == true)
    }

    @Test func perModelWeeklyExhaustedIsBlocked() {
        // A per-model sub-window at 100% counts via anyBaseLimitExhausted even when 5h/7d are low.
        let snap = UsageSnapshot(
            fiveHour: lowWindow(),
            sevenDay: lowWindow(),
            sevenDayOpus: fullWindow(),
            spend: nil
        )
        #expect(WorkAvailability.canWork(snap) == false)
    }

    @Test func sonnetWeeklyExhaustedIsBlocked() {
        let snap = UsageSnapshot(
            fiveHour: lowWindow(),
            sevenDay: lowWindow(),
            sevenDaySonnet: fullWindow(),
            spend: nil
        )
        #expect(WorkAvailability.canWork(snap) == false)
    }
}
