import SwiftUI
import TokenPaceKit

// MARK: - ProvidersClaudePane (#341, ADR-0084/0085)

/// Settings → Providers › Claude: the two things TokenPace does for Claude, kept apart.
///
/// **Usage** is the poll behind the bars. **Monitored services** is incident watching on the status
/// page. The page exists to make that distinction visible: before #341 the two were entangled in one
/// row reading "Claude API — always monitored", which conflated "we watch this service for outages"
/// with "our own data collection depends on this endpoint".
///
/// There is no provider-level master switch. It would have to mean one of the two things above, and
/// whichever it meant, the other would be the surprise.
struct ProvidersClaudePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            // MARK: Token limits usage — the data behind the bars
            Section("Token limits usage") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Claude Usage API", isOn: Binding(
                        get: { model.usageApiEnabled },
                        set: { model.usageApiEnabled = $0; model.commitProviderMonitoring() }))
                    SettingsHint(
                        text: "Polls Claude's usage API for your limits. This is what the bars show.")
                    // ⚠️ because it reports a condition holding a feature back, the same class as the
                    // Sessions-backup hints (#306). It appears only while the switch is off: with it
                    // on there is nothing being withheld to warn about.
                    if !model.usageApiEnabled {
                        SettingsHint(
                            text: "With this off there is no usage data, so the menu bar shows no bars "
                                + "— only the status of the services below.",
                            warning: true)
                    }
                }
            }

            // MARK: Monitored services — incident watching
            Section {
                // Claude API has no switch of its own: it is on whenever anything else is, because
                // the usage poll talks to it and the other services are unreadable without it. Shown
                // as a locked-on toggle plus a muted note saying *why* — a disabled control with no
                // explanation reads as a bug. It is derived, never persisted (`claudeApiLocked`).
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(model.claudeApiLocked ? "required by the above" : "nothing to monitor")
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: .constant(model.claudeApiLocked))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(true)
                    }
                } label: {
                    Text("Claude API")
                }

                Toggle("Claude Code", isOn: Binding(
                    get: { model.claudeCodeEnabled },
                    set: { model.claudeCodeEnabled = $0; model.commitProviderMonitoring() }))

                Toggle("Claude Web / Desktop", isOn: Binding(
                    get: { model.webDesktopEnabled },
                    set: { model.webDesktopEnabled = $0; model.commitProviderMonitoring() }))

                if model.webDesktopEnabled {
                    HStack {
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.webDesktopMode },
                            set: { model.webDesktopMode = $0; model.commitProviderMonitoring() })) {
                            Text("Chat only").tag(WebDesktopMode.chatOnly)
                            Text("Chat and Cowork").tag(WebDesktopMode.chatAndCowork)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } header: {
                // Under a data stub the status page is never fetched — the stub transport answers the
                // status endpoint too, so the switches below pick between canned components (#187). The
                // caveat covers the whole section, so it rides the *header*: directly under the title
                // and outside the grouped card, rather than as a row among the switches.
                SectionHeaderWithHint(title: "Monitored services",
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
            }
        }
        .formStyle(.grouped)
        // Show/hide the dependent rows without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.webDesktopEnabled)
        .animation(nil, value: model.usageApiEnabled)
    }
}
