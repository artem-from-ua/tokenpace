import Foundation

/// The credits line's **resting** money format: three significant digits, `K` past a thousand.
///
/// The popup shows two precisions of the same amount, gated on ⌥ exactly like `usedText`/`resetText`:
/// at rest `CompactMoney.text` keeps the line as narrow as the numbers themselves, and holding Option
/// swaps in the exact cents (`PopupViewController.moneyText`). The magnitude decides where the decimal
/// point falls, so the string keeps a near-constant width as the amount grows:
///
/// | amount   | renders   |
/// |----------|-----------|
/// | `0.214`  | `$0.21`   |
/// | `1.214`  | `$1.21`   |
/// | `20.14`  | `$20.1`   |
/// | `120.4`  | `$120`    |
/// | `1204`   | `$1.20K`  |
/// | `10140`  | `$10.1K`  |
/// | `120400` | `$120K`   |
///
/// Lives in the Kit — not on the AppKit view controller — so it is unit-testable, the same reason
/// ``ExtraUsageOnset/moneyText(_:)`` keeps its copy of the exact formatter here (that one is a
/// deliberate duplicate of the popup's; this one is the single source both surfaces call).
public enum CompactMoney {

    /// The three-significant-digit rendering of `money`, with the currency symbol in ICU's standard
    /// position for that currency and a `K` suffix past a thousand.
    ///
    /// The suffix is appended **after** formatting so the symbol keeps its placement — `$1.20K`, but
    /// `1,20K kr` for a trailing-symbol currency. An unknown currency falls back to the amount plus the
    /// ISO code (`1.20K UAH`), matching the exact formatter's own fallback.
    ///
    /// The amount always comes from the **integer** minor units + exponent, so no representation error
    /// creeps in before rounding.
    public static func text(_ money: Money) -> String {
        let value = Double(money.amountMinor) / pow(10, Double(money.exponent))
        // The K threshold is tested on the value **as it will round** (`999.7` reads as 1000 → `$1.00K`),
        // otherwise a just-under amount would render four digits — the one width this ladder avoids.
        let (scaled, suffix) = roundsToThousand(value) ? (value / 1_000, "K") : (value, "")
        // The source exponent caps the digits only at natural scale, where it means "this currency has
        // no smaller unit" (JPY → no cents). Past the K divide the suffix has already changed the scale,
        // so `¥1204` is `¥1.20K` — those decimals are thousands, not sub-unit precision the currency lacks.
        let significant = significantFractionDigits(scaled)
        let digits = suffix.isEmpty ? min(max(0, money.exponent), significant) : significant
        if isKnownCurrency(money.currency),
           let text = currencyFormatted(scaled, code: money.currency, digits: digits) {
            return "\(text)\(suffix)"
        }
        let amount = String(format: "%.\(digits)f", scaled)
        let code = money.currency.isEmpty ? "" : " \(money.currency.uppercased())"
        return "\(amount)\(suffix)\(code)"
    }

    /// Fraction digits that leave `value` with three significant digits: `< 10` → 2 (`1.21`), `< 100` →
    /// 1 (`20.1`), otherwise 0 (`120`). The magnitude is measured on the value **as it will be rounded**
    /// — `9.999` counts as 10, so it renders `10.0` rather than `10.00` — which keeps the digit count
    /// honest across every boundary.
    static func significantFractionDigits(_ value: Double) -> Int {
        let magnitude = abs(value)
        if magnitude < 9.995 { return 2 }
        if magnitude < 99.95 { return 1 }
        return 0
    }

    /// Whether `value` reaches 1_000 **once rounded to whole units** — the K-suffix test. A bare
    /// `>= 1_000` would let `999.7` through as `$1000` (four digits, the width this ladder exists to
    /// avoid); rounding first sends it to `$1.00K`, matching every other magnitude step.
    static func roundsToThousand(_ value: Double) -> Bool {
        abs(value).rounded() >= 1_000
    }

    /// Whether this ISO code gets a symbol vs. the bare code — mirrors
    /// ``ExtraUsageOnset/isKnownCurrency(_:)``, `PopupViewController.isKnownCurrency`, and
    /// `StatusItemView.creditsSymbolName(for:)`, so every surface agrees on which currencies get a symbol.
    static func isKnownCurrency(_ code: String) -> Bool {
        ["EUR", "USD", "GBP", "JPY", "CNY", "INR"].contains(code.uppercased())
    }

    /// `NumberFormatter` currency string with the symbol in its standard position and exactly `digits`
    /// fraction digits, or `nil` on failure (caller falls back to the code form). A fixed `en_US_POSIX`
    /// base locale keeps grouping/decimal marks deterministic while `currencyCode` drives the symbol.
    /// The leading-symbol NBSP is stripped so `€ 10.77` renders as `€10.77` (matching the popup).
    private static func currencyFormatted(_ value: Double, code: String, digits: Int) -> String? {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US_POSIX")
        f.currencyCode = code.uppercased()
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        guard let s = f.string(from: NSNumber(value: value)) else { return nil }
        return s.replacingOccurrences(
            of: "(?<=\\D)[\u{00A0}\u{202F}](?=\\d)", with: "", options: .regularExpression)
    }
}
