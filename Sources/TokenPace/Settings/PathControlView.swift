import SwiftUI
import AppKit

// MARK: - PathControlView (#168, ADR-0042)

/// A SwiftUI wrapper around AppKit's `NSPathControl` — the native control for showing a chosen file or
/// folder, used for the archive destination. It draws the folder icon + name with the **system's own**
/// icon-to-name spacing and icon size (no hand-picked numbers), truncates itself when the path is long
/// so it never widens the row, and reveals the folder in Finder on click. This is the system mechanism
/// ADR-0040 calls for (the same control the pre-#168 AppKit Settings used). `url == nil` shows the
/// muted placeholder.
struct PathControlView: NSViewRepresentable {
    let url: URL?
    var placeholder: String = "No folder selected"
    /// When `true` (default), clicking the control reveals the folder in Finder. Set `false` for a
    /// display-only path that has its own separate "Open in Finder" button (#242) — no click action, and
    /// the control hugs its content instead of stretching, so it sizes to the folder name.
    var clickToReveal: Bool = true

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        // `.popUp` shows just the chosen folder (not the full breadcrumb trail `.standard` draws).
        control.pathStyle = .popUp
        control.isEditable = false
        if clickToReveal {
            control.target = context.coordinator
            control.action = #selector(Coordinator.reveal(_:))
            // Let it shrink and truncate rather than force the row wider.
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            // Display-only: no click action, and hug the content so the control is exactly as wide as
            // the folder name (it can still compress/truncate if the row is too narrow).
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = url
        control.placeholderString = url == nil ? placeholder : nil
        context.coordinator.url = url
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL?
        init(url: URL?) { self.url = url }

        @objc func reveal(_ sender: NSPathControl) {
            guard let url = sender.url ?? url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
