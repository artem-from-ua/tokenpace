import Testing
@testable import TokenPaceKit

// MARK: - TOKENPACE_STUB resolution (#267)

/// Covers the pure mapping rule behind `TOKENPACE_STUB`. The scenario registry itself
/// (`StubScenario`) lives in the app target — each case owns a transport and AppKit display metadata —
/// but the rule that decides *which* id runs is here, per the pure-core / thin-shell split (ADR-0009).
///
/// The bug being locked down: an unrecognized value used to resolve to the live network, so a run
/// meant to be stubbed polled production and read the real `~/.claude` trees while looking stubbed in
/// every visible respect.
@Suite("TOKENPACE_STUB resolution")
struct StubResolutionTests {

    // A miniature stand-in for the real registry — same shape, stable under registry edits.
    private let live = "real"
    private let fallback = "screenshot"
    private let known = ["real", "screenshot", "all-green", "1"]

    private func resolve(_ env: String?, isAppBundle: Bool = false) -> StubResolution.Outcome {
        StubResolution.resolve(
            env: env, isAppBundle: isAppBundle,
            liveID: live, fallbackID: fallback, knownIDs: known
        )
    }

    /// **The #267 regression guard.** A bogus id must land on the frozen frame, never on live — and it
    /// must report the bad value so the run can't be mistaken for what was asked for.
    @Test func unknownValueFallsBackToScreenshotNotLive() {
        let outcome = resolve("healthy")
        #expect(outcome.id == fallback)
        #expect(outcome.id != live)
        #expect(outcome.unknownValue == "healthy")
        #expect(outcome.isExplicit == false)
    }

    /// An empty `TOKENPACE_STUB=` is *present but bogus*: it names no scenario. Before #267 it was
    /// `realNetwork`'s own id, which is what made "absent" and "explicitly live" indistinguishable.
    @Test func emptyValueIsBogusNotLive() {
        let outcome = resolve("")
        #expect(outcome.id == fallback)
        #expect(outcome.unknownValue == "")
        #expect(outcome.isExplicit == false)
    }

    /// A dev build with no env gets the reproducible frozen frame — live is no longer the default you
    /// fall into. Not flagged as a bad value: nothing was requested, so there is nothing to warn about.
    @Test func devBuildWithoutEnvDefaultsToScreenshot() {
        let outcome = resolve(nil, isAppBundle: false)
        #expect(outcome.id == fallback)
        #expect(outcome.isExplicit == false)
        #expect(outcome.unknownValue == nil)
    }

    /// The one path that stays live by default: an installed `.app` with no env. A real user must see
    /// their own limits, not a canned frame. Counts as explicit — it is production's normal mode.
    @Test func appBundleWithoutEnvStaysLive() {
        let outcome = resolve(nil, isAppBundle: true)
        #expect(outcome.id == live)
        #expect(outcome.isExplicit == true)
        #expect(outcome.unknownValue == nil)
    }

    /// Live can still be requested by name, on either kind of build — and it is explicit, which is what
    /// lets the awaiting-input watcher come up on a dev build (the supported way to test the hand
    /// indicator against live sessions).
    @Test func liveCanBeRequestedExplicitly() {
        for isAppBundle in [true, false] {
            let outcome = resolve("real", isAppBundle: isAppBundle)
            #expect(outcome.id == live)
            #expect(outcome.isExplicit == true)
            #expect(outcome.unknownValue == nil)
        }
    }

    /// An ordinary stub id resolves to itself and is explicit.
    @Test func knownStubResolvesToItself() {
        let outcome = resolve("all-green")
        #expect(outcome.id == "all-green")
        #expect(outcome.isExplicit == true)
        #expect(outcome.unknownValue == nil)
    }

    /// Every recognized id round-trips to itself — the property that makes the registry usable as env
    /// ids at all.
    @Test func everyKnownIDRoundTrips() {
        for id in known {
            #expect(resolve(id).id == id)
            #expect(resolve(id).isExplicit == true)
        }
    }

    /// Resolution is only unambiguous while no id is empty and none repeat. An empty id makes "absent
    /// env" and "this id" the same string — exactly the shape that caused #267.
    @Test func idsAreResolvableRejectsEmptyAndDuplicates() {
        #expect(StubResolution.idsAreResolvable(known) == true)
        #expect(StubResolution.idsAreResolvable(["real", ""]) == false)
        #expect(StubResolution.idsAreResolvable(["real", "real"]) == false)
    }
}
