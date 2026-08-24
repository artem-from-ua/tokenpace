import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Provider display order and three-provider merging (#503)

@Suite("Provider display order")
struct ProviderOrderTests {

    /// The order the whole UI reads: Claude first because it owns the bars, the rest alphabetical by
    /// display name.
    @Test func orderIsClaudeThenAlphabetical() {
        #expect(ProviderID.displayOrder == [.claude, .codex, .github])
        #expect(ProviderID.claude.displayIndex == 0)
        #expect(ProviderID.codex.displayIndex == 1)
        #expect(ProviderID.github.displayIndex == 2)
    }

    /// The property the split exists for: the case list is archive identity (the raw values are
    /// journal-stable), so a case appended there must not be able to reorder the screen. Today the
    /// two orders genuinely differ, which is what makes the test mean something.
    @Test func displayOrderIsIndependentOfCaseDeclarationOrder() {
        #expect(ProviderID.displayOrder != ProviderID.allCases)
        // Every case is present exactly once, whatever the two orders are.
        #expect(Set(ProviderID.displayOrder) == Set(ProviderID.allCases))
        #expect(ProviderID.displayOrder.count == ProviderID.allCases.count)
    }

    @Test func rawValuesAreTheJournalStableSpellings() {
        #expect(ProviderID.claude.rawValue == "claude")
        #expect(ProviderID.github.rawValue == "github")
        #expect(ProviderID.codex.rawValue == "codex")
    }

    // MARK: merging

    private func health(_ provider: ProviderID) -> StatusHealth {
        switch provider {
        case .claude:
            return StatusHealth(checks: [ServiceCheck(id: .claudeAPI, components: [
                ResolvedComponent(name: "Claude API (api.anthropic.com)", status: .operational),
            ])])
        case .github:
            return StatusHealth(checks: [ServiceCheck(id: .githubDevelopment, components: [
                ResolvedComponent(name: "Actions", status: .operational),
            ])])
        case .codex:
            return StatusHealth(checks: [ServiceCheck(id: .codexCLI, components: [
                ResolvedComponent(name: "CLI", status: .operational),
            ])])
        }
    }

    /// Whatever order the three polls land in, the merged checks read in display order — the popup
    /// renders plates in the order the checks arrive, so a merge that shuffled them would move the
    /// plates by who polled last.
    @Test func mergingSortsByDisplayOrderFromAnyArrival() {
        let providers: [ProviderID] = [.claude, .github, .codex]
        for a in providers {
            for b in providers where b != a {
                for c in providers where c != a && c != b {
                    let merged = health(a).merging(health(b)).merging(health(c))
                    #expect(merged.checks.map(\.id.provider) == [.claude, .codex, .github])
                }
            }
        }
    }

    /// A re-poll replaces one provider's checks and leaves the others alone — what lets one provider
    /// fail and recover without touching another's rows.
    @Test func mergingReplacesOneProviderAndIsIdempotent() {
        let all = health(.claude).merging(health(.codex)).merging(health(.github))
        let again = all.merging(health(.codex))
        #expect(again.checks.count == all.checks.count)
        #expect(again.checks.map(\.id) == all.checks.map(\.id))

        let degraded = StatusHealth(checks: [ServiceCheck(id: .codexCLI, components: [
            ResolvedComponent(name: "CLI", status: .majorOutage),
        ])])
        let after = all.merging(degraded)
        #expect(after.worstProblem(of: .codex) == .majorOutage)
        #expect(after.worstProblem(of: .claude) == nil)
        #expect(after.worstProblem(of: .github) == nil)
        #expect(after.checks.map(\.id.provider) == [.claude, .codex, .github])
    }

    /// The menu bar's worst-of-all spans providers; the per-provider one does not — picking the wrong
    /// one would let a Codex outage accelerate polling against GitHub's page.
    @Test func worstProblemIsFlatWhileWorstProblemOfIsPerProvider() {
        let outage = StatusHealth(checks: [ServiceCheck(id: .codexCLI, components: [
            ResolvedComponent(name: "CLI", status: .majorOutage),
        ])])
        let merged = health(.claude).merging(outage).merging(health(.github))
        #expect(merged.worstProblem == .majorOutage)
        #expect(merged.worstProblem(of: .codex) == .majorOutage)
        #expect(merged.worstProblem(of: .github) == nil)
    }

    @Test func everyServiceKnowsItsProvider() {
        for service in StatusHealth.codexServices {
            #expect(service.id.provider == .codex)
        }
        #expect(ServiceID.githubDevelopment.provider == .github)
        #expect(ServiceID.claudeCode.provider == .claude)
    }
}
