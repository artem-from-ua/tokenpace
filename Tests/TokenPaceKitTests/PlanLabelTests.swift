import Testing
@testable import TokenPaceKit

@Suite("claudePlanLabel")
struct PlanLabelTests {
    @Test func maps5xTier() {
        #expect(claudePlanLabel(rateLimitTier: "default_claude_max_5x") == "Max 5x")
    }

    @Test func maps20xTier() {
        #expect(claudePlanLabel(rateLimitTier: "default_claude_max_20x") == "Max 20x")
    }

    /// The multiplier is a pattern, not a fixed list — a future tier resolves without a code change.
    @Test func mapsFutureMultiplierTier() {
        #expect(claudePlanLabel(rateLimitTier: "default_claude_max_50x") == "Max 50x")
    }

    @Test func mapsProTier() {
        #expect(claudePlanLabel(rateLimitTier: "default_claude_pro") == "Pro")
    }

    /// The multiplier token keeps its original lowercase `x` (not "5X").
    @Test func preservesLowercaseMultiplier() {
        #expect(claudePlanLabel(rateLimitTier: "default_claude_max_5x")?.hasSuffix("5x") == true)
    }

    /// Whitelist, not best-effort: anything we don't confidently recognise yields `nil` so the header
    /// falls back to a plain "Claude" (no separator, no brand-coloured guess). Covers: absent/empty,
    /// a bare `default`, the ambiguous `default_claude_ai` (Pro vs Free across clients), a non-numeric
    /// multiplier, and any unknown shape.
    @Test(arguments: [
        nil, "",
        "default",
        "default_claude_ai",
        "default_claude_max_x",       // no digits
        "default_claude_max_fastx",   // non-numeric multiplier
        "default_claude_team_plus",
        "some_new_tier",
        "enterprise_cbp_usage_based",
    ])
    func unrecognisedYieldsNil(_ tier: String?) {
        #expect(claudePlanLabel(rateLimitTier: tier) == nil)
    }
}
