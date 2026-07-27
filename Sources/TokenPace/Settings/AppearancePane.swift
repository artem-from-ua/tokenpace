import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0041)

/// Settings → Appearance: the menu-bar widget options, in one "Menu Bar" section.
struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Menu Bar Widget") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Calm non-critical colors", isOn: Binding(
                        get: { model.calmColors }, set: { model.setCalmColors($0) }))
                    SettingsHint(text: "Keeps the menu bar quiet — only orange/red warnings are "
                        + "colored; on-pace and mild states stay a neutral white.")
                }

                // Shown to the user as "Show 7-day bar when calm" — the inverse of the stored
                // `hideCalmSevenDay` flag (off by default = the calm 7-day bar is hidden by default).
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show 7-day bar when calm", isOn: Binding(
                        get: { !model.hideCalmSevenDay }, set: { model.setHideCalmSevenDay(!$0) }))
                    SettingsHint(text: "Keep both bars always visible. Off collapses to just the "
                        + "5-hour bar while the 7-day limit is calm, and brings the 7-day bar back "
                        + "when it turns orange or red.")
                }

                // Reset-countdown mode: a menu picker (like System Settings' few-option choices).
                Picker("Show reset countdown", selection: Binding(
                    get: { model.resetRadio },
                    set: { model.resetRadio = $0; model.commitResetCountdownMode() })) {
                    Text("Always").tag(ResetRadio.always)
                    Text("When pacing well ahead or limit reached").tag(ResetRadio.smart)
                    Text("Never").tag(ResetRadio.never)
                }

                Toggle("Show extra-usage credits icon", isOn: Binding(
                    get: { model.showExtraUsage }, set: { model.setShowExtraUsage($0) }))
                Toggle("Show service status dot on issues", isOn: Binding(
                    get: { model.showServiceDot }, set: { model.setShowServiceDot($0) }))
            }
        }
        .formStyle(.grouped)
    }
}
