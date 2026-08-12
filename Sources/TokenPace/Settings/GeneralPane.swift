import SwiftUI
import TokenPaceKit

// MARK: - GeneralPane (#168, ADR-0042)

/// Settings → General: how the app lives on this Mac — launch-at-login, screen-lock polling pause,
/// and the usage journal.
///
/// **Usage history belongs here rather than with a provider** (#317): the journal is a feature of
/// the app — it feeds the Insights window (ADR-0067) — and providers are merely sources of records
/// in it. A second provider adds rows to the same single journal, so the switch that owns it stays
/// app-wide. (It spent #242…#317 on the "Extra features" pane, which is being retired.)
struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch TokenPace at login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.toggleLaunchAtLogin($0) }))
                    .disabled(!model.launchToggleEnabled)
                    SettingsHint(text: model.launchHint.text, warning: model.launchHint.devBuild)
                }

                Toggle("Pause usage API polling while the screen is locked", isOn: Binding(
                    get: { model.pausePolling },
                    set: { model.setPausePolling($0) }))
            }

            // MARK: Usage history (usage journal collector, #242 — moved here by #317)
            Section("Usage history") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Record usage history", isOn: Binding(
                        get: { model.journalEnabled },
                        set: { model.setJournalEnabled($0) }))
                    SettingsHint(text: "Saves each usage reading to a local file so the Insights window can show trends over time. The data stays on this Mac and never leaves it.")
                }

                // Read-only destination: the journal lives in Application Support and is not
                // user-relocatable, but the folder can be revealed in Finder. Shown only when on.
                // The path control is display-only (no click) and hugs its content — right-aligned
                // before the button, since a separate "Open in Finder" button already reveals it.
                if model.journalEnabled {
                    LabeledContent("Location") {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            PathControlView(url: journalDirectoryURL, clickToReveal: false)
                                .fixedSize()
                            Button("Open in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([journalDirectoryURL])
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Show/hide the Location row without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.journalEnabled)
    }

    /// The fixed journal directory in Application Support — read-only, revealed via Finder.
    private var journalDirectoryURL: URL { UsageJournal.defaultDirectory }
}
