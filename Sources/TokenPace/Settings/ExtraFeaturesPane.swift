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
            Section {
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

                // #279: the incident age cut-off lives here rather than with the notification
                // toggles, because it filters what the *popup shows*, not what gets delivered. The
                // service filter it pairs with is the set of switches directly above — Monitored
                // services now decides which incidents are yours as well as which rows are drawn.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Hide incidents older than")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.incidentMaxAgeHours },
                            set: { model.setIncidentMaxAgeHours($0) })) {
                            Text("12 hours").tag(12)
                            Text("24 hours").tag(24)
                            Text("3 days").tag(72)
                            Text("No limit").tag(0)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsHint(
                        text: "Some incidents stay open for days after the services behind them "
                            + "recovered. This keeps those out of the popup.")
                }
            } header: {
                // Under a data stub the status page is never fetched — the stub transport answers the
                // status endpoint too, so the switches below pick between canned components (#187). The
                // caveat covers the whole section, so it rides the *header*: directly under the title
                // and outside the grouped card, rather than as a row among the switches.
                SectionHeaderWithHint(title: "Monitored services",
                                      hint: model.stubScenarioActive ? Self.stubbedHint : nil)
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

                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent {
                            Button("Archive Now") { model.archiveNow() }
                                .disabled(model.archiveDestination == nil)
                        } label: {
                            Text(model.archiveStatusText)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Why a backup isn't happening (#306). Both hints vanish when their string is
                        // empty, so no conditional is needed. The space line warns — a full disk needs
                        // the user to act; the battery line stays neutral, because it clears itself.
                        SettingsHint(text: model.archiveSpaceHint, warning: true)
                        SettingsHint(text: model.archiveBatteryHint)
                    }
                }
            }

            // MARK: Session status (moved from General)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show sessions awaiting input", isOn: Binding(
                        get: { model.awaitingInputEnabled },
                        set: { model.setAwaitingInputEnabled($0) }))
                    SettingsHint(text: "Shows how many Claude Code sessions are waiting for your reply. Configure where it appears in Appearance.")
                    // Unlike the stub caveat in the header, this one is unconditional: the feature
                    // reads Claude Code's private state files (ADR-0066), so the fragility is a
                    // permanent property of it rather than a state we detect. Declaring it here is
                    // what we do instead of failing loudly on an unparseable format (#243).
                    SettingsHint(text: "Experimental. This reads Claude Code's internal files, which are "
                        + "undocumented and may be changed on Anthropic's side at any time. If that happens, "
                        + "the count may stop appearing and disappearing properly.", warning: true)
                }
            } header: {
                // The watcher is gated on the real network: a stub is a frozen frame, and reading the
                // live ~/.claude trees would let real waiting sessions leak into it. `TOKENPACE_AWAITING=N`
                // exercises the indicator with synthetic sessions instead. Same header treatment as above.
                SectionHeaderWithHint(title: "Session status",
                                      hint: model.stubScenarioActive ? Self.stubbedHint : nil)
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

    /// The ⚠️ line shown under any section whose data is canned by a `TOKENPACE_STUB` scenario. Shared
    /// with `AppearancePane` so the wording stays identical across panes.
    static let stubbedHint = "Stubbed in this development build."

    private var archiveDestinationURL: URL? {
        guard let path = model.archiveDestination else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The fixed journal directory in Application Support — read-only, revealed via Finder.
    private var journalDirectoryURL: URL { UsageJournal.defaultDirectory }
}
