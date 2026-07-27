import SwiftUI

// MARK: - GeneralPane (#168, ADR-0041)

/// Settings → General: launch-at-login and screen-lock polling pause.
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
        }
        .formStyle(.grouped)
    }
}
