import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - ExtraUsageOnset

/// A workable base window (well under 100%).
private func lowWindow() -> UsageWindow { UsageWindow(utilization: 40, resetsAt: "") }
/// An exhausted base window (server caps utilization at 100).
private func fullWindow() -> UsageWindow { UsageWindow(utilization: 100, resetsAt: "") }

@Suite("ExtraUsageOnset.isOnCredits")
struct ExtraUsageOnsetSignalTests {

    @Test func noCreditsIsNotOnCredits() {
        // A pre-credits payload (spend == nil) is never on credits, even with an exhausted window.
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: nil)
        #expect(ExtraUsageOnset.isOnCredits(snap) == false)
    }

    @Test func baseNotExhaustedIsNotOnCredits() {
        // Credits enabled but no main window exhausted → nothing overflowing → not on credits.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: lowWindow(), spend: spend)
        #expect(ExtraUsageOnset.isOnCredits(snap) == false)
    }

    @Test func baseExhaustedAndSpendingIsOnCredits() {
        // 7d exhausted + credits enabled & not capped → actively spending on credits.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(ExtraUsageOnset.isOnCredits(snap) == true)
    }

    @Test func fiveHourExhaustedAndSpendingIsOnCredits() {
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(fiveHour: fullWindow(), sevenDay: lowWindow(), spend: spend)
        #expect(ExtraUsageOnset.isOnCredits(snap) == true)
    }

    @Test func cappedCreditsIsNotOnCredits() {
        // At the money cap the server sends enabled:false + spend_limit_reached:true → blocked, not
        // spending. That is the "Back to work!" domain, not this one.
        let spend = SpendInfo(enabled: false, spendLimitReached: true)
        let snap = UsageSnapshot(fiveHour: lowWindow(), sevenDay: fullWindow(), spend: spend)
        #expect(ExtraUsageOnset.isOnCredits(snap) == false)
    }

    @Test func perModelExhaustedDoesNotTrigger() {
        // A per-model sub-window (Opus) at 100% does NOT overflow into credits on its own (#177) — the
        // main windows are low, so no onset even with credits enabled.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let snap = UsageSnapshot(
            fiveHour: lowWindow(), sevenDay: lowWindow(), sevenDayOpus: fullWindow(), spend: spend)
        #expect(ExtraUsageOnset.isOnCredits(snap) == false)
    }

    @Test func idleFiveHourIsNotExhausted() {
        // sessionIdle: the 5h window carries utilization 0 → not exhausted → nothing overflowing.
        let spend = SpendInfo(enabled: true, spendLimitReached: false)
        let idle = UsageWindow(utilization: 0, resetsAt: "")
        let snap = UsageSnapshot(fiveHour: idle, sevenDay: lowWindow(), sessionIdle: true, spend: spend)
        #expect(ExtraUsageOnset.isOnCredits(snap) == false)
    }
}

@Suite("ExtraUsageOnset.bannerBody")
struct ExtraUsageOnsetBodyTests {

    @Test func limitSetShowsSpentOfLimit() {
        let spend = SpendInfo(
            used: Money(amountMinor: 240, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 5000, currency: "EUR", exponent: 2),
            enabled: true)
        #expect(ExtraUsageOnset.bannerBody(for: spend)
            == "You've hit a Claude usage limit — now spending paid credit: €2.40 of €50.00.")
    }

    @Test func unlimitedShowsSpentSoFar() {
        // limit == nil (monthly limit set to unlimited) → spent amount only, "so far".
        let spend = SpendInfo(
            used: Money(amountMinor: 1077, currency: "EUR", exponent: 2),
            limit: nil,
            enabled: true)
        #expect(ExtraUsageOnset.bannerBody(for: spend)
            == "You've hit a Claude usage limit — now spending paid credit: €10.77 so far.")
    }

    @Test func usdSymbolBeforeAmount() {
        let spend = SpendInfo(
            used: Money(amountMinor: 500, currency: "USD", exponent: 2),
            limit: Money(amountMinor: 2000, currency: "USD", exponent: 2),
            enabled: true)
        #expect(ExtraUsageOnset.bannerBody(for: spend)
            == "You've hit a Claude usage limit — now spending paid credit: $5.00 of $20.00.")
    }

    @Test func unknownCurrencyShowsIsoCode() {
        // A currency without a trusted symbol renders "amount CODE" (e.g. "12.00 UAH").
        let spend = SpendInfo(
            used: Money(amountMinor: 1200, currency: "UAH", exponent: 2),
            limit: Money(amountMinor: 5000, currency: "UAH", exponent: 2),
            enabled: true)
        #expect(ExtraUsageOnset.bannerBody(for: spend)
            == "You've hit a Claude usage limit — now spending paid credit: 12.00 UAH of 50.00 UAH.")
    }

    @Test func fallsBackToUsedCreditsWhenNoMoneyObject() {
        // No spend.used → reconstruct the spent amount from extra_usage.used_credits + currency/dp.
        let spend = SpendInfo(
            used: nil,
            limit: Money(amountMinor: 5000, currency: "EUR", exponent: 2),
            enabled: true,
            usedCredits: 240,
            currency: "EUR",
            decimalPlaces: 2)
        #expect(ExtraUsageOnset.bannerBody(for: spend)
            == "You've hit a Claude usage limit — now spending paid credit: €2.40 of €50.00.")
    }

    @Test func genericLineWhenNoAmountResolvable() {
        // Neither spend.used nor used_credits present → no bogus "0", just the generic line.
        let spend = SpendInfo(used: nil, limit: nil, enabled: true, usedCredits: nil)
        #expect(ExtraUsageOnset.bannerBody(for: spend)
            == "You've hit a Claude usage limit — now spending paid credit.")
    }
}
