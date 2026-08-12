import SwiftUI

// MARK: - SidebarIconMetrics (#168, ADR-0042; pinned to Large in #335)

/// Sizes for the coloured SF-Symbol chips in the Settings sidebar — **fixed at the Large bucket**,
/// deliberately ignoring System Settings → Appearance → "Sidebar icon size".
///
/// It used to follow that setting: read `NSTableViewDefaultSizeMode` from `NSGlobalDomain`
/// (1/2/3 = S/M/L), expose the matching chip/symbol/label sizes, and update live off the private
/// `AppleSideBarDefaultIconSizeChanged` distributed notification. Chip sizes did track the system;
/// nothing else did. Following one axis of a design while the rest stays put produced a sidebar that
/// matched System Settings at no size at all (#335):
///
/// - **Column width** could not be made to follow. Neither SwiftUI lever scales it — measured on the
///   live window, `.navigationSplitViewColumnWidth(259)` rendered 307 pt, and `.frame(width:)` snaps
///   between a couple of fixed states rather than scaling (frame 200 → 307 pt, 240 → 243, 340 → 243:
///   a *wider* frame giving a *narrower* column). Reaching into AppKit for
///   `NSSplitView.setPosition(_:ofDividerAt:)` did work, but see below.
/// - **Row inset** drifted with the list width — 32.5 pt at Small against the system's 10 — because
///   `List(.sidebar)` derives it, and `listRowInsets` can only *add* to its own 20 pt floor
///   (measured: leading 0 → 20 pt, 4 → 24, 10 → 30).
///
/// Both were fixable in isolation and the combination still did not match: chip, width and inset are
/// three of many numbers the system moves together, and we were chasing them one at a time. Pinning
/// to one size makes the window honestly *one* size — the largest, because that is the one whose
/// measured values (#156) the rest of the layout was built against.
///
/// The type stays (rather than the numbers being inlined at their use sites) so there is still one
/// place that answers "how big is a sidebar chip", and one place to revisit if a future macOS gives
/// SwiftUI a real handle on the column.
@MainActor
@Observable
final class SidebarIconMetrics {
    /// Chip (rounded-rect background) side length in points.
    let chip: CGFloat = 26
    /// SF-Symbol point size inside the chip.
    let symbol: CGFloat = 17
    /// Sidebar row label point size.
    let label: CGFloat = 15
    /// Gap between the icon chip and the label. SwiftUI's `Label` default is ~half the System Settings
    /// sidebar gap, so we set it explicitly (measured ≈ 8 pt against the live sidebar) — a documented
    /// value, since SwiftUI exposes no "match the system sidebar gap" API (ADR-0040 measured exception).
    let chipLabelGap: CGFloat = 8

    /// Sidebar column width, as handed to the `List`'s `.frame`. Not the rendered width: SwiftUI
    /// reinterprets it (see the type doc). 275 is what the Large bucket passed before the size was
    /// pinned, so the rendered sidebar is unchanged — it was pixel-identical to System Settings at
    /// Large, and pinning must not move it.
    let sidebarWidth: CGFloat = 275
}
