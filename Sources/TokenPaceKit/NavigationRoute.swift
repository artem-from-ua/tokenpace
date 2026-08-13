import Foundation

// MARK: - NavigationRoute (#333, ADR-0082)

/// Where the Settings window currently is: a sidebar `Section`, plus the `Child` page drilled into
/// from it, if any. The window's detail column shows the section's own page while `child` is nil and
/// the child's page otherwise; the sidebar always highlights `section`, drilled in or not (System
/// Settings does the same — its sidebar row stays selected while you are inside a child page).
///
/// Lives in the kit alongside ``NavigationHistory``, and for the same reason: the app target has no
/// test target, so the parts with rules worth getting wrong belong here. It is generic over both the
/// section and the child so those rules can be exercised without dragging in any Settings types —
/// the tests drive it with plain strings.
///
/// The rules this type owns:
/// - **A section change pops to the root.** Picking a different sidebar row cannot leave you inside
///   the previous section's child page, so ``root(_:)`` is the only way a section is entered.
/// - **Equality spans both fields**, which is what lets ``NavigationHistory`` treat "Appearance" and
///   "Appearance › Menu bar" as two distinct stops: ‹ steps from the child back to the parent rather
///   than skipping to whatever came before the section.
public struct NavigationRoute<Section: Equatable, Child: Equatable>: Equatable {

    /// The sidebar section — always set, including while a child page is showing.
    public private(set) var section: Section

    /// The child page drilled into from ``section``, or `nil` at the section's own page.
    public private(set) var child: Child?

    /// A route at a section's own page, with nothing drilled into.
    public init(_ section: Section) {
        self.section = section
        self.child = nil
    }

    /// A route at a section's own page — the spelling used where `root` reads better than a bare
    /// initializer, e.g. when popping back out of a child.
    public static func root(_ section: Section) -> Self { Self(section) }

    /// The route reached by drilling from this one into `child`, keeping the section.
    ///
    /// Drilling from a route that is *already* inside a child replaces that child rather than
    /// nesting: the hierarchy is one level deep by design (a child page has no navigator rows of its
    /// own), so there is no second level to push onto.
    public func drilling(into child: Child) -> Self {
        var next = self
        next.child = child
        return next
    }

    /// The route reached by leaving the child page for the section's own page. Already-at-root is a
    /// no-op, so this is safe to call unconditionally.
    public func poppedToRoot() -> Self { Self(section) }

    /// Whether a child page is showing — the state in which the toolbar's ‹ has somewhere to go
    /// *within* the section.
    public var isDrilledIn: Bool { child != nil }
}
