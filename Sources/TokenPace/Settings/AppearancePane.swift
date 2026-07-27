import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0041)

/// Settings → Appearance: the menu-bar widget options, in one "Menu Bar" section.
struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Menu Bar Widget") {
                Toggle("Calm non-critical colors", isOn: Binding(
                    get: { model.calmColors }, set: { model.setCalmColors($0) }))
                // Shown to the user as "Show 7-day bar when calm" — the inverse of the stored
                // `hideCalmSevenDay` flag (off by default = the calm 7-day bar is hidden by default).
                Toggle("Show 7-day bar when calm", isOn: Binding(
                    get: { !model.hideCalmSevenDay }, set: { model.setHideCalmSevenDay(!$0) }))

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
