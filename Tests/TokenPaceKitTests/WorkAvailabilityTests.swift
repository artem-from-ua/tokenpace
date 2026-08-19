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

    @Test func perModelWeeklyExhaustedIsWorkable() {
        // A per-model sub-window (Opus) at 100% does NOT gate work — Claude blocks only on the two main
        // 5h / 7d windows, then credits (#177). Both main windows low → workable, no "Back to work!" edge.
        let snap = UsageSnapshot(
            fiveHour: lowWindow(),
            sevenDay: lowWindow(),
            sevenDayOpus: fullWindow(),
            spend: nil
        )
        #expect(WorkAvailability.canWork(snap) == true)
    }

    @Test func sonnetWeeklyExhaustedIsWorkable() {
        // Same as above for the Sonnet sub-window: a scoped model at 100% is not a work gate (#177).
        let snap = UsageSnapshot(
            fiveHour: lowWindow(),
            sevenDay: lowWindow(),
            sevenDaySonnet: fullWindow(),
            spend: nil
        )
        #expect(WorkAvailability.canWork(snap) == true)
    }
}

// MARK: - WorkAvailability.subscriptionAvailable

/// The "Back to work!" signal since #161: only the 5h / 7d subscription windows count, and Extra Usage
/// Credit never moves it in either direction. The two credit-bearing cases below are exactly where this
/// parts ways with `canWork` — they are the reason the predicate exists.
@Suite("WorkAvailability.subscriptionAvailable")
struct SubscriptionAvailabilityTests {

    @Test func bothWindowsLowIsAvailable() {
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: lowWindow())
        #expect(WorkAvailability.subscriptionAvailable(snap) == true)
    }

    @Test func sevenDayExhaustedIsUnavailable() {
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: nil)
        #expect(WorkAvailability.subscriptionAvailable(snap) == false)
    }

    @Test func fiveHourExhaustedIsUnavailable() {
        // Either main window spends the subscription on its own — you wait for that window's reset.
        let snap = UsageSnapshot(fiveHour: fullWindow(), sevenDay: lowWindow(), spend: nil)
        #expect(WorkAvailability.subscriptionAvailable(snap) == false)
    }

    @Test func exhaustedWhileCreditsCoverIsStillUnavailable() {
        // The case `canWork` gets "wrong" for this notification: credits are actively paying, so work is
        // possible, but the subscription quota is spent. Reading it as unavailable is what makes the
        // later subscription reset a real edge — under `canWork` this state is already workable, the
        // block is never entered, and the reset is announced to nobody.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(WorkAvailability.canWork(snap) == true)
        #expect(WorkAvailability.subscriptionAvailable(snap) == false)
    }

    @Test func creditsResetWhileSubscriptionStillSpentIsUnavailable() {
        // The mirror case: credits hit the cap and then reset (spend_limit_reached false, enabled true)
        // while 7d is still at 100 %. `canWork` crosses false → true here and would announce "Back to
        // work" off a credits reset; the subscription signal does not move.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(WorkAvailability.subscriptionAvailable(snap) == false)

        let capped = SpendInfo(enabled: false, spendLimitReached: true)
        let before = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: capped)
        #expect(WorkAvailability.canWork(before) == false)
        #expect(WorkAvailability.subscriptionAvailable(before) == false)
    }

    @Test func subscriptionResetWhileCreditsEnabledIsAvailable() {
        // The payoff: 7d back under 100 % with credits still enabled → available, the edge fires.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: lowWindow(), spend: spend)
        #expect(WorkAvailability.subscriptionAvailable(snap) == true)
    }

    @Test func idleFiveHourWithLowSevenDayIsAvailable() {
        // sessionIdle: the 5h window carries utilization 0 → "ready to start", not exhausted.
        let idle = UsageWindow(utilization: 0, resetsAt: "")
        let snap = UsageSnapshot(fiveHour: idle, sevenDay: lowWindow(), sessionIdle: true)
        #expect(WorkAvailability.subscriptionAvailable(snap) == true)
    }

    @Test func perModelWeeklyExhaustedIsAvailable() {
        // A per-model sub-window at 100 % is not a subscription gate (#177) — no spurious edge.
        let opus = UsageSnapshot(
            fiveHour: lowWindow(),
            sevenDay: lowWindow(),
            sevenDayOpus: fullWindow(),
            spend: nil
        )
        #expect(WorkAvailability.subscriptionAvailable(opus) == true)

        let sonnet = UsageSnapshot(
            fiveHour: lowWindow(),
            sevenDay: lowWindow(),
            sevenDaySonnet: fullWindow(),
            spend: nil
        )
        #expect(WorkAvailability.subscriptionAvailable(sonnet) == true)
    }
}
