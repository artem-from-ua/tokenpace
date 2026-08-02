import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0042)

/// Settings → Appearance: the menu-bar widget options in a "Menu Bar Widget" section, plus a
/// "Dropdown" section for popup-only options (the per-model limits toggle, #211).
struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            // First section: a one-click revert of every Appearance setting to its factory default.
            // The button is trailing-aligned (label left, control right — the standard Form row shape).
            Section {
                HStack {
                    Text("Revert appearance settings to default")
                    Spacer()
                    Button("Reset") { model.resetAppearanceToDefaults() }
                }
            }

            Section("Menu Bar Widget") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Calm non-critical colors", isOn: Binding(
                        get: { model.calmColors }, set: { model.setCalmColors($0) }))
                    SettingsHint(text: "Keeps the menu bar quiet — only orange/red warnings are "
                        + "colored; on-pace and mild states stay a neutral white.")
                }

                // #199 — placed second by request. Independent of the pacing-bars toggle below: the
                // glyph shows whenever fully blocked, before the bars or before the countdown.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show pause icon when fully blocked", isOn: Binding(
                        get: { model.showBlockedPause }, set: { model.setShowBlockedPause($0) }))
                    SettingsHint(text: "An orange pause icon when every limit is exhausted and "
                        + "extra-usage credits can't cover.")
                }

                // Shown to the user as "Show 7-day bar when calm" — the inverse of the stored
                // `hideCalmSevenDay` flag (off by default = the calm 7-day bar is hidden by default).
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show 7-day bar when calm", isOn: Binding(
                        get: { !model.hideCalmSevenDay }, set: { model.setHideCalmSevenDay(!$0) }))
                    SettingsHint(text: "Off hides the 7-day bar while it's calm, bringing it back "
                        + "when it turns orange or red.")
                }

                // Shown to the user as "Show pacing bars when 5h/7d limits reached" — the inverse of
                // the stored `hideBarsWhenBlocked` flag (off by default = bars hidden when blocked,
                // #194 behaviour preserved).
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show pacing bars when 5h/7d limits reached", isOn: Binding(
                        get: { !model.hideBarsWhenBlocked }, set: { model.setHideBarsWhenBlocked(!$0) }))
                    SettingsHint(text: "Off shows just the reset countdown when a 5-hour or 7-day "
                        + "limit is exhausted.")
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

            // #211 — a popup-only option, so it lives in its own "Dropdown" section rather than in
            // "Menu Bar Widget" above (whose toggles all govern the menu-bar widget).
            Section("Dropdown") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show model & service limits", isOn: Binding(
                        get: { model.showModelSpecificLimits },
                        set: { model.setShowModelSpecificLimits($0) }))
                    SettingsHint(text: "Adds per-model or per-service 7-day rows. Off keeps only "
                        + "5-hour and 7-day base limits.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
