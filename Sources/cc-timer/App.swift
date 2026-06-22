import AppKit
import CCTimerKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu-bar item. Held strongly for the process lifetime — releasing it removes the item.
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: no Dock icon, no main menu — belt-and-suspenders with LSUIElement
        // so the bare `swift run` binary (which has no Info.plist) is also dockless.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // MOCK — replaced by live polling in #13. Drives the custom view with a representative
        // snapshot so the bars/idle/reset rendering is visible under `swift run` today.
        let layout = MenuBarLayout.make(from: Self.mockSnapshot(now: Date()), now: Date())
        let view = StatusItemView(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 22)))
        view.layout = layout

        // Hand the button a ready non-template image. (Hosting the custom NSView as a button
        // subview is unreliable — the system button paints over it; see StatusItemView.snapshotImage.)
        let image = view.snapshotImage()
        item.button?.image = image
        item.length = image.size.width
        self.statusItem = item

        AppLogger.lifecycle.info(
            "cc-timer status item attached (\(CCTimerKit.version, privacy: .public)); live polling arrives in #13"
        )
    }

    // MARK: - Mock data (#13 replaces this with a live poll)

    /// A representative `UsageSnapshot` for visual verification: mid-range 5h usage running a touch
    /// ahead of pace (red gap likely), lighter 7d usage, with both resets a few hours/days out.
    private static func mockSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 62, resetsAt: iso(now.addingTimeInterval(2 * 3600))),
            sevenDay: UsageWindow(utilization: 28, resetsAt: iso(now.addingTimeInterval(3 * 24 * 3600)))
        )
    }

    /// Format a `Date` as the ISO-8601 string the usage API emits (and `ResetClock.parse` accepts).
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
