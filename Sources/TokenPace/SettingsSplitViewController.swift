import AppKit

// MARK: - SettingsSplitViewController (#131)

/// The split container behind the redesigned Settings window: a source-list sidebar on the left and a
/// detail pane on the right that swaps to the selected section's view. Modelled on macOS System
/// Settings (a sidebar of sections + a detail area).
///
/// Sections are supplied as ``Section`` descriptors whose `make` closure builds the detail view
/// **eagerly** (all panes are built up front — see `SettingsWindowController` for why: background
/// callbacks touch pane outlets while the window is closed). The detail views are cached, so switching
/// sections just swaps which cached view is shown; nothing is rebuilt.
@MainActor
final class SettingsSplitViewController: NSSplitViewController {

    /// One sidebar entry: a title, an SF Symbol, a tint for the icon chip, and a builder for its pane.
    struct Section {
        let title: String
        let symbol: String
        let tint: NSColor
        let make: () -> NSView
    }

    /// Called when the selection changes, with the new section title — used to update the window title.
    var onSelect: ((String) -> Void)?

    /// The title of the currently-selected section, or `nil` before the first selection.
    private(set) var selectedTitle: String?

    private let sections: [Section]
    private let sidebarWidth: CGFloat
    private let sidebar: SettingsSidebarController
    private let detailContainer = NSView()
    /// Cached detail views, built once on first show of each section (indexed by section).
    private var detailViews: [Int: NSView] = [:]

    init(sidebarWidth: CGFloat, sections: [Section]) {
        self.sidebarWidth = sidebarWidth
        self.sections = sections
        self.sidebar = SettingsSidebarController(items: sections.map {
            .init(title: $0.title, symbol: $0.symbol, tint: $0.tint)
        })
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // No `loadView` override: NSSplitViewController creates and owns its `NSSplitView` as `view`.
    // Overriding it with a plain NSView breaks the split entirely (the panes never lay out).

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = sidebarWidth
        sidebarItem.maximumThickness = sidebarWidth
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailVC = NSViewController()
        detailVC.view = detailContainer   // split VC sizes this root view via autoresizing — leave it
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 380
        addSplitViewItem(detailItem)

        sidebar.onSelect = { [weak self] index in self?.select(index) }
        select(0)   // land on the first section
    }

    /// Show the section at `index`, building and caching its detail view on first visit.
    private func select(_ index: Int) {
        guard sections.indices.contains(index) else { return }

        let detail: NSView
        if let cached = detailViews[index] {
            detail = cached
        } else {
            detail = sections[index].make()
            detailViews[index] = detail
        }

        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])

        selectedTitle = sections[index].title
        onSelect?(sections[index].title)
        sidebar.select(index)
    }

    /// Eagerly build every pane up front. Called by `SettingsWindowController` right after init so no
    /// pane's outlets are nil when a background callback fires while the window is closed.
    func buildAllPanes() {
        for index in sections.indices where detailViews[index] == nil {
            detailViews[index] = sections[index].make()
        }
    }
}
