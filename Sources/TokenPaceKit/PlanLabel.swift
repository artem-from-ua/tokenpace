import Foundation

/// Turns the Keychain `rateLimitTier` string into a short human-readable plan label for the popup
/// header ("Claude ･ **Max (5x)**"). The value comes from the OAuth payload
/// (`TokenCredentials.rateLimitTier`, e.g. `"default_claude_max_5x"`) — not a secret, just a plan mark.
///
/// **Whitelist, not best-effort.** There is no published table of tier strings, and third-party clients
/// disagree even on the ones they've seen (`default_claude_ai` is labelled "Pro" by one project and
/// "Free" by another). Rather than title-case an unknown string and render a guess in brand colour —
/// which would read as a bug on the popup — we recognise **only** the shapes we're confident about and
/// return `nil` for everything else, so the header falls back to a plain "Claude" (and the view draws
/// no `･` separator). Recognised:
///
/// - `default_claude_max_<N>x` → `"Max (<N>x)"` (a pattern, so a future `max_50x` still resolves) —
///   Anthropic's own naming for these plans, with the multiplier parenthesised and its lowercase `x`.
/// - `default_claude_pro`      → `"Pro"`.
/// - anything else (`default`, `default_claude_ai`, unknown shapes, `nil`, empty) → `nil`.
///
/// `subscriptionType` (e.g. `"max"`) is intentionally **not** used: it is redundant with the tier —
/// the tier already carries the plan family *and* the multiplier.
public func claudePlanLabel(rateLimitTier: String?) -> String? {
    guard let tier = rateLimitTier, !tier.isEmpty else { return nil }
    if tier == "default_claude_pro" { return "Pro" }
    // `default_claude_max_<digits>x` → "Max (<digits>x)". Anchored, digits-only multiplier so we match
    // a real tier (5x, 20x, a future 50x) and not an arbitrary trailing token. The parenthesised
    // `(<digits>x)` with its lowercase `x` is how Anthropic writes these plan names.
    let prefix = "default_claude_max_"
    if tier.hasPrefix(prefix), tier.hasSuffix("x") {
        let digits = tier.dropFirst(prefix.count).dropLast()   // "default_claude_max_5x" → "5"
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
            return "Max (\(digits)x)"
        }
    }
    return nil
}
