import SwiftUI
import TokenPaceKit

// MARK: - MonitoredServicesPane (#168, ADR-0041)

/// Settings → Monitored Services: which Claude services feed the menu-bar status (#89, ADR-0024).
/// Claude API is always monitored (a disabled on-switch); Claude Code and Web/Desktop are optional,
/// the latter with a Chat-only / Chat-and-Cowork sub-mode.
struct MonitoredServicesPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // Claude API is always monitored — a disabled on-switch (a real switch, like the other
                // rows) + a muted trailing note. It is not part of the persisted MonitoredServices; it
                // never participates in a commit.
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

                Toggle("Claude WEB / Desktop", isOn: Binding(
                    get: { model.webDesktopEnabled },
                    set: { model.webDesktopEnabled = $0; model.commitMonitoredServices() }))

                // The sub-mode as its own row — a menu picker with a real label, so Form aligns it like
                // any other row (no hand-tuned indent). Disabled unless Web/Desktop is on.
                Picker("Scope", selection: Binding(
                    get: { model.webDesktopMode },
                    set: { model.webDesktopMode = $0; model.commitMonitoredServices() })) {
                    Text("Chat only").tag(WebDesktopMode.chatOnly)
                    Text("Chat and Cowork").tag(WebDesktopMode.chatAndCowork)
                }
                .disabled(!model.webDesktopRadioEnabled)
            }
        }
        .formStyle(.grouped)
    }
}
