import AppKit
import SwiftUI
import TokenPaceKit

// MARK: - InsightsWindowController

/// The "Insights" window (#242, ADR-0067) — a **separate** window (styled like Settings) reached from
/// the first item of the popup menu, where usage-journal data will be visualised. This is the shell
/// for the Insights feature area (#238): the collector (#242) fills the journal; the charts that read
/// it back arrive in #239/#240/#241.
///
/// For now the window is a placeholder: it exists so the menu entry, the window chrome, and the
/// journal-enabled empty state are all in place, and a downstream ticket only has to drop chart views
/// into `InsightsRootView`. Kept as its own controller (not a Settings pane) because Settings is only
/// for configuring the collector — viewing the data is a distinct surface.
@MainActor
final class InsightsWindowController: NSWindowController {

    private enum Metrics {
        /// Matches the Settings window width so the two feel like one family (#156).
        static let contentWidth: CGFloat = 857
        static let contentHeight: CGFloat = 560
    }

    private var hasBeenPositioned = false

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
        let hosting = NSHostingController(rootView: InsightsRootView())
        hosting.sizingOptions = []
        window.contentViewController = hosting
    }

    /// Show or re-focus the window, bringing the app forward and centring on first show of a session.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.setContentSize(NSSize(width: Metrics.contentWidth, height: Metrics.contentHeight))
        if !hasBeenPositioned {
            hasBeenPositioned = true
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - InsightsRootView

/// Placeholder content for the Insights window (#242). The usage journal is the data source; the
/// charts that render it land in a downstream ticket (#239/#240/#241). Until then this states what the
/// window will show and reflects whether recording is on, so the empty state is honest rather than blank.
///
/// The empty state says outright that the window is still a placeholder and the charts come in a later
/// version (#253) — without it a user who has just enabled recording reads the unchanged screen as a
/// broken feature. Three deliberate wordings, all from that ticket:
///
/// - The ⚠️ caveat reuses the Settings hint treatment (#156) so both surfaces flag a caveat alike.
/// - "over time" is gone from the lead line: it was the only temporal claim in the window and it was
///   unbounded, so it invited exactly the "should I come back in an hour or a month?" question the
///   ticket opens with. Quantifying it honestly means counting *days with data* (idle cadence and
///   `pausePollingWhenScreenLocked` leave gaps, so wall-clock overstates coverage) — that belongs with
///   the charts, not with a placeholder, so the promise is dropped rather than made precise.
/// - The Settings pointer names **General**, where the toggle actually lives. This is the third
///   place it has named: General before #242, Extra features after it, General again since #317
///   moved the journal back. A hard-coded path to another pane goes stale silently — nothing fails
///   to build when the toggle moves — so whoever moves it next must grep for this string.
private struct InsightsRootView: View {
    /// Read once on appear — a plain read of the collector switch (no live binding needed for a
    /// placeholder; the window is short-lived and re-reads on each open).
    @State private var recording = PersistedConfig.journalEnabled

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Usage Insights")
                .font(.title2.weight(.semibold))
            Text("Charts of your usage will appear here.")
                .foregroundStyle(.secondary)
            // Warning triangle, not a plain line: the caveat has to read as a caveat at a glance,
            // otherwise it blends into the neutral lines around it. Reuses the Settings ⚠️ hint
            // treatment (#156) so the two surfaces state a caveat the same way.
            SettingsHint(text: "This window is still a placeholder — the charts arrive in a future version of TokenPace.",
                         warning: true)
            if !recording {
                Text("Turn on **Record usage history** in Settings → General to start collecting data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { recording = PersistedConfig.journalEnabled }
    }
}
