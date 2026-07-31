import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0042)

/// Settings → Appearance: the menu-bar widget options in a "Menu Bar Widget" section, plus a
/// "Dropdown" section for popup-only options (the per-model limits toggle, #211).
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

                // #199 — placed second by request. Independent of the pacing-bars toggle below: the
                // glyph shows whenever fully blocked, before the bars or before the countdown.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show pause icon when fully blocked", isOn: Binding(
                        get: { model.showBlockedPause }, set: { model.setShowBlockedPause($0) }))
                    SettingsHint(text: "When every limit is exhausted and extra-usage credits can't "
                        + "cover, an orange pause icon appears at the left of the menu-bar widget — "
                        + "before the pacing bars, or before the reset countdown when the bars are hidden.")
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

                // Shown to the user as "Show pacing bars when 5h/7d limits reached" — the inverse of
                // the stored `hideBarsWhenBlocked` flag (off by default = bars hidden when blocked,
                // #194 behaviour preserved).
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show pacing bars when 5h/7d limits reached", isOn: Binding(
                        get: { !model.hideBarsWhenBlocked }, set: { model.setHideBarsWhenBlocked(!$0) }))
                    SettingsHint(text: "When a 5-hour or 7-day limit is exhausted, keep both full (red) "
                        + "bars visible. Off collapses to just the countdown to the reset, since a full "
                        + "red bar shows nothing you can act on. The popup always shows the full bars.")
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
                    Toggle("Show model-specific limits", isOn: Binding(
                        get: { model.showModelSpecificLimits },
                        set: { model.setShowModelSpecificLimits($0) }))
                    SettingsHint(text: "Shows separate 7-day limit rows per model (Opus, Sonnet, "
                        + "Fable…) in the dropdown, below the 5-hour and 7-day rows. Off keeps only "
                        + "the 5-hour and 7-day limits.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
