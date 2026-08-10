import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - NavigationHistory (#156 §2)

@Suite("NavigationHistory — back/forward over visited panes")
struct NavigationHistoryTests {

    /// A fresh history sits on its initial item with both directions dead — the state the Settings
    /// toolbar renders as two dimmed chevrons.
    @Test func startsWithNowhereToGo() {
        let history = NavigationHistory(current: "About")
        #expect(history.current == "About")
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    /// Visiting enables ‹ but not ›: there is somewhere behind you, nothing ahead.
    @Test func visitingEnablesBackOnly() {
        var history = NavigationHistory(current: "About")
        history.visit("General")
        #expect(history.current == "General")
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    /// ‹ then › returns to where you were, and the two ends swap availability along the way.
    @Test func backThenForwardRoundTrips() {
        var history = NavigationHistory(current: "About")
        history.visit("General")
        history.visit("Appearance")

        history.goBack()
        #expect(history.current == "General")
        #expect(history.canGoBack)
        #expect(history.canGoForward)

        history.goBack()
        #expect(history.current == "About")
        #expect(!history.canGoBack)      // start of history
        #expect(history.canGoForward)

        history.goForward()
        history.goForward()
        #expect(history.current == "Appearance")
        #expect(!history.canGoForward)   // end of history
    }

    /// The rule that separates this from a plain undo stack: stepping back and then choosing a *new*
    /// pane discards the branch you had stepped back from, exactly like a browser.
    @Test func visitingAfterBackDropsForwardHistory() {
        var history = NavigationHistory(current: "About")
        history.visit("General")
        history.visit("Appearance")
        history.goBack()                 // now on General, Appearance is ahead
        #expect(history.canGoForward)

        history.visit("Notifications")
        #expect(history.current == "Notifications")
        #expect(!history.canGoForward)   // Appearance is unreachable now
        history.goBack()
        #expect(history.current == "General")
    }

    /// Re-selecting the pane already shown is not a visit: it must not stack a duplicate entry, or ‹
    /// would appear to do nothing on the first click.
    @Test func revisitingCurrentItemRecordsNothing() {
        var history = NavigationHistory(current: "About")
        history.visit("About")
        #expect(!history.canGoBack)

        history.visit("General")
        history.visit("General")
        history.goBack()
        #expect(history.current == "About")
        #expect(!history.canGoBack)
    }

    /// Stepping past either end is a no-op rather than a crash — the buttons are disabled there, but
    /// a keyboard shortcut or a stale click can still arrive.
    @Test func steppingPastTheEndsIsHarmless() {
        var history = NavigationHistory(current: "About")
        history.goBack()
        history.goForward()
        #expect(history.current == "About")

        history.visit("General")
        history.goForward()              // already at the end
        #expect(history.current == "General")
        history.goBack()
        history.goBack()                 // already at the start
        #expect(history.current == "About")
    }

    /// Replaying history must not itself be recorded as a visit — otherwise ‹ would bounce between
    /// two panes instead of walking further back.
    @Test func replayingDoesNotGrowHistory() {
        var history = NavigationHistory(current: "A")
        history.visit("B")
        history.visit("C")
        history.goBack()
        history.goBack()
        #expect(history.current == "A")
        #expect(!history.canGoBack)      // exactly two steps of history existed, no more
    }
}
