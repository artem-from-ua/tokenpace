import SwiftUI
import AppKit

// MARK: - PathControlView (#168, ADR-0041)

/// A SwiftUI wrapper around AppKit's `NSPathControl` — the native control for showing a chosen file
/// or folder. In `.popUp` style it shows the folder icon + name, **truncates itself** when the path
/// is long (so it never widens the row), and reveals the folder in Finder on click. This is the same
/// control the previous AppKit Settings used (ADR-0040: a system mechanism, not a bare label that a
/// long path would stretch). `url == nil` shows the muted "No folder selected" placeholder.
struct PathControlView: NSViewRepresentable {
    let url: URL?
    var placeholder: String = "No folder selected"

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .popUp
        control.isEditable = false
        control.target = context.coordinator
        control.action = #selector(Coordinator.reveal(_:))
        // Let it shrink and truncate rather than force the row wider.
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
