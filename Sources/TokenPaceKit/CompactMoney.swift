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
/// Two entry points, for the two halves of the credits line: ``text(_:)`` for the **spend** (a moving
/// value on the ladder, bar two cases — an untouched `$0` shows no cents, and a spend below the
/// smallest shown unit reads `<$0.01`) and ``capText(_:)`` for the **cap** (a constant, which drops a
/// zero fraction throughout — `€15`, not `€15.0`). The ladder is shared; only trailing zeros differ.
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
        // Nothing spent yet reads as `$0`, not `$0.00`: at exactly zero the cents are not precision but
        // padding, and the resting line is trying to be narrow. The test is on the **integer** minor
        // units, so "no money has moved" and "some money has moved" never look alike.
        guard money.amountMinor != 0 else { return text(money, dropsZeroFraction: true) }
        // A spend too small for the line's own precision reads `<$0.01` rather than `$0.00`, which would
        // claim nothing was spent. Rounding *up* to `$0.01` was the alternative and is worse: it
        // overstates the amount (25× at $0.0004) on a line whose whole job is reporting money.
        if let floor = belowSmallestShown(money) { return floor }
        return text(money, dropsZeroFraction: false)
    }

    /// `"<$0.01"` when `money` is a **non-zero** amount that the ladder would render as all zeros — or
    /// `nil` when it renders honestly on its own.
    ///
    /// The threshold is the smallest unit this line actually *shows*, not a hard-coded cent: at
    /// `exponent: 2` that is `0.01`, and for a whole-unit currency (JPY) it is `¥1`, so the string reads
    /// `<¥1`. Unreachable with today's payloads — every captured `Money` is `exponent: 2`, whose
    /// smallest non-zero value is exactly `$0.01` — and kept as a guard for a finer-grained schema,
    /// where the alternative is a line that reads `$0.00` while money is being spent.
    static func belowSmallestShown(_ money: Money) -> String? {
        let digits = min(max(0, money.exponent), 2)   // what the sub-1 rung of the ladder would print
        let smallest = pow(10, -Double(digits))       // 0.01 at 2 digits, 1 at 0 digits
        let value = Double(money.amountMinor) / pow(10, Double(money.exponent))
        guard abs(value) < smallest else { return nil }
        let rendered = isKnownCurrency(money.currency)
            ? currencyFormatted(smallest, code: money.currency, digits: digits)
            : nil
        guard let text = rendered else {
            let amount = String(format: "%.\(digits)f", smallest)
            let code = money.currency.isEmpty ? "" : " \(money.currency.uppercased())"
            return "<\(amount)\(code)"
        }
        return "<\(text)"
    }

    /// The compact rendering of a **cap** — the ladder above, but a whole amount drops its zero
    /// fraction entirely: `€15` rather than `€15.0`.
    ///
    /// This is the credits line's *right* half only. The two amounts are different kinds of number and
    /// the asymmetry is the point: the spend is a moving value whose precision carries information,
    /// while the cap is a constant the user typed into Anthropic's billing — every limit in the captured
    /// payloads is whole (€15, €11, €5), so its `.00` is noise on a line that is trying to be narrow.
    /// A cap that *does* carry cents still shows them (`€15.50` → `€15.5`), so nothing is hidden.
    ///
    /// The ⌥ form is unaffected: holding Option shows both amounts exact, cap cents included.
    public static func capText(_ money: Money) -> String {
        text(money, dropsZeroFraction: true)
    }

    /// Shared body of ``text(_:)`` and ``capText(_:)``. `dropsZeroFraction` decides only what happens to
    /// an amount whose fraction rounds to nothing — the ladder itself is identical either way, so the
    /// two halves of the credits line can never disagree about magnitude, only about trailing zeros.
    private static func text(_ money: Money, dropsZeroFraction: Bool) -> String {
        let value = Double(money.amountMinor) / pow(10, Double(money.exponent))
        // The K threshold is tested on the value **as it will round** (`999.7` reads as 1000 → `$1.00K`),
        // otherwise a just-under amount would render four digits — the one width this ladder avoids.
        let (scaled, suffix) = roundsToThousand(value) ? (value / 1_000, "K") : (value, "")
        // The source exponent caps the digits only at natural scale, where it means "this currency has
        // no smaller unit" (JPY → no cents). Past the K divide the suffix has already changed the scale,
        // so `¥1204` is `¥1.20K` — those decimals are thousands, not sub-unit precision the currency lacks.
        let significant = significantFractionDigits(scaled)
        var digits = suffix.isEmpty ? min(max(0, money.exponent), significant) : significant
        // A cap whose fraction rounds away shows none: `€15.0` → `€15`, `$1.20K` → `$1.2K` only when the
        // hundredth is what vanished. Tested on the value **as this many digits would round it**, so
        // `€14.999` (which renders `€15.0`) counts as whole too — the string decides, not the input.
        if dropsZeroFraction, roundsToWhole(scaled, digits: digits) { digits = 0 }
        if isKnownCurrency(money.currency),
           let text = currencyFormatted(scaled, code: money.currency, digits: digits) {
            return "\(text)\(suffix)"
        }
        let amount = String(format: "%.\(digits)f", scaled)
        let code = money.currency.isEmpty ? "" : " \(money.currency.uppercased())"
        return "\(amount)\(suffix)\(code)"
    }

    /// Whether `value`, rendered at `digits` fraction digits, would show nothing but zeros after the
    /// decimal point. Compares the value against its own whole-number rounding at that precision, so it
    /// answers "will the string end in `.0`/`.00`?" rather than "is the input mathematically whole" —
    /// the two differ for a value like `14.999`, which prints `15.0`.
    static func roundsToWhole(_ value: Double, digits: Int) -> Bool {
        guard digits > 0 else { return true }
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        return rounded == rounded.rounded()
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
