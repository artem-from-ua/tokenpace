import AppKit
import OSLog
import CCTimerKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.artem-n.cc-timer", category: "lifecycle")

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
        log.info(
            "cc-timer scaffold launched (\(CCTimerKit.version, privacy: .public)); status item arrives in #10"
        )
        // No UI yet. Process stays alive via the AppKit run loop.
        // Quit with Ctrl-C (swift run) or `kill` / Activity Monitor (the .app).
    }
}
