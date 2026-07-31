import Foundation

// MARK: - ExtraUsageOnset

/// Whether Claude Code has **just switched to spending paid Extra Usage Credit**, and the banner text
/// that describes it — the pure signal + copy behind the "switched to Extra Usage Credit" notification.
///
/// This mirrors ``WorkAvailability`` (the "Back to work!" signal): the shell watches ``isOnCredits(_:)``
/// poll-to-poll and fires when it crosses `false → true` (see `AppDelegate.detectExtraUsageEdge`). The
/// impure post lives in `ExtraUsageNotifier` (`TokenPace`); this type owns only the decision and the
/// formatting, so it is fully unit-testable (ADR-0009).
///
/// ## The signal
/// "On credits" reuses the existing pacing predicate rather than inventing a new one — it is exactly
/// ``CreditsPacing/isSpending(_:baseLimitExhausted:)`` with the **blocking** notion of exhaustion
/// (``CreditsPacing/mainWindowExhausted(in:)``, the 5h/7d windows that actually gate work). So the
/// notification fires at the precise moment a plan limit is spent **and** paid credits start covering
/// new work:
/// ```
/// isOnCredits = spend != nil
///            && mainWindowExhausted(snapshot)
///            && isSpending(spend, baseLimitExhausted: true)   // enabled && !spend_limit_reached
/// ```
/// It does **not** conflict with the "Back to work!" edge: that fires on `blocked → workable`, whereas
/// this fires on `not-spending → spending-on-credits` (a state that is already "workable"), so the two
/// notifications describe different transitions and never collide.
///
/// ## The body copy
/// The maintainer's requirement: the banner body carries the **current amount spent** and the **limit**
/// (when the user set one). ``bannerBody(for:)`` formats both from the exact ``Money`` integers (never a
/// rounded `Double`) with the same currency-placement rules as the popup's "Extra usage" section, so the
/// banner and the dropdown read identically. Unlimited (`limit == nil`) → spent amount only.
public enum ExtraUsageOnset {

    /// `true` when paid Extra Usage Credit is **actively covering work right now**: a main window
    /// (5h / 7d) is exhausted **and** credits are enabled and not yet capped. This is the state whose
    /// `false → true` edge fires the notification.
    ///
    /// Reuses ``CreditsPacing/isSpending(_:baseLimitExhausted:)`` with
    /// ``CreditsPacing/mainWindowExhausted(in:)`` as the exhaustion source — the two blocking windows,
    /// not the per-model sub-windows (a scoped model at 100 % never overflows into credits on its own,
    /// #177), so no spurious onset from a Opus/Sonnet cap.
    ///
    /// A `nil` spend (pre-credits payload) is never "on credits". At the money cap the server sends
    /// `enabled: false` + `spend_limit_reached: true`, so `isSpending` is false there too — the user is
    /// then blocked, not spending, which is the "Back to work!" domain, not this one.
    public static func isOnCredits(_ snapshot: UsageSnapshot) -> Bool {
        guard let spend = snapshot.spend else { return false }
        return CreditsPacing.isSpending(
            spend, baseLimitExhausted: CreditsPacing.mainWindowExhausted(in: snapshot))
    }

    /// The banner **title** — fixed copy, no interpolation (the numbers live in the body).
    public static let bannerTitle = "Now using Extra Usage Credit"

    /// The banner **body**: the current spent amount, plus the limit when the user set one.
    ///
    /// - **Limit set**: `"You've hit a Claude usage limit — now spending paid credit: €2.40 of €50.00."`
    /// - **Unlimited** (`spend.limit == nil`): `"You've hit a Claude usage limit — now spending paid credit: €2.40 so far."`
    ///
    /// Amounts come from the exact ``Money`` integers (`amount_minor / 10^exponent`) via ``moneyText(_:)``.
    /// When `spend.used` is absent the spent amount falls back to the `extra_usage.used_credits` scalar
    /// (same value, kept as a cross-check) reconstructed into a ``Money`` with the block's currency /
    /// `decimal_places`. If **no** amount can be resolved at all, the body degrades to a generic line
    /// (never crashes, never shows a bogus "0").
    public static func bannerBody(for spend: SpendInfo) -> String {
        let prefix = "You've hit a Claude usage limit — now spending paid credit"
        guard let spent = resolvedSpent(spend) else {
            return "\(prefix)."
        }
        if let limit = spend.limit, limit.amountMinor > 0 {
            return "\(prefix): \(moneyText(spent)) of \(moneyText(limit))."
        }
        return "\(prefix): \(moneyText(spent)) so far."
    }

    /// The spent amount as an exact ``Money``: `spend.used` when present, otherwise the
    /// `extra_usage.used_credits` scalar rebuilt with the extra-usage block's currency + decimal places.
    /// `nil` only when neither is available (a partial payload with no amount at all).
    static func resolvedSpent(_ spend: SpendInfo) -> Money? {
        if let used = spend.used { return used }
        guard let credits = spend.usedCredits else { return nil }
        // `used_credits` is already in minor units (e.g. 240.0 == €2.40); rebuild the Money so the same
        // integer + exponent formatting path applies. Fall back to the limit's currency/exponent, then
        // to a plain 2-dp form, when the extra-usage block omits them.
        let currency = spend.currencyCode.isEmpty ? (spend.limit?.currency ?? "") : spend.currencyCode
        let exponent = spend.decimalPlaces ?? spend.limit?.exponent ?? 2
        return Money(amountMinor: Int(credits.rounded()), currency: currency, exponent: exponent)
    }

    /// Format a ``Money`` for the banner body, matching the popup's `PopupViewController.moneyText`:
    /// a known currency uses its symbol in the standard position (`$10.77`, `€10.77`, `10,77 kr`); an
    /// unknown currency shows the amount then the ISO code (`12.00 UAH`). The amount is built from the
    /// **integer** minor units + exponent so no representation error reaches the shown value.
    ///
    /// A duplicate of the popup formatter, deliberately: the popup version is a `static` on the AppKit
    /// view controller (executable target) and cannot be imported here, and the maintainer's rule is to
    /// keep pure copy in the Kit so it is testable. The two must stay in lock-step — a currency added to
    /// one's known-set belongs in the other (see ``isKnownCurrency(_:)``).
    static func moneyText(_ money: Money) -> String {
        let value = Double(money.amountMinor) / pow(10, Double(money.exponent))
        let digits = max(0, money.exponent)
        if isKnownCurrency(money.currency), let text = currencyFormatted(value, code: money.currency, digits: digits) {
            return text
        }
        let amount = String(format: "%.\(digits)f", value)
        let code = money.currency.isEmpty ? "" : " \(money.currency.uppercased())"
        return "\(amount)\(code)"
    }

    /// Whether this ISO code gets a symbol vs. the bare code — mirrors `PopupViewController.isKnownCurrency`
    /// and `StatusItemView.creditsSymbolName(for:)`, so the menu-bar glyph, the dropdown, and this banner
    /// all agree on which currencies render a symbol.
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
