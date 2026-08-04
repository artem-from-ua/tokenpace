import SwiftUI
import TokenPaceKit

// MARK: - ExtraFeaturesPane (#168, ADR-0042)

/// Settings → Extra features: opt-in extras grouped in one pane —
/// - **Monitored services** — which Claude services feed the menu-bar status (#89, ADR-0024).
/// - **Sessions backup** — the raw-log archiver (#110, ADR-0031): enable, destination, Archive Now.
/// - **Session status** — the "sessions awaiting input" indicator (#233, ADR-0066), moved here from
///   General (its placement is still configured in Appearance).
/// - **Usage history** — the usage journal collector (#242, ADR-0067): enable, plus a read-only
///   destination the user can reveal in Finder but not change (the file lives in Application Support).
struct ExtraFeaturesPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            // MARK: Monitored services (was its own sidebar pane)
            Section("Monitored services") {
                // Claude API is always monitored — a disabled on-switch + a muted trailing note. It is
                // not part of the persisted MonitoredServices; it never participates in a commit.
                LabeledContent {
                    HStack(spacing: 8) {
                        Text("always monitored").foregroundStyle(.secondary)
                        Toggle("", isOn: .constant(true))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(true)
                    }
                } label: {
                    Text("Claude API")
                }

                Toggle("Claude Code", isOn: Binding(
                    get: { model.claudeCodeEnabled },
                    set: { model.claudeCodeEnabled = $0; model.commitMonitoredServices() }))

                Toggle("Claude Web / Desktop", isOn: Binding(
                    get: { model.webDesktopEnabled },
                    set: { model.webDesktopEnabled = $0; model.commitMonitoredServices() }))

                if model.webDesktopEnabled {
                    HStack {
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.webDesktopMode },
                            set: { model.webDesktopMode = $0; model.commitMonitoredServices() })) {
                            Text("Chat only").tag(WebDesktopMode.chatOnly)
                            Text("Chat and Cowork").tag(WebDesktopMode.chatAndCowork)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            // MARK: Sessions backup (was "Session Logs")
            Section("Sessions backup") {
                Toggle("Archive session logs daily", isOn: Binding(
                    get: { model.archiveEnabled },
                    set: { model.setArchiveEnabled($0) }))

                // Destination + status are only relevant once archiving is on — hidden otherwise.
                if model.archiveEnabled {
                    LabeledContent("Destination") {
                        HStack(spacing: 8) {
                            PathControlView(url: archiveDestinationURL)
                            Button("Choose…") { model.chooseArchiveFolder() }
                        }
                    }

                    LabeledContent {
                        Button("Archive Now") { model.archiveNow() }
                            .disabled(model.archiveDestination == nil)
                    } label: {
                        Text(model.archiveStatusText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // MARK: Session status (moved from General)
            Section("Session status") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show sessions awaiting input", isOn: Binding(
                        get: { model.awaitingInputEnabled },
                        set: { model.setAwaitingInputEnabled($0) }))
                    SettingsHint(text: "Shows how many Claude Code sessions are waiting for your reply. Configure where it appears in Appearance.")
                }
            }

            // MARK: Usage history (usage journal collector, #242)
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
        // Show/hide the dependent rows without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.archiveEnabled)
        .animation(nil, value: model.journalEnabled)
        .animation(nil, value: model.webDesktopEnabled)
    }

    private var archiveDestinationURL: URL? {
        guard let path = model.archiveDestination else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The fixed journal directory in Application Support — read-only, revealed via Finder.
    private var journalDirectoryURL: URL { UsageJournal.defaultDirectory }
}
