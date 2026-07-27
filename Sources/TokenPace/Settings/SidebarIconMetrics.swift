import SwiftUI

// MARK: - SidebarIconMetrics (#168, ADR-0041)

/// The System Settings "Sidebar icon size" (System Settings → Appearance) drives the size of the
/// coloured SF-Symbol chips in a source-list sidebar. macOS keys this off `NSTableViewDefaultSizeMode`
/// in `NSGlobalDomain` (1 = Small, 2 = Medium, 3 = Large; absent = Medium) and broadcasts changes via
/// a private `AppleSideBarDefaultIconSizeChanged` distributed notification.
///
/// SwiftUI's `List(.sidebar)` doesn't size a *custom* icon view from this automatically (the standard
/// chip treatment is bespoke), so this observable reads the system bucket and exposes the matching
/// chip / symbol / label sizes, updating live when the user changes the setting. The per-bucket values
/// are **measured** from the live macOS 15 System Settings sidebar (chip 14/20/26, symbol 9/13/17,
/// label 11/13/15 for S/M/L) — the same values the old AppKit sidebar used — because there is no public
/// API that hands them to us. This keeps the size *system-driven* (not one hardcoded size) while the
/// exact numbers are documented, per ADR-0040.
@MainActor
@Observable
final class SidebarIconMetrics {
    /// Chip (rounded-rect background) side length in points.
    private(set) var chip: CGFloat = 20
    /// SF-Symbol point size inside the chip.
    private(set) var symbol: CGFloat = 13
    /// Sidebar row label point size.
    private(set) var label: CGFloat = 13

    /// Sidebar column width. System Settings widens the sidebar with the icon size (measured live: the
    /// visible sidebar is ≈ 278 pt at Large). SwiftUI's `.frame` on the List eats ≈ 30 pt of inset, so
    /// these are the *frame* values tuned to render to the measured visible widths.
    private(set) var sidebarWidth: CGFloat = 288

    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        apply()
        // Re-read when the user changes "Sidebar icon size" while the window is open. That is a
        // cross-process write to NSGlobalDomain, which UserDefaults KVO does NOT observe — only the
        // private distributed notification does. A nil-name observer would not receive it; the name
        // must be explicit. Best-effort: the name is private and may change on a future OS.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleSideBarDefaultIconSizeChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// The current system bucket: `NSTableViewDefaultSizeMode` (1/2/3 = S/M/L; anything else → Medium).
    private static func systemBucket() -> Int {
        let mode = UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode")
        return (1...3).contains(mode) ? mode : 2
    }

    private func apply() {
        // Measured from the live macOS 15 System Settings sidebar (#156): chip 14/20/26, symbol ≈ 0.65
        // chip → 9/13/17, label 11/13/15 for Small/Medium/Large.
        switch Self.systemBucket() {
        case 1:  (chip, symbol, label, sidebarWidth) = (14, 9, 11, 238)    // Small
        case 3:  (chip, symbol, label, sidebarWidth) = (26, 17, 15, 270)   // Large
        default: (chip, symbol, label, sidebarWidth) = (20, 13, 13, 251)   // Medium
        }
    }
}
