import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - CreditsPacing.creditsCanCover / isBlocked

@Suite("CreditsPacing.creditsCanCover")
struct CreditsCanCoverTests {

    @Test func nilSpendCannotCover() {
        #expect(!CreditsPacing.creditsCanCover(nil))
    }

    @Test func enabledAndNotCappedCovers() {
        #expect(CreditsPacing.creditsCanCover(SpendInfo(enabled: true, spendLimitReached: false)))
    }

    @Test func cappedDoesNotCover() {
        // At the money cap the server sends enabled:false + spend_limit_reached:true — no cover left.
        #expect(!CreditsPacing.creditsCanCover(SpendInfo(enabled: false, spendLimitReached: true)))
    }

    @Test func disabledDoesNotCover() {
        #expect(!CreditsPacing.creditsCanCover(SpendInfo(enabled: false, spendLimitReached: false)))
    }
}

@Suite("CreditsPacing.isBlocked")
struct IsBlockedTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func iso(_ seconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: now.addingTimeInterval(seconds))
    }
    private func idle(sevenDayUtil: Double, spend: SpendInfo?) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 0, resetsAt: ""),
            sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: iso(4 * 24 * 3600)),
            sessionIdle: true, spend: spend)
    }
    /// An **active** (non-idle) snapshot with explicit 5h / 7d utilisations.
    private func active(fiveDayUtil: Double, sevenDayUtil: Double, spend: SpendInfo? = nil) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: fiveDayUtil, resetsAt: iso(2 * 3600)),
            sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: iso(4 * 24 * 3600)),
            spend: spend)
    }

    // Idle-blocked cases (5h window absent).

    @Test func idleSevenDayBelow100NotBlocked() {
        #expect(!CreditsPacing.isBlocked(in: idle(sevenDayUtil: 80, spend: nil)))
    }

    @Test func idleSevenDayExhaustedNoCreditsIsBlocked() {
        #expect(CreditsPacing.isBlocked(in: idle(sevenDayUtil: 100, spend: nil)))
    }

    @Test func idleSevenDayExhaustedButCreditsCoverIsNotBlocked() {
        let cover = SpendInfo(enabled: true, spendLimitReached: false)
        #expect(!CreditsPacing.isBlocked(in: idle(sevenDayUtil: 100, spend: cover)))
    }

    @Test func idleSevenDayExhaustedAndCreditsCappedIsBlocked() {
        let capped = SpendInfo(enabled: false, spendLimitReached: true)
        #expect(CreditsPacing.isBlocked(in: idle(sevenDayUtil: 100, spend: capped)))
    }

    // Active (non-idle) cases.

    @Test func activeBothExhaustedNoCreditsIsBlocked() {
        // The `both-red` screen: active session, 5h and 7d both at 100 %, no credits → blocked.
        #expect(CreditsPacing.isBlocked(in: active(fiveDayUtil: 100, sevenDayUtil: 100)))
    }

    @Test func activeFiveExhaustedBlocksEvenWhenSevenHasQuota() {
        // 5h spent while 7d still has room → you must wait for the 5h reset before working; blocked.
        // Either main window blocks on its own (#177).
        #expect(CreditsPacing.isBlocked(in: active(fiveDayUtil: 100, sevenDayUtil: 40)))
    }

    @Test func activeSevenExhaustedBlocksEvenWhenFiveHasQuota() {
        // 7d at 100 with the active 5h still below → the weekly cap blocks despite 5h quota (#177).
        // This is Артем's real bug: 7d exhausted, 5h at 48 %, no red blocking badge before the fix.
        #expect(CreditsPacing.isBlocked(in: active(fiveDayUtil: 30, sevenDayUtil: 100)))
    }

    @Test func activePerModelExhaustedMainWindowsHaveQuotaNotBlocked() {
        // A per-model sub-window (Opus) at 100 % does NOT gate work — Claude blocks only on the two main
        // 5h / 7d windows, then credits (#177). Both main windows below 100 % → not blocked.
        let snapshot = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 30, resetsAt: iso(2 * 3600)),
            sevenDay: UsageWindow(utilization: 40, resetsAt: iso(4 * 24 * 3600)),
            sevenDayOpus: UsageWindow(utilization: 100, resetsAt: iso(4 * 24 * 3600)))
        #expect(!CreditsPacing.isBlocked(in: snapshot))
    }

    @Test func activeBothExhaustedButCreditsCoverNotBlocked() {
        let cover = SpendInfo(enabled: true, spendLimitReached: false)
        #expect(!CreditsPacing.isBlocked(in: active(fiveDayUtil: 100, sevenDayUtil: 100, spend: cover)))
    }
}

// MARK: - BlockingReset.select — the "last stand" (credits-priority) rule

@Suite("BlockingReset.select")
struct BlockingResetSelectTests {
    // Reset instants at increasing offsets so ordering is unambiguous. `t(n)` is n hours out.
    private let base = Date(timeIntervalSince1970: 2_000_000)
    private func t(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }
    private func tok(_ id: Int, _ hours: Double) -> BlockingReset.TokenCandidate {
        BlockingReset.TokenCandidate(id: id, resetsAt: t(hours))
    }

    // The six orderings from the ticket table (5 = id 0, 7 = id 1, e = credits).

    @Test func e_5_7_picksCredits() {                       // e < 5 < 7
        let choice = BlockingReset.select(tokenWindows: [tok(0, 5), tok(1, 7)], creditsReset: t(1))
        #expect(choice == .credits(resetsAt: t(1)))
    }

    @Test func e_7_5_picksCredits() {                       // e < 7 < 5
        let choice = BlockingReset.select(tokenWindows: [tok(0, 7), tok(1, 5)], creditsReset: t(1))
        #expect(choice == .credits(resetsAt: t(1)))
    }

    @Test func five_e_7_picksCredits() {                    // 5 < e < 7
        let choice = BlockingReset.select(tokenWindows: [tok(0, 2), tok(1, 8)], creditsReset: t(5))
        #expect(choice == .credits(resetsAt: t(5)))
    }

    @Test func seven_e_5_picksCredits() {                   // 7 < e < 5
        let choice = BlockingReset.select(tokenWindows: [tok(1, 2), tok(0, 8)], creditsReset: t(5))
        #expect(choice == .credits(resetsAt: t(5)))
    }

    @Test func five_seven_e_picksLaterToken() {             // 5 < 7 < e → max(5,7) = 7
        let choice = BlockingReset.select(tokenWindows: [tok(0, 2), tok(1, 5)], creditsReset: t(9))
        #expect(choice == .token(id: 1, resetsAt: t(5)))
    }

    @Test func seven_five_e_picksLaterToken() {             // 7 < 5 < e → max(5,7) = 5
        let choice = BlockingReset.select(tokenWindows: [tok(1, 2), tok(0, 5)], creditsReset: t(9))
        #expect(choice == .token(id: 0, resetsAt: t(5)))
    }

    // Edge cases.

    @Test func noCreditsPicksLatestToken() {
        let choice = BlockingReset.select(tokenWindows: [tok(0, 3), tok(1, 6)], creditsReset: nil)
        #expect(choice == .token(id: 1, resetsAt: t(6)))
    }

    @Test func onlyCreditsPicksCredits() {
        let choice = BlockingReset.select(tokenWindows: [], creditsReset: t(4))
        #expect(choice == .credits(resetsAt: t(4)))
    }

    @Test func nothingBlockingReturnsNil() {
        #expect(BlockingReset.select(tokenWindows: [], creditsReset: nil) == nil)
    }

    @Test func creditsTiedWithLatestTokenPrefersCredits() {
        // e == latest token → "<=" tie goes to credits (joint-soonest way back is still credits).
        let choice = BlockingReset.select(tokenWindows: [tok(0, 5)], creditsReset: t(5))
        #expect(choice == .credits(resetsAt: t(5)))
    }
}
