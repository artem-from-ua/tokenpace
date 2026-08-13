import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - NavigationRoute (#333, ADR-0082)

/// Driven with plain strings rather than `SettingsSection` / a child enum: those live in the app
/// target, which has no test target, and the rules under test are about the route's own shape.
private typealias Route = NavigationRoute<String, String>

@Suite("NavigationRoute — section plus optional child page")
struct NavigationRouteTests {

    /// A bare section is at its own page: nothing drilled into, so the toolbar's ‹ has nothing to
    /// pop within the section.
    @Test func aFreshRouteSitsAtTheSectionsOwnPage() {
        let route = Route("Appearance")
        #expect(route.section == "Appearance")
        #expect(route.child == nil)
        #expect(!route.isDrilledIn)
    }

    /// Drilling keeps the section — that is what lets the sidebar stay highlighted on the parent
    /// while a child page shows.
    @Test func drillingKeepsTheSection() {
        let route = Route("Appearance").drilling(into: "Menu bar")
        #expect(route.section == "Appearance")
        #expect(route.child == "Menu bar")
        #expect(route.isDrilledIn)
    }

    /// The hierarchy is one level deep: drilling from inside a child replaces it rather than
    /// nesting, because a child page carries no navigator rows of its own.
    @Test func drillingFromAChildReplacesItRatherThanNesting() {
        let route = Route("Appearance")
            .drilling(into: "Menu bar")
            .drilling(into: "Dropdown")
        #expect(route.section == "Appearance")
        #expect(route.child == "Dropdown")
    }

    /// Popping returns to the section's own page, and is a no-op when already there — so callers
    /// need no "am I drilled in?" guard.
    @Test func poppingReturnsToTheSectionAndIsIdempotent() {
        let child = Route("Appearance").drilling(into: "Menu bar")
        #expect(child.poppedToRoot() == Route("Appearance"))
        #expect(Route("Appearance").poppedToRoot() == Route("Appearance"))
    }

    /// The parent and its child are **different** routes. This is the property `NavigationHistory`
    /// rides on: without it, drilling in would not record a stop and ‹ would skip the parent
    /// entirely.
    @Test func parentAndChildAreDistinctRoutes() {
        let parent = Route("Appearance")
        #expect(parent != parent.drilling(into: "Menu bar"))
        #expect(parent.drilling(into: "Menu bar") != parent.drilling(into: "Dropdown"))
    }

    /// Two routes into the same child of the same section are equal — so re-picking the row you are
    /// already on records nothing (`NavigationHistory.visit` drops a visit to the current item).
    @Test func sameSectionAndChildCompareEqual() {
        #expect(Route("Appearance").drilling(into: "Menu bar")
            == Route("Appearance").drilling(into: "Menu bar"))
    }

    /// The same child name under a different section is a different route: the child is scoped to
    /// its parent, not global.
    @Test func theSameChildNameUnderAnotherSectionIsADifferentRoute() {
        #expect(Route("Appearance").drilling(into: "Menu bar")
            != Route("Providers").drilling(into: "Menu bar"))
    }

    // MARK: Interaction with NavigationHistory — where the real rules live

    /// ‹ from a child page lands on its parent, not on whatever preceded the section. This is the
    /// behaviour the whole drill-in design depends on.
    @Test func backFromAChildLandsOnItsParent() {
        var history = NavigationHistory(current: Route("About"))
        history.visit(Route("Appearance"))
        history.visit(Route("Appearance").drilling(into: "Menu bar"))

        history.goBack()
        #expect(history.current == Route("Appearance"))
        #expect(!history.current.isDrilledIn)

        history.goBack()
        #expect(history.current == Route("About"))
    }

    /// Switching sections while drilled in records the new section's **root** — a sidebar pick can
    /// never leave you inside the previous section's child page.
    @Test func switchingSectionsFromAChildRecordsTheNewSectionsRoot() {
        var history = NavigationHistory(current: Route("Appearance").drilling(into: "Dropdown"))
        history.visit(.root("Notifications"))

        #expect(history.current == Route("Notifications"))
        #expect(!history.current.isDrilledIn)
        // ‹ still returns to the child you left, exactly like a browser's back.
        history.goBack()
        #expect(history.current == Route("Appearance").drilling(into: "Dropdown"))
    }

    /// › replays a drill-in that ‹ undid, and both ends of the walk stay reachable.
    @Test func forwardReplaysADrillIn() {
        var history = NavigationHistory(current: Route("Appearance"))
        history.visit(Route("Appearance").drilling(into: "Menu bar"))
        history.goBack()
        #expect(history.canGoForward)

        history.goForward()
        #expect(history.current == Route("Appearance").drilling(into: "Menu bar"))
        #expect(!history.canGoForward)
    }

    /// Stepping back out of a child and then drilling into the *other* child discards the forward
    /// branch — the browser rule, now across a drill-in boundary.
    @Test func drillingElsewhereAfterBackDropsTheForwardBranch() {
        var history = NavigationHistory(current: Route("Appearance"))
        history.visit(Route("Appearance").drilling(into: "Menu bar"))
        history.goBack()

        history.visit(Route("Appearance").drilling(into: "Dropdown"))
        #expect(history.current == Route("Appearance").drilling(into: "Dropdown"))
        #expect(!history.canGoForward)
    }
}
