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

    /// Called with the newly-selected row index when the user picks a section.
    var onSelect: ((Int) -> Void)?

    private let items: [Item]
    private let tableView = NSTableView()
    /// Guards against re-entrancy: `select(_:)` sets the selection programmatically, which would
    /// otherwise re-fire the delegate and loop back through the split controller.
    private var isProgrammaticSelection = false

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
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        scroll.documentView = tableView
        view = scroll
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

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        // A rounded coloured chip behind the symbol, like System Settings' sidebar icons.
        let chip = ChipView(tint: item.tint)
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(icon)

        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(chip)
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 22),
            chip.heightAnchor.constraint(equalToConstant: 22),
            chip.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            chip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
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
