import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - CompactMoney

/// A `Money` from a plain decimal amount, at the given currency's natural precision. `exponent: 2`
/// (cents) unless a whole-unit currency is under test.
private func money(_ amount: Double, _ currency: String = "USD", exponent: Int = 2) -> Money {
    Money(amountMinor: Int((amount * pow(10, Double(exponent))).rounded()),
          currency: currency,
          exponent: exponent)
}

@Suite("CompactMoney.text — the three-significant-digit ladder")
struct CompactMoneyLadderTests {

    /// The maintainer's own worked example, rung by rung: each magnitude keeps three digits, and the
    /// decimal point walks left until `K` restarts the ladder.
    @Test func ladderMatchesTheSpecifiedRungs() {
        #expect(CompactMoney.text(money(0.21)) == "$0.21")
        #expect(CompactMoney.text(money(1.21)) == "$1.21")
        #expect(CompactMoney.text(money(20.1)) == "$20.1")
        #expect(CompactMoney.text(money(120)) == "$120")
        #expect(CompactMoney.text(money(1_200)) == "$1.20K")
        #expect(CompactMoney.text(money(10_100)) == "$10.1K")
        #expect(CompactMoney.text(money(120_000)) == "$120K")
    }

    /// Digits past the third are dropped, not carried: the rung is chosen by magnitude alone.
    @Test func extraPrecisionIsTruncatedToTheRung() {
        #expect(CompactMoney.text(money(0.214)) == "$0.21")
        #expect(CompactMoney.text(money(1.214)) == "$1.21")
        #expect(CompactMoney.text(money(20.14)) == "$20.1")
        #expect(CompactMoney.text(money(120.4)) == "$120")
        #expect(CompactMoney.text(money(1_204)) == "$1.20K")
    }

    /// The real amounts from the popup that started this change.
    @Test func realCreditAmounts() {
        #expect(CompactMoney.text(money(15.02)) == "$15.0")
        #expect(CompactMoney.text(money(120.00)) == "$120")
        #expect(CompactMoney.text(money(10.77, "EUR")) == "€10.8")
    }
}

@Suite("CompactMoney.text — rounding boundaries")
struct CompactMoneyBoundaryTests {

    /// A value that rounds *up* into the next magnitude takes that magnitude's precision. Without this
    /// `999.7` would render `$1000` — four digits, the one width the ladder exists to avoid.
    @Test func roundingUpIntoThousandsUsesTheKRung() {
        #expect(CompactMoney.text(money(999.7)) == "$1.00K")
    }

    /// The same rule one rung down: `9.999` rounds to 10, so it renders at the 10–99 precision (`10.0`),
    /// not the sub-10 one (`10.00`).
    @Test func roundingUpAcrossTheTensBoundaryDropsADigit() {
        #expect(CompactMoney.text(money(9.999)) == "$10.0")
        #expect(CompactMoney.text(money(99.96)) == "$100")
    }

    /// Just below each boundary the finer precision still applies.
    @Test func justBelowABoundaryKeepsTheFinerRung() {
        #expect(CompactMoney.text(money(9.99)) == "$9.99")
        #expect(CompactMoney.text(money(99.9)) == "$99.9")
        #expect(CompactMoney.text(money(999.4)) == "$999")
    }
}

@Suite("CompactMoney.text — currencies")
struct CompactMoneyCurrencyTests {

    /// A whole-unit currency (JPY, `exponent: 0`) grows no fake cents at natural scale…
    @Test func wholeUnitCurrencyKeepsNoFractionAtNaturalScale() {
        #expect(CompactMoney.text(money(214, "JPY", exponent: 0)) == "¥214")
    }

    /// …but past the `K` divide the decimals are *thousands*, not sub-unit precision the currency
    /// lacks — so they are shown. `¥1204` is `¥1.20K`, never `¥1K`.
    @Test func wholeUnitCurrencyShowsThousandsDecimals() {
        #expect(CompactMoney.text(money(1_204, "JPY", exponent: 0)) == "¥1.20K")
        #expect(CompactMoney.text(money(20_140, "JPY", exponent: 0)) == "¥20.1K")
    }

    /// An unknown currency has no symbol to trust, so the amount is followed by the ISO code — and the
    /// `K` stays attached to the number, ahead of the code.
    @Test func unknownCurrencyFallsBackToIsoCode() {
        #expect(CompactMoney.text(money(20.14, "UAH")) == "20.1 UAH")
        #expect(CompactMoney.text(money(1_204, "UAH")) == "1.20K UAH")
    }

    /// The symbol keeps ICU's per-currency placement; the suffix is appended after formatting, so it
    /// never lands between the symbol and the digits.
    @Test func suffixSitsAfterTheFormattedAmount() {
        #expect(CompactMoney.text(money(1_204, "EUR")) == "€1.20K")
        #expect(CompactMoney.text(money(1_204, "GBP")) == "£1.20K")
    }

    /// A missing currency code renders the bare amount — no symbol, no trailing space.
    @Test func emptyCurrencyRendersBareAmount() {
        #expect(CompactMoney.text(money(20.14, "")) == "20.1")
    }
}

@Suite("CompactMoney.capText — the cap drops a zero fraction")
struct CompactMoneyCapTests {

    /// A whole cap shows no decimals at all — the case that motivated the split. Every limit in the
    /// captured payloads is whole (€15, €11, €5), so this is the shape users actually see.
    @Test func wholeCapDropsTheFraction() {
        #expect(CompactMoney.capText(money(15)) == "$15")
        #expect(CompactMoney.capText(money(11)) == "$11")
        #expect(CompactMoney.capText(money(5)) == "$5")
        #expect(CompactMoney.capText(money(120)) == "$120")
    }

    /// The maintainer's stated range, end to end: every whole cap from 1 to 99 loses its cents.
    @Test func wholeCapsAcrossTheStatedRange() {
        #expect(CompactMoney.capText(money(1)) == "$1")
        #expect(CompactMoney.capText(money(50)) == "$50")
        #expect(CompactMoney.capText(money(99)) == "$99")
    }

    /// A cap that genuinely carries cents still shows them — nothing is hidden, only zeros dropped.
    @Test func capWithCentsKeepsThem() {
        #expect(CompactMoney.capText(money(15.50)) == "$15.5")
        #expect(CompactMoney.capText(money(9.99)) == "$9.99")
        #expect(CompactMoney.capText(money(0.21)) == "$0.21")
    }

    /// The test is on the **rendered** string, not the input: `14.999` renders `15.0` on the ladder, so
    /// as a cap it renders `$15` — the zeros that would have shown are the ones that vanish.
    @Test func capIsJudgedByWhatWouldRender() {
        #expect(CompactMoney.text(money(14.999)) == "$15.0")
        #expect(CompactMoney.capText(money(14.999)) == "$15")
    }

    /// Past the K divide the same rule applies to the scaled amount: `$1000` is whole once scaled.
    @Test func wholeCapPastTheThousandDivide() {
        #expect(CompactMoney.capText(money(1_000)) == "$1K")
        #expect(CompactMoney.capText(money(1_200)) == "$1.20K")
        #expect(CompactMoney.capText(money(120_000)) == "$120K")
    }

    /// The spend formatter keeps the ladder even when whole — the cap rule is *not* mirrored onto it.
    /// A spend of exactly 12 still reads `$12.0`; only an untouched zero is special.
    @Test func theSpendFormatterStillShowsZeros() {
        #expect(CompactMoney.text(money(15)) == "$15.0")
        #expect(CompactMoney.text(money(12)) == "$12.0")
        #expect(CompactMoney.text(money(5)) == "$5.00")
    }

    /// A whole-unit currency has no fraction to drop; the cap form matches the plain one.
    @Test func wholeUnitCurrencyIsUnchanged() {
        #expect(CompactMoney.capText(money(214, "JPY", exponent: 0)) == "¥214")
        #expect(CompactMoney.capText(money(1_204, "JPY", exponent: 0)) == "¥1.20K")
    }

    /// An unknown currency drops the zeros too, code still trailing.
    @Test func unknownCurrencyCapDropsTheFraction() {
        #expect(CompactMoney.capText(money(15, "UAH")) == "15 UAH")
    }
}

@Suite("CompactMoney.text — zero and negatives")
struct CompactMoneyEdgeCaseTests {

    /// Nothing spent yet reads as a bare `$0` — at exactly zero the cents are padding, not precision.
    @Test func untouchedZeroShowsNoCents() {
        #expect(CompactMoney.text(money(0)) == "$0")
        #expect(CompactMoney.text(money(0, "EUR")) == "€0")
        #expect(CompactMoney.capText(money(0)) == "$0")
    }

    /// A real but tiny spend is never shown as `$0`: money has moved, and the line must not claim
    /// otherwise. The zero case is keyed to the **integer** minor units, not to what rounding produces.
    @Test func aTinySpendIsNotTreatedAsZero() {
        #expect(CompactMoney.text(Money(amountMinor: 1, currency: "USD", exponent: 2)) == "$0.01")
        #expect(CompactMoney.text(Money(amountMinor: 4, currency: "USD", exponent: 3)) != "$0")
    }

    /// A spend below the smallest unit the line shows reads `<$0.01` — not `$0.00` (which would claim
    /// nothing was spent) and not a rounded-up `$0.01` (which would overstate it 25×).
    @Test func subCentSpendReadsAsBelowTheSmallestUnit() {
        #expect(CompactMoney.text(Money(amountMinor: 4, currency: "USD", exponent: 3)) == "<$0.01")
        #expect(CompactMoney.text(Money(amountMinor: 4, currency: "EUR", exponent: 4)) == "<€0.01")
    }

    /// Exactly one cent is representable, so it prints plainly — the threshold is *below*, not *at*.
    @Test func exactlyOneCentIsNotBelowTheThreshold() {
        #expect(CompactMoney.text(Money(amountMinor: 1, currency: "USD", exponent: 2)) == "$0.01")
        #expect(CompactMoney.text(Money(amountMinor: 10, currency: "USD", exponent: 3)) == "$0.01")
    }

    /// The threshold is the smallest unit *this line* shows, not a hard-coded cent. A whole-unit
    /// currency (`exponent: 0`) can express nothing below `¥1`, so any non-zero amount is already at or
    /// above the threshold and prints plainly — the guard never fires.
    @Test func wholeUnitCurrencyHasNothingBelowItsThreshold() {
        #expect(CompactMoney.text(Money(amountMinor: 1, currency: "JPY", exponent: 0)) == "¥1")
        #expect(CompactMoney.text(Money(amountMinor: 214, currency: "JPY", exponent: 0)) == "¥214")
    }

    /// An `exponent` finer than the currency's convention means those digits *are* representable, so
    /// they print rather than tripping the threshold: `¥0.4` is an honest rendering, not a sub-unit one.
    @Test func aFinerExponentPrintsItsDigits() {
        #expect(CompactMoney.text(Money(amountMinor: 4, currency: "JPY", exponent: 1)) == "¥0.4")
    }

    /// An unknown currency keeps the ISO-code fallback under the threshold too.
    @Test func unknownCurrencyBelowThreshold() {
        #expect(CompactMoney.text(Money(amountMinor: 4, currency: "UAH", exponent: 3)) == "<0.01 UAH")
    }

    /// Zero is still zero — the threshold applies only to amounts that are genuinely non-zero.
    @Test func zeroDoesNotUseTheThreshold() {
        #expect(CompactMoney.text(Money(amountMinor: 0, currency: "USD", exponent: 3)) == "$0")
    }

    /// A negative amount (a refund/credit adjustment) picks its rung by magnitude, sign intact.
    @Test func negativeAmountsPickTheRungByMagnitude() {
        #expect(CompactMoney.text(money(-20.14)) == "-$20.1")
        #expect(CompactMoney.text(money(-1_204)) == "-$1.20K")
    }
}
