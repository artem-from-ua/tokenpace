import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Live-body fixtures (spike #142, captured 2026-07-26)
//
// Verbatim `GET /api/oauth/usage` bodies for the credits states the spike observed live. These are
// the same shapes pinned by the tolerance tests in `UsageClientTests.swift`; here they exercise the
// **modeled** `SpendInfo` (#143). Kept in one place so the decode and pacing suites share them.

private let now = Date(timeIntervalSince1970: 1_000_000)

/// Out of paid credits: `enabled: false`, `spend_limit_reached: false`, `limit: null`, EUR.
private let bodyOutOfCredits = #"""
{"five_hour":{"utilization":6.0,"resets_at":"2026-07-26T04:10:00.157569+00:00"},"seven_day":{"utilization":65.0,"resets_at":"2026-07-28T07:00:00.157592+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":1077.0,"utilization":null,"currency":"EUR","decimal_places":2,"disabled_reason":"out_of_credits","user_disabled":false,"spend_limit_reached":false,"credits_ever_enabled":true,"daily":null,"weekly":null},"limits":[{"kind":"session","group":"session","percent":6,"severity":"normal","resets_at":"2026-07-26T04:10:00.157569+00:00","scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":65,"severity":"normal","resets_at":"2026-07-28T07:00:00.157592+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":36,"severity":"normal","resets_at":"2026-07-28T07:00:00.157890+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],"spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},"limit":null,"percent":0,"severity":"normal","enabled":false,"disabled_reason":"out_of_credits","cap":null,"balance":null,"auto_reload":null,"can_purchase_credits":false,"can_toggle":false},"member_dashboard_available":false}
"""#

/// Credits enabled, monthly limit €15.00, spent €10.77 (72 %) — healthy "within limit".
private let bodyEnabledWithinLimit = #"""
{"five_hour":{"utilization":16.0,"resets_at":"2026-07-26T04:09:59.746567+00:00"},"seven_day":{"utilization":66.0,"resets_at":"2026-07-28T06:59:59.746589+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":true,"monthly_limit":1500,"used_credits":1077.0,"utilization":71.8,"currency":"EUR","decimal_places":2,"disabled_reason":null,"user_disabled":false,"spend_limit_reached":false,"credits_ever_enabled":true,"daily":null,"weekly":null},"limits":[{"kind":"session","group":"session","percent":16,"severity":"normal","resets_at":"2026-07-26T04:09:59.746567+00:00","scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":66,"severity":"normal","resets_at":"2026-07-28T06:59:59.746589+00:00","scope":null,"is_active":true}],"spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},"limit":{"amount_minor":1500,"currency":"EUR","exponent":2},"percent":72,"severity":"normal","enabled":true,"disabled_reason":null,"cap":{"money":{"amount_minor":1500,"currency":"EUR","exponent":2},"credits":null},"balance":null,"auto_reload":null,"can_purchase_credits":false,"can_toggle":false},"member_dashboard_available":false}
"""#

/// Monthly limit €5.00 set BELOW the €10.77 spent — the "limit exceeded" shape: server caps
/// `percent`/`utilization` at 100, flips `enabled` to false, sets `spend_limit_reached: true`.
/// Also drives a base-limit-exhausted trigger: `seven_day` here is at 100 %.
private let bodyLimitBelowSpent = #"""
{"five_hour":{"utilization":22.0,"resets_at":"2026-07-26T04:10:00.940049+00:00"},"seven_day":{"utilization":100.0,"resets_at":"2026-07-28T07:00:00.940073+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":false,"monthly_limit":500,"used_credits":1077.0,"utilization":100.0,"currency":"EUR","decimal_places":2,"disabled_reason":"org_level_disabled_until","user_disabled":false,"spend_limit_reached":true,"credits_ever_enabled":true,"daily":null,"weekly":null},"limits":[{"kind":"weekly_all","group":"weekly","percent":100,"severity":"critical","resets_at":"2026-07-28T07:00:00.940073+00:00","scope":null,"is_active":true}],"spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},"limit":{"amount_minor":500,"currency":"EUR","exponent":2},"percent":100,"severity":"critical","enabled":false,"disabled_reason":"org_level_disabled_until","cap":{"money":{"amount_minor":500,"currency":"EUR","exponent":2},"credits":null},"balance":null,"auto_reload":null,"can_purchase_credits":false,"can_toggle":false},"member_dashboard_available":false}
"""#

/// Monthly limit set to "unlimited" while enabled: `spend.limit`/`cap`/`monthly_limit`/`utilization`
/// all null, `percent` 0.
private let bodyUnlimited = #"""
{"five_hour":{"utilization":22.0,"resets_at":"2026-07-26T04:09:59.671333+00:00"},"seven_day":{"utilization":67.0,"resets_at":"2026-07-28T06:59:59.671352+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":1077.0,"utilization":null,"currency":"EUR","decimal_places":2,"disabled_reason":null,"user_disabled":false,"spend_limit_reached":false,"credits_ever_enabled":true,"daily":null,"weekly":null},"limits":[{"kind":"weekly_all","group":"weekly","percent":67,"severity":"normal","resets_at":"2026-07-28T06:59:59.671352+00:00","scope":null,"is_active":true}],"spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},"limit":null,"percent":0,"severity":"normal","enabled":true,"disabled_reason":null,"cap":null,"balance":null,"auto_reload":null,"can_purchase_credits":false,"can_toggle":false},"member_dashboard_available":false}
"""#

private func decodeSpend(_ body: String) throws -> SpendInfo {
    let snapshot = try UsageClient.decode(from: Data(body.utf8), now: now)
    return try #require(snapshot.spend, "expected a modeled `spend` on a credits body")
}

// MARK: - SpendInfo decode

@Suite("SpendInfo.decode")
struct SpendInfoDecodeTests {

    /// A pre-credits body (neither `spend` nor `extra_usage` block) → `spend == nil`, so the legacy
    /// fixtures that predate #143 are unaffected.
    @Test func absentBlocksDecodeToNilSpend() throws {
        let body = #"{"five_hour":{"utilization":13.0,"resets_at":"2026-06-21T05:30:00.619428+00:00"},"seven_day":{"utilization":40.0,"resets_at":"2026-06-28T00:00:00.000000+00:00"},"limits":[]}"#
        let snapshot = try UsageClient.decode(from: Data(body.utf8), now: now)
        #expect(snapshot.spend == nil)
    }

    /// State 1 — out of credits. `enabled: false`, `spend_limit_reached: false`, `limit: null`, EUR
    /// money object decoded exactly (1077 minor == €10.77).
    @Test func outOfCredits() throws {
        let spend = try decodeSpend(bodyOutOfCredits)
        #expect(spend.enabled == false)
        #expect(spend.spendLimitReached == false)
        #expect(spend.limit == nil)
        #expect(spend.used == Money(amountMinor: 1077, currency: "EUR", exponent: 2))
        #expect(spend.used?.majorUnitValue == 10.77)
        #expect(spend.usedCredits == 1077.0)
        #expect(spend.currency == "EUR")
        #expect(spend.decimalPlaces == 2)
    }

    /// State 2 — enabled within a €15.00 limit. Both `used` and `limit` are money objects; the
    /// currency travels with them (EUR, not USD).
    @Test func enabledWithinLimit() throws {
        let spend = try decodeSpend(bodyEnabledWithinLimit)
        #expect(spend.enabled == true)
        #expect(spend.spendLimitReached == false)
        #expect(spend.used == Money(amountMinor: 1077, currency: "EUR", exponent: 2))
        #expect(spend.limit == Money(amountMinor: 1500, currency: "EUR", exponent: 2))
        #expect(spend.limit?.majorUnitValue == 15.0)
    }

    /// State 3 — money limit €5.00 set below the €10.77 spent. `enabled` flips to false while
    /// `spend_limit_reached` is true (the over-limit shape). `limit < used` is preserved exactly.
    @Test func limitBelowSpent() throws {
        let spend = try decodeSpend(bodyLimitBelowSpent)
        #expect(spend.enabled == false)
        #expect(spend.spendLimitReached == true)
        #expect(spend.used == Money(amountMinor: 1077, currency: "EUR", exponent: 2))
        #expect(spend.limit == Money(amountMinor: 500, currency: "EUR", exponent: 2))
    }

    /// State 4 (near-cap, €11.00, ~98 %) — the spike captured this privately; synthesized here from
    /// the same shape so the decode path for a "warning zone" limit is covered.
    @Test func enabledNearCap() throws {
        let body = #"""
        {"five_hour":{"utilization":16.0,"resets_at":"2026-07-26T04:09:59.746567+00:00"},"seven_day":{"utilization":66.0,"resets_at":"2026-07-28T06:59:59.746589+00:00"},"extra_usage":{"is_enabled":true,"monthly_limit":1100,"used_credits":1077.0,"utilization":97.9,"currency":"EUR","decimal_places":2,"spend_limit_reached":false},"limits":[],"spend":{"used":{"amount_minor":1077,"currency":"EUR","exponent":2},"limit":{"amount_minor":1100,"currency":"EUR","exponent":2},"percent":98,"severity":"normal","enabled":true}}
        """#
        let spend = try decodeSpend(body)
        #expect(spend.enabled == true)
        #expect(spend.limit == Money(amountMinor: 1100, currency: "EUR", exponent: 2))
        #expect(spend.used?.amountMinor == 1077)
    }

    /// State 5 — unlimited. `limit: null` while enabled; `used`/`currency` still present.
    @Test func unlimited() throws {
        let spend = try decodeSpend(bodyUnlimited)
        #expect(spend.enabled == true)
        #expect(spend.spendLimitReached == false)
        #expect(spend.limit == nil)
        #expect(spend.used == Money(amountMinor: 1077, currency: "EUR", exponent: 2))
    }

    /// A present-but-empty `spend` block (and no `extra_usage`) still yields a value (all defaults),
    /// not `nil` — the block's *presence* is the signal, not its contents.
    @Test func presentEmptySpendBlockYieldsDefaults() throws {
        let body = #"{"five_hour":{"utilization":1.0,"resets_at":"2026-07-26T04:10:00.000000+00:00"},"seven_day":{"utilization":1.0,"resets_at":"2026-07-28T07:00:00.000000+00:00"},"spend":{}}"#
        let spend = try decodeSpend(body)
        #expect(spend.enabled == false)
        #expect(spend.used == nil)
        #expect(spend.limit == nil)
    }

    /// A malformed money object (wrong types) degrades to zeros rather than failing the snapshot —
    /// the tolerant-decode contract shared with `UsageWindow`/`UsageLimit`.
    @Test func malformedMoneyDegradesToZeros() throws {
        let body = #"{"five_hour":{"utilization":1.0,"resets_at":"2026-07-26T04:10:00.000000+00:00"},"seven_day":{"utilization":1.0,"resets_at":"2026-07-28T07:00:00.000000+00:00"},"spend":{"used":{"amount_minor":null,"currency":null,"exponent":null},"enabled":true}}"#
        let spend = try decodeSpend(body)
        #expect(spend.used == Money(amountMinor: 0, currency: "", exponent: 0))
        #expect(spend.enabled == true)
    }
}

// MARK: - CreditsPacing.isActive / shouldShowIcon

@Suite("CreditsPacing.trigger")
struct CreditsPacingTriggerTests {

    @Test func enabledIsActive() {
        #expect(CreditsPacing.isActive(SpendInfo(enabled: true, spendLimitReached: false)))
    }

    @Test func limitReachedIsActiveEvenWhenDisabled() {
        // The load-bearing OR: server sends enabled:false + spend_limit_reached:true at the cap.
        #expect(CreditsPacing.isActive(SpendInfo(enabled: false, spendLimitReached: true)))
    }

    @Test func neitherEnabledNorReachedIsInactive() {
        // Out-of-credits: enabled false, not reached → icon must not show.
        #expect(!CreditsPacing.isActive(SpendInfo(enabled: false, spendLimitReached: false)))
    }

    @Test func showRequiresBothActiveAndBaseLimitExhausted() {
        let active = SpendInfo(enabled: true)
        #expect(CreditsPacing.shouldShowIcon(active, baseLimitExhausted: true))
        #expect(!CreditsPacing.shouldShowIcon(active, baseLimitExhausted: false))
        let inactive = SpendInfo(enabled: false, spendLimitReached: false)
        #expect(!CreditsPacing.shouldShowIcon(inactive, baseLimitExhausted: true))
    }

    @Test func liveOutOfCreditsIsInactive() throws {
        let spend = try decodeSpend(bodyOutOfCredits)
        #expect(!CreditsPacing.isActive(spend))
    }

    @Test func liveLimitBelowSpentIsActiveViaReached() throws {
        let spend = try decodeSpend(bodyLimitBelowSpent)
        #expect(CreditsPacing.isActive(spend))   // enabled:false but spend_limit_reached:true
    }

    // MARK: anyBaseLimitExhausted

    @Test func baseLimitExhaustedWhenSevenDayAt100() throws {
        let snapshot = try UsageClient.decode(from: Data(bodyLimitBelowSpent.utf8), now: now)
        #expect(CreditsPacing.anyBaseLimitExhausted(in: snapshot))   // seven_day == 100
    }

    @Test func baseLimitNotExhaustedWhenAllBelow100() throws {
        let snapshot = try UsageClient.decode(from: Data(bodyEnabledWithinLimit.utf8), now: now)
        #expect(!CreditsPacing.anyBaseLimitExhausted(in: snapshot))   // 16 / 66, no scoped >= 100
    }

    @Test func liveShowIconEndToEndAtCap() throws {
        // Full path: over-limit body → active (via reached) AND a base limit exhausted → show.
        let snapshot = try UsageClient.decode(from: Data(bodyLimitBelowSpent.utf8), now: now)
        let spend = try #require(snapshot.spend)
        #expect(CreditsPacing.shouldShowIcon(
            spend, baseLimitExhausted: CreditsPacing.anyBaseLimitExhausted(in: snapshot)))
    }
}

// MARK: - CreditsPacing.spentFraction

@Suite("CreditsPacing.spentFraction")
struct CreditsPacingFractionTests {

    @Test func noLimitHasNoFraction() throws {
        // Unlimited: nothing to pace against → nil (amount-only UI, no bar/colour).
        #expect(CreditsPacing.spentFraction(of: try decodeSpend(bodyUnlimited)) == nil)
    }

    @Test func outOfCreditsNoLimitHasNoFraction() throws {
        // limit:null even though disabled → no fraction.
        #expect(CreditsPacing.spentFraction(of: try decodeSpend(bodyOutOfCredits)) == nil)
    }

    @Test func withinLimit() throws {
        // €10.77 / €15.00 = 71.8 %.
        let fraction = try #require(CreditsPacing.spentFraction(of: try decodeSpend(bodyEnabledWithinLimit)))
        #expect(abs(fraction - 0.718) < 0.001)
    }

    @Test func overLimitIsUnclamped() throws {
        // €10.77 / €5.00 = 2.154 — over-limit fraction is meaningful, not clamped here.
        let fraction = try #require(CreditsPacing.spentFraction(of: try decodeSpend(bodyLimitBelowSpent)))
        #expect(fraction > 1)
    }

    @Test func usesUsedCreditsFallbackWhenMoneyUsedAbsent() {
        // No `spend.used` money object → numerator falls back to extra_usage.used_credits (minor).
        let spend = SpendInfo(
            used: nil,
            limit: Money(amountMinor: 1000, currency: "EUR", exponent: 2),
            enabled: true,
            usedCredits: 900.0)
        #expect(CreditsPacing.spentFraction(of: spend) == 0.9)
    }

    @Test func zeroLimitHasNoFraction() {
        // A zero-minor limit is not a usable cap → nil (avoids divide-by-zero).
        let spend = SpendInfo(
            used: Money(amountMinor: 100, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 0, currency: "EUR", exponent: 2),
            enabled: true)
        #expect(CreditsPacing.spentFraction(of: spend) == nil)
    }
}

// MARK: - CreditsPacing.monthElapsedFraction

@Suite("CreditsPacing.monthElapsedFraction")
struct CreditsMonthFractionTests {

    private static let utc = TimeZone(identifier: "UTC")!

    /// Build a UTC instant from components — deterministic, no environment clock.
    private func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func startOfMonthIsZero() {
        // 1st at 00:00 UTC → nothing elapsed.
        let f = CreditsPacing.monthElapsedFraction(now: utcDate(2026, 7, 1), timeZone: Self.utc)
        #expect(f == 0)
    }

    @Test func midMonthIsAboutHalf() {
        // 16th of a 31-day month at 00:00 → 15/31 ≈ 0.484.
        let f = CreditsPacing.monthElapsedFraction(now: utcDate(2026, 7, 16), timeZone: Self.utc)
        #expect(abs(f - 15.0 / 31.0) < 0.001)
    }

    @Test func lastInstantIsNearOne() {
        // 31st 23:59 → almost the whole month elapsed.
        let f = CreditsPacing.monthElapsedFraction(now: utcDate(2026, 7, 31, 23, 59), timeZone: Self.utc)
        #expect(f > 0.99 && f <= 1)
    }

    @Test func februaryLengthHandled() {
        // 15th of Feb 2026 (28 days) → 14/28 = 0.5 exactly. Month length comes from Foundation.
        let f = CreditsPacing.monthElapsedFraction(now: utcDate(2026, 2, 15), timeZone: Self.utc)
        #expect(abs(f - 0.5) < 0.001)
    }

    @Test func timeZoneShiftsTheBoundary() {
        // At 2026-07-01T02:00 UTC it is still June 30 in a UTC-3 zone → that zone reports a
        // near-full (June) fraction, while UTC reports a near-zero (July) one. Proves the boundary
        // is time-zone dependent, which is why the zone is injected.
        let instant = utcDate(2026, 7, 1, 2, 0)
        let utcFraction = CreditsPacing.monthElapsedFraction(now: instant, timeZone: Self.utc)
        let westFraction = CreditsPacing.monthElapsedFraction(
            now: instant, timeZone: TimeZone(secondsFromGMT: -3 * 3600)!)
        #expect(utcFraction < 0.01)     // just into July (UTC)
        #expect(westFraction > 0.99)    // still end of June (UTC-3)
    }
}

// MARK: - CreditsPacing.barLayout (usage vs. time, same grading as the token bars)

@Suite("CreditsPacing.barLayout")
struct CreditsBarLayoutTests {

    private static let utc = TimeZone(identifier: "UTC")!

    private func utcDate(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        return cal.date(from: DateComponents(year: y, month: mo, day: d))!
    }

    @Test func noLimitProducesNoBar() throws {
        // Unlimited → no cap to pace against → nil (view shows amount only).
        let spend = try decodeSpend(bodyUnlimited)
        #expect(CreditsPacing.barLayout(for: spend, now: utcDate(2026, 7, 16), timeZone: Self.utc) == nil)
    }

    @Test func spentBelowTimePaceIsOnPaceOrBehind() {
        // 20 % spent, ~48 % of month elapsed (16th of 31) → usage <= time → green (on pace/behind).
        let spend = SpendInfo(
            used: Money(amountMinor: 200, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 1000, currency: "EUR", exponent: 2),
            enabled: true)
        let bar = CreditsPacing.barLayout(for: spend, now: utcDate(2026, 7, 16), timeZone: Self.utc)
        #expect(bar?.pacing == .onPaceOrBehind)
        #expect(abs((bar?.usageFraction ?? -1) - 0.2) < 0.001)
    }

    @Test func spentAheadOfTimePaceIsAhead() {
        // 80 % spent by the 16th (~48 % elapsed) → usage > time → ahead (yellow/orange, not red).
        let spend = SpendInfo(
            used: Money(amountMinor: 800, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 1000, currency: "EUR", exponent: 2),
            enabled: true)
        let bar = CreditsPacing.barLayout(for: spend, now: utcDate(2026, 7, 16), timeZone: Self.utc)
        #expect(bar?.pacing == .ahead)
    }

    @Test func spendLimitReachedForcesFullUsageBar() throws {
        // Over-limit / reached → usageFraction forced to 1 so the view's aheadColor renders it red
        // (usage >= 1), regardless of where in the month we are.
        let spend = try decodeSpend(bodyLimitBelowSpent)   // reached: true, used > limit
        let bar = CreditsPacing.barLayout(for: spend, now: utcDate(2026, 7, 2), timeZone: Self.utc)
        #expect(bar?.usageFraction == 1)
        #expect(bar?.pacing == .ahead)   // usage(1) > time(early month) → ahead; view paints red at usage>=1
    }

    @Test func usageIsClampedForRendering() {
        // Raw fraction 2.15 (used 1077 / limit 500) clamps to 1 in the bar even without the reached flag.
        let spend = SpendInfo(
            used: Money(amountMinor: 1077, currency: "EUR", exponent: 2),
            limit: Money(amountMinor: 500, currency: "EUR", exponent: 2),
            enabled: true,
            spendLimitReached: false)
        let bar = CreditsPacing.barLayout(for: spend, now: utcDate(2026, 7, 16), timeZone: Self.utc)
        #expect(bar?.usageFraction == 1)
    }
}
