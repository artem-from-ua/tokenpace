import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0041)

/// Settings → Appearance: the menu-bar widget toggles + the "Show Reset Countdown in Menu Bar" mode.
struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Calm menu-bar widget colors", isOn: Binding(
                    get: { model.calmColors }, set: { model.setCalmColors($0) }))
                Toggle("Hide 7-day bar when calm", isOn: Binding(
                    get: { model.hideCalmSevenDay }, set: { model.setHideCalmSevenDay($0) }))
                Toggle("Show extra-usage credits icon", isOn: Binding(
                    get: { model.showExtraUsage }, set: { model.setShowExtraUsage($0) }))
                Toggle("Show service status dot on issues", isOn: Binding(
                    get: { model.showServiceDot }, set: { model.setShowServiceDot($0) }))
            }

            Section("Show Reset Countdown in Menu Bar") {
                Picker("", selection: Binding(
                    get: { model.resetRadio },
                    set: { model.resetRadio = $0; model.commitResetCountdownMode() })) {
                    Text("Always").tag(ResetRadio.always)
                    Text("When well ahead or limit reached").tag(ResetRadio.smart)
                    Text("Never").tag(ResetRadio.never)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Toggle("Include distant 7-day limit reset (≥ 24 h away)", isOn: Binding(
                    get: { model.includeDistant7d },
                    set: { model.includeDistant7d = $0; model.commitResetCountdownMode() }))
                .disabled(!model.includeDistantEnabled)
                .padding(.leading, 18)
            }
        }
        .formStyle(.grouped)
    }
}
