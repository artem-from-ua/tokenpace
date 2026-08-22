import AppKit

// MARK: - SettingsToolbarController (#156 §2; ‹ › rebuilt as one segmented item, #314)

/// Owns the Settings window's toolbar: the ‹ › history control and the current pane's name, laid out
/// the way System Settings lays out its own.
///
/// **The toolbar, not a row in the detail column**: a SwiftUI header row would put three independent
/// sources of vertical spacing in series (the toolbar's empty safe area, the row's own padding, the
/// `Form`'s top inset), so tuning any one moves the other two. Putting the arrows and the title in
/// the toolbar removes the empty strip and every compensating offset.
///
/// **‹ › as one item holding a segmented control (#314, ADR-0077)**: two separate image-only
/// `NSToolbarItem`s render as two `NSToolbarButton`s whose hover plate is narrower than the button
/// frame, leaving an 8 pt dead zone between them whatever the items' sizes. A **separated
/// `NSSegmentedControl`** matches System Settings' own accessibility tree exactly:
///
/// ```
/// AXGroup   76×52            ← the toolbar item's slot
///   AXGroup ~68×28           ← the span of the two hover plates
///     AXButton "Back"    40×40 ┐ adjacent, zero gap between hit zones
///     AXButton "Forward" 40×40 ┘
/// ```
///
/// The control self-sizes to 80×40, draws each hover plate at 33–34 × 28 touching edge to edge, and
/// a disabled segment dims its template glyph with no plate — System Settings' disabled look. Nothing
/// is sized by hand (ADR-0040: system mechanism over measured constants).
@MainActor
final class SettingsToolbarController: NSObject {

    private enum Metrics {
        /// The one pixel of vertical alignment left over once the glyph box matched the system's in
        /// width (measured: rows 41–62 against 40–61). Applied as a `.baselineOffset` attribute rather
        /// than a stack inset: the toolbar centres the item vertically in the bar, so neither
        /// `edgeInsets` nor a spacer offset moves the label at all.
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

    /// Built once here and handed to the toolbar as the nav item's view; the toolbar never rebuilds
    /// it, so nothing needs re-applying on validation passes (the #312 flicker class of bugs).
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
        // one. Re-assigning the same value makes AppKit repaint, which once showed up as a flicker
        // under the pointer (#312).
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
        // A segment applies no automatic symbol treatment, so it's set explicitly (13 pt medium,
        // `.large` scale, measured 17×29 px @2x).
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
        // Sized against the system's own pane title, compared pixel-for-pixel at the same window
        // size: theirs renders 22 px tall (@2x). 15 pt semibold lands on 22 (glyph box x 180–238,
        // y 40–61, 57.9% ink coverage matching theirs exactly).
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

    /// No `.flexibleSpace` in front: it would shove the items into the right corner. The
    /// `.sidebarTrackingSeparator` supplies the sidebar-width offset that keeps them at the left of
    /// the detail column, like System Settings.
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
            // One item for the pair, with the segmented control as its view. Two separate items give
            // the 8 pt dead zone the type doc measures; a plain-button view is no alternative either
            // — an `NSButton` outside the toolbar's own generation never draws the hover plate at
            // all (probed). No min/max sizes: the
            // control self-sizes to the system's 80×40 and the toolbar wraps it in the same 76×52
            // slot System Settings' pair occupies.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = navControl
            item.label = "Back/Forward"
            item.paletteLabel = item.label
            // `isNavigational` is what these two are: AppKit reserves it for back/forward pairs.
            item.isNavigational = true
            // Enablement flows from `update(...)` straight into the segments; nothing for the
            // toolbar's validation pass to manage.
            item.autovalidates = false
            return item
        case ItemID.title:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = titleLabel
            return item
        default:
            return nil
        }
    }
}
