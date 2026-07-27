import AppKit

// MARK: - SettingsSidebarController (#131)

/// The source-list sidebar of the redesigned Settings window: one selectable row per section, each a
/// coloured SF Symbol chip beside the section title — the same visual language as the sidebar in macOS
/// System Settings. Selection notifies `onSelect` with the row index; `SettingsSplitViewController`
/// swaps the detail pane in response.
@MainActor
final class SettingsSidebarController: NSViewController {

    struct Item {
        let title: String
        let symbol: String
        let tint: NSColor
    }

    private enum Metrics {
        /// Gap from the chip to the label — the standard source-list icon-to-text spacing.
        static let chipLabelGap: CGFloat = 8
    }

    /// The system "Sidebar icon size" as an S/M/L bucket, read straight from the global default
    /// `NSTableViewDefaultSizeMode` (1 = Small, 2 = Medium, 3 = Large; absent = Medium). We do NOT use
    /// `NSTableView.effectiveRowSizeStyle` here: for a `.sourceList` table it does not resolve to
    /// `.large` even when the user picks Large, so a Large sidebar was rendering at the Medium size
    /// (#156). The global default is the authoritative source that System Settings itself keys off.
    private static func systemIconSize() -> Int {
        let mode = UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode")
        return (1...3).contains(mode) ? mode : 2   // default → Medium
    }

    /// Chip / SF-Symbol / label point sizes per system icon-size bucket, measured from the live macOS 15
    /// System Settings sidebar (#156): chip 14/20/26, label 11/13/15 for Small/Medium/Large; symbol ≈
    /// 0.65 chip. The custom chip can't ride AppKit's automatic outlet sizing (the source-list outlet
    /// imageView greys + hides the glyph), so these measured values size it explicitly.
    private static func iconMetrics() -> (chip: CGFloat, symbol: CGFloat, labelFont: CGFloat) {
        switch systemIconSize() {
        case 1:  return (14, 9, 11)    // Small
        case 3:  return (26, 17, 15)   // Large
        default: return (20, 13, 13)   // Medium
        }
    }

    /// Called with the newly-selected row index when the user picks a section.
    var onSelect: ((Int) -> Void)?

    private let items: [Item]
    private let tableView = NSTableView()
    /// Guards against re-entrancy: `select(_:)` sets the selection programmatically, which would
    /// otherwise re-fire the delegate and loop back through the split controller.
    private var isProgrammaticSelection = false
    /// Retains the `UserDefaults.didChangeNotification` observer that re-sizes the icons when the system
    /// "Sidebar icon size" changes (#156). The observer uses `[weak self]`, and this controller is the
    /// window's single long-lived sidebar (kept for the app's lifetime), so no explicit teardown is
    /// needed — holding the token keeps the registration alive as long as the controller.
    private var sizeModeObserver: (any NSObjectProtocol)?

    init(items: [Item]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let column = NSTableColumn(identifier: .init("section"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .sourceList   // sets the source-list selection highlight too (macOS 11+)
        // Follow the system "Sidebar icon size" (System Settings → General), like the System Settings
        // sidebar itself (#156). `.default` opts the table into the system small/medium/large sizing —
        // the AppKit default is `.custom`, which ignores it. With a non-custom style AppKit manages the
        // row height, so `rowHeight` is left unset; the cell reads `effectiveRowSizeStyle` to size its
        // icon chip to match. `NSTableViewDefaultSizeMode` in NSGlobalDomain (1/2/3 = S/M/L) backs it.
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        scroll.documentView = tableView
        view = scroll

        // Re-lay out when the user changes "Sidebar icon size" in System Settings while we're open.
        // That is a CROSS-PROCESS write to NSGlobalDomain, which `UserDefaults.didChangeNotification`
        // and defaults-KVO do NOT observe (they only see this process's own writes). AppKit's own
        // source-list tables relayout via a private DistributedNotificationCenter post named
        // `AppleSideBarDefaultIconSizeChanged` (verified from the AppKit binary) — the System Settings
        // pane broadcasts it after writing `NSTableViewDefaultSizeMode`. We observe the same name (a
        // `nil`-name distributed observer does NOT receive it — the name must be explicit) and re-read
        // the value ourselves. Best-effort: the name is private, so it may change on a future OS.
        sizeModeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleSideBarDefaultIconSizeChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The icon size changed → the cell chip/label sizes change; rebuild the rows. The
                // sidebar width itself is fixed (like System Settings), so only the cells reload.
                self?.tableView.reloadData()
            }
        }
    }

    /// Programmatically select `index` without re-firing `onSelect` (the split controller drives this
    /// to keep the sidebar in sync when it changes the pane itself).
    func select(_ index: Int) {
        guard items.indices.contains(index), tableView.selectedRow != index else { return }
        isProgrammaticSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isProgrammaticSelection = false
    }
}

// MARK: - Data source & delegate

extension SettingsSidebarController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let m = Self.iconMetrics()

        // The symbol is a CUSTOM image view, deliberately NOT the cell's `imageView` outlet: a
        // source-list cell applies AppKit's own template tint + vibrancy to the outlet imageView, which
        // painted our glyph a low-contrast grey and hid it entirely on an inactive window (#156). A
        // plain subview keeps its explicit white tint on the coloured chip in every state.
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let symbolImage = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        symbolImage?.isTemplate = true
        icon.image = symbolImage
        icon.contentTintColor = .white   // white glyph on the coloured chip — System Settings' look
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: m.symbol, weight: .regular)

        // The coloured chip behind the symbol (System Settings renders this via a private graphic-icon).
        let chip = ChipView(tint: item.tint)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(icon)

        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: m.labelFont)
        label.lineBreakMode = .byTruncatingTail
        // HIG: a too-long sidebar label truncates on one line (never wraps); a hover expansion tooltip
        // reveals the full string. The dynamic width (below) normally keeps it from truncating at all.
        label.allowsExpansionToolTips = true
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(chip)
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: m.chip),
            chip.heightAnchor.constraint(equalToConstant: m.chip),
            chip.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: Metrics.chipLabelGap),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return }
        onSelect?(row)
    }
}

// MARK: - ChipView

/// The rounded coloured background behind a sidebar icon. Layer-backed with a fixed tint (the tint is
/// already a fixed system colour like `.systemBlue`, which is dynamic, so re-resolve it in
/// `updateLayer()` for dark/light — same `CGColor`-is-static caveat as the cards).
@MainActor
final class ChipView: NSView {

    private let tint: NSColor

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.cgColor
    }
}
