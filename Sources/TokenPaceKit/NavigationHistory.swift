import Foundation

// MARK: - NavigationHistory (#156 §2)

/// Back/forward history over a sequence of visited items — the model behind the Settings window's
/// ‹ › toolbar buttons, which walk the panes you have visited the way a browser's do.
///
/// Lives in the kit rather than beside `SettingsModel` so it can be tested: the app target has no
/// test target, and this is the part with actual rules to get wrong (what a fresh visit does to the
/// forward stack, what replaying does *not* record). It is generic over the item so those rules can
/// be exercised without dragging in any Settings types.
///
/// The contract is the standard one:
/// - visiting a new item pushes the old current onto the back stack and **clears** forward history;
/// - `goBack()` moves the current item onto the forward stack;
/// - `goForward()` moves it back onto the back stack;
/// - re-visiting the item already current is not a visit at all, and records nothing.
public struct NavigationHistory<Item: Equatable> {

    /// The item currently shown.
    public private(set) var current: Item

    /// Previously visited items, oldest first — where `goBack()` steps to.
    public private(set) var back: [Item] = []

    /// Items popped by `goBack()`, ready to be replayed — where `goForward()` steps to.
    public private(set) var forward: [Item] = []

    public init(current: Item) {
        self.current = current
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Record a user-initiated move to `item`.
    ///
    /// Clearing `forward` is what makes this different from `goForward()`: once you strike out on a
    /// new path, the branch you had stepped back from is gone — the same as a browser.
    public mutating func visit(_ item: Item) {
        guard item != current else { return }
        back.append(current)
        forward.removeAll()
        current = item
    }

    /// Step back one item. No-op at the start of history.
    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    /// Step forward one item. No-op at the end of history.
    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }
}
