import AppKit
import TokenPaceKit

// MARK: - Settings shell support (#168, ADR-0041)

/// Static links used by the Settings About pane.
enum SettingsLinks {
    static let repoURL = "https://github.com/artem-from-ua/tokenpace"
    static let repoDisplay = "github.com/artem-from-ua/tokenpace"
}

/// Thin wrapper over `NSWorkspace.open` for a URL string, so the model doesn't import AppKit URL glue
/// inline. A malformed string is silently ignored (same as the old guard-let).
enum NSWorkspaceOpener {
    @MainActor static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The archive-destination folder picker — an imperative modal `NSOpenPanel`, invoked from a SwiftUI
/// button action. `.fileImporter` can't set the prompt/message/seed directory, so the AppKit panel is
/// kept verbatim (ADR-0041). Returns the chosen path, or `nil` if cancelled.
enum FolderPicker {
    @MainActor static func choose(current: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to archive Claude Code session logs into."
        if let current {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

extension SettingsModel {

    /// The version string shown in the About pane: the kit version, plus a "— Dev Build" (and stub
    /// name) suffix outside a real `.app` bundle.
    static func makeVersionText() -> String {
        let base = TokenPaceKit.version
        guard !LaunchAtLoginController.isAppBundle else { return base }
        if let stub = ProcessInfo.processInfo.environment["TOKENPACE_STUB"] {
            return "\(base) — Dev Build (stub: \(stub))"
        }
        return "\(base) — Dev Build"
    }

    /// Compose the Session Logs status line (#110): the "Last archived …" summary, the running totals,
    /// or the not-yet-archived placeholder. Empty when no destination is set.
    static func composeArchiveStatus(destination: String?, lastSync: Date?, summary: LogArchiver.Summary?) -> String {
        guard let destination else { return "" }

        // Before this app's first archive there is nothing to report — the destination folder's own
        // file count is not our archive (it may hold unrelated files), so don't show totals that would
        // contradict "Not archived yet".
        guard let last = lastSync else { return "Not archived yet." }

        let destURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)
        let stats = LogArchiver().archiveStats(at: destURL)
        let totals = "\(stats.files) files · \(ByteSize.humanReadable(stats.bytes))"
        let when = PopupViewController.ageText(max(0, Date().timeIntervalSince(last)))
        if let summary {
            return "Last archived: \(when) · \(summary.copied) updated · \(totals)"
        }
        return "Last archived: \(when) · \(totals)"
    }
}
