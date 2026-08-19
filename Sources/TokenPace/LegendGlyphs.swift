import AppKit

// MARK: - WidgetGlyph (#261)

/// The SF Symbol names the widget draws, in one place.
///
/// Until this type they were string literals at each draw site — five of them across `StatusItemView`
/// alone, plus the popup's own copies. That was harmless while the only reader was the code doing the
/// drawing: a renamed symbol broke one call and showed up immediately.
///
/// The **Legend** pane (#261) changes that. It is a second reader that must show exactly what the
/// widget shows, and a literal repeated there would let the page keep advertising a glyph the widget
/// had stopped using — with nothing to catch it, because both sides would still compile and both
/// would still draw *something*. That is the same class of drift ADR-0097 was written about when it
/// replaced screenshot previews with live renders; a shared name is the cheapest fix for the part of
/// it a render cannot reach.
///
/// Not an `enum` of cases: the values are consumed by AppKit as strings, and a case-per-glyph would
/// add a `rawValue` at every call site for no checking a constant does not already give.
enum WidgetGlyph {

    /// Sessions waiting for the user's answer (#233). Tinted by urgency at the draw site.
    static let awaitingInput = "hand.raised"

    /// Every limit spent with no credits to cover — work is blocked until a reset.
    static let paused = "pause.fill"

    /// **The data contradicts itself** — a window is provably exhausted while its reset instant is
    /// missing or unparseable (ADR-0091). Deliberately *not* used for "we cannot reach the API",
    /// which is what ``noData`` says.
    static let dataConflict = "exclamationmark.triangle"

    /// Usage monitoring switched off by the user, with services still watched (#341).
    static let usageTrackingOff = "zzz"

    /// Nothing to show: the usage API is unreachable, or no usage has been recorded yet.
    ///
    /// Resolved through `StatusItemView.noDataSymbolName` rather than restated, because that property
    /// carries a fallback for a future OS dropping the symbol — duplicating the preferred name here
    /// would leave the Legend showing it after the widget had fallen back to something else.
    @MainActor
    static var noData: String { StatusItemView.noDataSymbolName }

    /// The currency mark shown while paid credits are being spent — `eurosign`, `dollarsign`, and so
    /// on, chosen from the account's currency.
    ///
    /// Delegated to the widget's own mapping, which is already `static` and already handles the
    /// unknown-currency fallback.
    @MainActor
    static func credits(for currency: String) -> String {
        StatusItemView.creditsSymbolName(for: currency)
    }
}
