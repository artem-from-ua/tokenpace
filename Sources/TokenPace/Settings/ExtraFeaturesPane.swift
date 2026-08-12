import SwiftUI
import TokenPaceKit

// MARK: - ExtraFeaturesPane (#168, ADR-0042)

/// Settings → Extra features: opt-in extras grouped in one pane —
/// - **Monitored services** — which Claude services feed the menu-bar status (#89, ADR-0024).
/// - **Sessions backup** — the raw-log archiver (#110, ADR-0031): enable, destination, Archive Now.
/// - **Session status** — the "sessions awaiting input" feature's own switch (#233, ADR-0066). It is
///   what makes the count appear in the dropdown; whether the *menu bar* also carries it is a
///   menu-bar concern and lives on that pane.
///
/// This pane is being retired (#317). **Usage history** has already left for General — the journal
/// is an app-wide feature, not a provider's. The three sections above go to Providers next, and the
/// pane disappears with them.
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
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
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
                        // empty, so no conditional is needed. Both carry ⚠️: a hint that reports a
                        // condition holding the feature back is a warning, whatever clears it — the
                        // neutral (icon-less) style is reserved for describing what a control does.
                        SettingsHint(text: model.archiveSpaceHint, warning: true)
                        SettingsHint(text: model.archiveBatteryHint, warning: true)
                    }
                }
            }

            // MARK: Session status (moved from General)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show sessions awaiting input", isOn: Binding(
                        get: { model.awaitingInputEnabled },
                        set: { model.setAwaitingInputEnabled($0) }))
                    SettingsHint(text: "Shows how many Claude Code sessions are waiting for your reply "
                        + "in the dropdown. Whether it also appears in the menu bar is configured in "
                        + "*Menu bar*.")
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
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
            }

        }
        .formStyle(.grouped)
        // Show/hide the dependent rows without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.archiveEnabled)
        .animation(nil, value: model.webDesktopEnabled)
    }

    private var archiveDestinationURL: URL? {
        guard let path = model.archiveDestination else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
