import AppKit

// MARK: - SettingsToolbarController (#156 §2; ‹ › rebuilt as one segmented item, #314)

/// Owns the Settings window's toolbar: the ‹ › history control and the current pane's name, laid out
/// the way System Settings lays out its own.
///
/// ### Why the toolbar, and not a row in the detail column
///
/// The earlier attempt drew this header as the first view inside the SwiftUI detail column. That put
/// three independent sources of vertical spacing in series — the empty safe area the toolbar reserves
/// at the top of the column, the header row's own padding, and the `Form`'s top inset — so tuning any
/// one of them moved the other two, and the header could be pushed past the first card or collapsed
/// out of sight entirely. Putting the arrows and the title in the toolbar itself removes the empty
/// strip (it now has contents) and with it every compensating offset. The traffic lights are the
/// window's own children and merely share the horizontal band (measured on System Settings over the
/// Accessibility API, #311).
///
/// ### Why ‹ › are one item holding a segmented control (#314)
///
/// They used to be two image-only `NSToolbarItem`s, which the toolbar renders as two system
/// `NSToolbarButton`s. That shape cannot match System Settings, for a measured reason: a toolbar
/// button's hover tracking covers **the plate it draws, not the button's frame** (probed live — with
/// a 40 pt button the plate is 28 pt, and a pointer 1 pt outside the plate lights nothing), and the
/// plate always renders 12 pt narrower than the button. Two separate buttons therefore always leave
/// a strip between their plates where the pointer hovers neither — the 8 pt dead zone of #314,
/// whatever the items' sizes (#313 tried 39/43.5/45/53; a stack with negative spacing overlaps the
/// boxes instead, and both plates light at once).
///
/// A **separated `NSSegmentedControl`** is the System Settings shape. Its two segments expose the
/// same accessibility tree the real System Settings toolbar has — measured on both, same numbers:
///
/// ```
/// AXGroup   76×52            ← the toolbar item's slot
///   AXGroup ~68×28           ← the span of the two hover plates
///     AXButton "Back"    40×40 ┐ adjacent (921..961..1001 in System Settings):
///     AXButton "Forward" 40×40 ┘ zero gap between hit zones, zero dead zone
/// ```
///
/// The control self-sizes to 80×40 (two 40 pt segments), draws each hover plate at 33–34 × 28, and
/// the plates touch edge to edge — every pointer position over the pair lights exactly one of them
/// (probed: seam−1 pt lights ‹, seam+1 pt lights ›). A disabled segment dims its template glyph and
/// draws no plate, which is System Settings' disabled look. Nothing is sized by hand: segment width,
/// plate metrics and glyph placement are the control's own, so the "system mechanism over measured
/// constants" rule (ADR-0040) now covers this pair too. Decision record: ADR-0077.
///
/// This also retires the #312/#313 workaround stack — walking the titlebar for generated buttons,
/// re-applying `isBordered` after every validation pass, keeping enablement in the controller so
/// `validateToolbarItem(_:)` could answer — none of which has anything to attach to any more: the
/// segmented control is our view, the toolbar never rebuilds it, and enablement is two plain
/// `setEnabled(_:forSegment:)` writes.
@MainActor
final class SettingsToolbarController: NSObject {

    private enum Metrics {
        /// Baseline lift for the title, in points, for the one pixel of vertical alignment left over
        /// once the glyph box matched the system's in width (measured: rows 41–62 against 40–61).
        ///
        /// Applied as a `.baselineOffset` attribute rather than a stack inset: the toolbar centres the
        /// item vertically in the bar, so neither `edgeInsets` nor a half-point on the spacer moved
        /// the label at all — both were measured and left the glyphs on the same rows.
        static let titleLift: CGFloat = 0.5
    }

    private enum ItemID {
        static let nav = NSToolbarItem.Identifier("TokenPaceSettingsNav")
        static let title = NSToolbarItem.Identifier("TokenPaceSettingsPaneTitle")
    }

    /// Invoked when ‹ is clicked. Wired by the window controller into the model's `goBack()`.
    var onBack: (() -> Void)?
    /// Invoked when › is clicked.
    var onForward: (() -> Void)?

    /// The ‹ › pair. Built once here and handed to the toolbar as the nav item's view — the toolbar
    /// styles a segmented control in an item exactly like System Settings' own back/forward cluster
    /// (borderless at rest, a rounded plate under the hovered segment) and never rebuilds it, so
    /// nothing needs re-applying on validation passes (the #312 flicker class of bugs).
    private let navControl = NSSegmentedControl()
    private let titleLabel = NSTextField(labelWithString: "")

    override init() {
        super.init()
        configureTitle()
        configureNav()
    }

    /// Build the toolbar and attach it to the window. `.unified` is the style that lands the traffic
    /// lights on the measured System Settings position — `.unifiedCompact` falls 7 pt short.
    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "TokenPaceSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // The bar is a fixed header, not a customisable strip of user-chosen tools.
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    /// Reflect the current pane and what the history buttons can reach.
    func update(title: String, canGoBack: Bool, canGoForward: Bool) {
        // Every write is guarded, because this runs on **any** model change, not just a navigation
        // one: `observeToolbarState` re-arms `withObservationTracking` on each fire, so toggling an
        // unrelated setting lands here too. Re-assigning the same value makes AppKit repaint, which
        // once showed up as a flicker under the pointer (#312).
        if titleLabel.stringValue != title {
            titleLabel.attributedStringValue = NSAttributedString(
                string: title,
                attributes: [.font: titleLabel.font as Any,
                             .foregroundColor: titleLabel.textColor as Any,
                             .baselineOffset: Metrics.titleLift])
        }
        if navControl.isEnabled(forSegment: 0) != canGoBack {
            navControl.setEnabled(canGoBack, forSegment: 0)
        }
        if navControl.isEnabled(forSegment: 1) != canGoForward {
            navControl.setEnabled(canGoForward, forSegment: 1)
        }
    }

    private func configureNav() {
        navControl.segmentCount = 2
        // `.separated` is what draws each segment as its own rounded hover plate — System Settings'
        // look — rather than one continuous capsule.
        navControl.segmentStyle = .separated
        // Buttons, not a sticky selection: the clicked segment reports through `selectedSegment`
        // inside the action and then releases.
        navControl.trackingMode = .momentary
        // The old toolbar-generated buttons took a bare symbol and sized it themselves (13 pt medium
        // at `.large`, measured 17×29 px @2x in #313). A segment applies no such treatment, so the
        // same configuration is set explicitly to keep the glyphs pixel-identical.
        let glyph = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .large)
        for (segment, back) in [(0, true), (1, false)] {
            let symbol = NSImage(
                systemSymbolName: back ? "chevron.backward" : "chevron.forward",
                // The description becomes the segment's accessibility label — the segments expose as
                // the two AXButtons System Settings' own pair shows.
                accessibilityDescription: back ? "Back" : "Forward")?
                .withSymbolConfiguration(glyph)
            // Template, so AppKit tints the glyph itself — that is what makes a disabled segment
            // read as greyed out. Without it the symbol carries its own colour and both arrows
            // render identically whatever the enablement says (#312).
            symbol?.isTemplate = true
            navControl.setImage(symbol, forSegment: segment)
            // `.scaleNone`: the glyph is already configured; segment scaling would resize it to the
            // segment's own liking and off the system metrics.
            navControl.setImageScaling(.scaleNone, forSegment: segment)
        }
        navControl.target = self
        navControl.action = #selector(navClicked)
    }

    private func configureTitle() {
        // Sized against the system's own pane title, compared pixel-for-pixel at the same window size:
        // theirs renders 22 px tall (@2x), `.headline` gave 19 and `systemFontSize` (the *body* size)
        // was further off still. 15 pt semibold lands on 22.
        // Matched against a System Settings window showing the *same word* ("VPN") at the same window
        // size — the only comparison that works here. Earlier attempts measured our all-caps pane name
        // against a system pane with lowercase and descenders ("Обліковий запис Apple"), whose glyph
        // box is not comparable, and that pointed the size the wrong way twice.
        //
        // Final render matches the system's exactly: glyph box x 180–238, y 40–61 (@2x, x relative to
        // the column divider), with 57.9% ink coverage against their 57.9%. `.semibold` is what
        // carries the weight — at `.medium` the stems came out 4–5 px against the system's 5–6.
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        // `labelColor` is the one that dims when the window resigns key, which is what System Settings'
        // title does — a hardcoded white stayed bright on a background window.
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
    }

    @objc private func navClicked() {
        // With `.momentary` tracking, `selectedSegment` is the segment under the click for the
        // duration of the action — it does not persist afterwards.
        if navControl.selectedSegment == 0 { onBack?() } else { onForward?() }
    }
}

// MARK: - NSToolbarDelegate

extension SettingsToolbarController: NSToolbarDelegate {

    /// Leading order, no `.flexibleSpace` in front: a flexible space here shoves the items into the
    /// right corner (measured), while System Settings keeps them at the left of the detail column.
    /// The `.sidebarTrackingSeparator` supplies the sidebar-width offset that puts them there.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, ItemID.nav, ItemID.title]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ItemID.nav:
            // One item for the pair, with the segmented control as its view. Two separate image
            // items are what produced the #314 dead zone (see the type doc); a custom *plain-button*
            // view is no alternative either — an `NSButton` outside the toolbar's own generation
            // never shows the hover plate at all (probed, #314).
            //
            // No min/max sizes anywhere: the control self-sizes to the system's 80×40 and the
            // toolbar wraps it in the same 76×52 slot System Settings' pair occupies.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = navControl
            item.label = "Back/Forward"
            item.paletteLabel = item.label
            // `isNavigational` is what these two are: AppKit reserves it for back/forward pairs and
            // positions them accordingly.
            item.isNavigational = true
            // Enablement flows from `update(...)` straight into the segments; there is nothing for
            // the toolbar's validation pass to manage (for a view item it would be a no-op anyway).
            item.autovalidates = false
            return item
        case ItemID.title:
            // The label is the item's view directly. It used to be wrapped in a stack whose
            // `edgeInsets` supplied a leading gap, which existed to clear a hand-positioned chevron
            // pair; the toolbar spaces its own items now.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = titleLabel
            return item
        default:
            return nil
        }
    }
}
