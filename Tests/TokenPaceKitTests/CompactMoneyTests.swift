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

@Suite("CompactMoney.text — zero and negatives")
struct CompactMoneyEdgeCaseTests {

    /// Zero sits on the finest rung.
    @Test func zeroUsesTheFinestRung() {
        #expect(CompactMoney.text(money(0)) == "$0.00")
    }

    /// A negative amount (a refund/credit adjustment) picks its rung by magnitude, sign intact.
    @Test func negativeAmountsPickTheRungByMagnitude() {
        #expect(CompactMoney.text(money(-20.14)) == "-$20.1")
        #expect(CompactMoney.text(money(-1_204)) == "-$1.20K")
    }
}
