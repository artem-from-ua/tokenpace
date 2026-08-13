import SwiftUI
import TokenPaceKit

// MARK: - ProvidersPane (#341, ADR-0084/0085)

/// Settings → Providers: what TokenPace collects and watches, per provider.
///
/// The page replaces `Extra features` (#341), which had no organising principle — it was where
/// things went when they fit nowhere else, and it had no axis along which to grow for a second
/// provider. This one does: each provider is a row that drills into its own page, so adding Codex
/// adds a row rather than a rethink.
///
/// The sections **below** the provider list stay on this parent page because they belong to no
/// single provider: awaiting-input reads local Claude Code state and would apply to any provider
/// with a local client, the incident age cut-off filters the popup for every service at once, and
/// there is one archiver. Pushing them down into `Claude` would claim a per-provider granularity
/// that does not exist.
struct ProvidersPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            // MARK: Providers
            Section("Providers") {
                SettingsNavigationRow(
                    title: "Claude",
                    subtitle: model.claudeProviderSummary,
                    action: { model.drill(into: .providersClaude) })
            }

            // MARK: Sessions (spans providers — reads the local client's state)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    // "Detect", not "Show": this switch turns the **feature** on — the watcher that
                    // reads the local client's session files. Where the result appears is a separate
                    // question, answered by the Menu bar page's own row (#341). Naming both "Show …"
                    // made them look like the same switch listed twice.
                    Toggle("Detect sessions waiting for input", isOn: Binding(
                        get: { model.awaitingInputEnabled },
                        set: { model.setAwaitingInputEnabled($0) }))
                    SettingsHint(text: "Finds sessions that asked you something and are waiting for "
                        + "an answer.")
                }
            } header: {
                // The watcher is gated on the real network: a stub is a frozen frame, and reading the
                // live ~/.claude trees would let real waiting sessions leak into it. `TOKENPACE_AWAITING=N`
                // exercises the indicator with synthetic sessions instead.
                // "Sessions", not "Session status": the neighbouring sections watch a status **page**,
                // and reusing that word here pointed the reader at the wrong subsystem.
                SectionHeaderWithHint(title: "Sessions",
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
            }

            // MARK: Incidents (one threshold for every monitored service)
            Section("Incidents") {
                // #279: the incident age cut-off filters what the *popup shows*, not what gets
                // delivered — which is why it sits with the display settings rather than with the
                // notification toggles. It applies to every provider's services at once, so it stays
                // on this page rather than following the service switches into `Claude`.
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
            }

            // MARK: Sessions backup
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
        }
        .formStyle(.grouped)
        // Show/hide the dependent rows without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.archiveEnabled)
    }

    private var archiveDestinationURL: URL? {
        guard let path = model.archiveDestination else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
