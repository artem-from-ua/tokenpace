import AppKit
import SwiftUI
import TokenPaceKit

// MARK: - InsightsDashboard

/// A dashboard listed in the Insights sidebar. The pilot ships one; later consumers (#239/#240/#241)
/// add cases, and the week×hour view may itself gain interval options (year/month/week-hour).
enum InsightsDashboard: String, CaseIterable, Identifiable {
    case weekHour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekHour: return "Weekly rhythm"
        }
    }

    var symbol: String {
        switch self {
        case .weekHour: return "calendar.day.timeline.left"
        }
    }
}

// MARK: - InsightsViewModel

/// Observable state for the Insights window (#245). Holds the current aggregated grid, the 5h/7d
/// filter, and whether recording is on. `refresh()` re-reads the journal from disk and re-runs the
/// pure ``UsageGridAggregator`` — called on window open and on each poll (no timers).
@MainActor
@Observable
final class InsightsViewModel {
    /// The dashboard shown in the detail pane.
    var selection: InsightsDashboard = .weekHour

    /// The aggregated grid for the current filter, or `nil` before the first refresh.
    private(set) var grid: UsageGrid?
    /// Whether the collector is on — drives the empty-state hint when there's no data yet.
    private(set) var recording: Bool = PersistedConfig.journalEnabled
    /// The 5h/7d limit filter. For the `sampleDensity` pilot it's a no-op (both yield the same grid),
    /// but it's wired so the control is real and ready for later utilisation metrics.
    var filter: UsageGridFilter = .fiveHour {
        didSet { if filter != oldValue { refresh() } }
    }

    /// Re-read the journal and rebuild the grid. Best-effort: an empty/absent journal yields an
    /// all-holes grid (honest empty state), never an error.
    func refresh() {
        recording = PersistedConfig.journalEnabled
        let records = JournalStore.load()
        // Monday-first for now; taking the first weekday from the locale is #251.
        grid = UsageGridAggregator.weekHourGrid(
            from: records, metric: .sampleDensity, filter: filter,
            firstWeekday: 2, timeZone: .current)
    }
}

// MARK: - InsightsWindowController

/// The "Insights" window (#242 skeleton, #245 pilot chart) — a **separate** window styled like
/// Settings: a sidebar of dashboards on the left, the selected dashboard on the right. The pilot ships
/// one dashboard, a weekday × hours sample-density heatmap (#245); later consumers (#239/#240/#241)
/// add more. Kept as its own controller (not a Settings pane) because Settings is only for configuring
/// the collector — viewing the data is a distinct surface.
///
/// Single-instance, lazily created, reused on re-open. Refreshed on open (`show()`) and on each poll
/// (`render()`, a no-op while the window is closed) — mirroring `TroubleshootWindowController`, but
/// pushing data into an `@Observable` view-model rather than mutating AppKit labels.
@MainActor
final class InsightsWindowController: NSWindowController {

    private enum Metrics {
        /// Matches the Settings window width so the two feel like one family (#156).
        static let contentWidth: CGFloat = 857
        static let contentHeight: CGFloat = 560
        /// Sidebar width, matching the Settings source list at the default icon size.
        static let sidebarWidth: CGFloat = 220
    }

    private var hasBeenPositioned = false
    private let model = InsightsViewModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.contentWidth, height: Metrics.contentHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TokenPace Insights"
        window.level = .floating               // float above other apps from a menu-bar app (ADR-0012 §6)
        window.isReleasedWhenClosed = false    // keep the controller alive so re-opening reuses it
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.contentMinSize = NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight)
        self.init(window: window)
        let root = InsightsRootView(
            model: model,
            minWidth: Metrics.contentWidth,
            minHeight: Metrics.contentHeight,
            sidebarWidth: Metrics.sidebarWidth)
        let hosting = NSHostingController(rootView: root)
        // Don't let the hosting controller drive the window size from SwiftUI's ideal — a
        // NavigationSplitView's ideal would otherwise collapse the split to a sliver (as in Settings).
        hosting.sizingOptions = []
        window.contentViewController = hosting
    }

    /// Show or re-focus the window, refreshing the grid first so it opens on current data.
    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.setContentSize(NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight))
        if !hasBeenPositioned {
            hasBeenPositioned = true
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Live-refresh on each poll — a no-op while the window is closed (like Troubleshoot's `render`).
    /// Called from `AppDelegate.apply` **after** the new record is appended to disk, so the re-read
    /// includes it.
    func render() {
        guard window?.isVisible == true else { return }
        model.refresh()
    }
}

// MARK: - InsightsRootView

/// The Insights window content (#245): a sidebar of dashboards (Settings-style) beside the selected
/// dashboard's detail pane.
private struct InsightsRootView: View {
    @Bindable var model: InsightsViewModel
    var minWidth: CGFloat = 857
    var minHeight: CGFloat = 560
    var sidebarWidth: CGFloat = 220

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(InsightsDashboard.allCases) { dashboard in
                    Label(dashboard.title, systemImage: dashboard.symbol)
                        .tag(dashboard)
                }
            }
            .listStyle(.sidebar)
            .frame(width: sidebarWidth)
            // Like Settings, the split is fixed — no collapsible sidebar in a menu-bar window.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
        }
        .frame(minWidth: minWidth, maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch model.selection {
        case .weekHour: weekHourPane
        }
    }

    /// The pilot dashboard: header + 5h/7d filter above the weekday × hours heatmap, or an honest
    /// empty state when nothing has been observed yet.
    private var weekHourPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let grid = model.grid, grid.maxObservedValue != nil {
                UsageHeatmapView(grid: grid)
            } else {
                emptyState
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sampling density by weekday")
                    .font(.headline)
                Text("Every week of history folded into one — when you're usually active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Limits", selection: $model.filter) {
                Text("5-hour limits").tag(UsageGridFilter.fiveHour)
                Text("7-day limits").tag(UsageGridFilter.sevenDay)
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No usage history yet")
                .font(.title3.weight(.semibold))
            if !model.recording {
                Text("Turn on **Record usage history** in Settings → Extra features to start collecting data.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Readings will appear here as they're collected — check back after a few polls.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
