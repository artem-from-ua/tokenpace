import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0042)

/// Settings → Appearance: the menu-bar widget options in a "Menu Bar Widget" section, plus a
/// "Dropdown" section for popup-only options (the per-model limits toggle, #211).
struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            // First section: one-click Appearance presets (#215, #224) — a "Change UI preset" segmented
            // control. Selecting Chill / Work harder! / Control freak applies that preset (sets every
            // option below at once). The trailing "Custom" segment is an **indicator**, not a choice:
            // its selection is ignored, and it lights up only when the live config matches no preset —
            // i.e. after any manual toggle. `model.activePreset` is nil in that Custom state.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    // Label + control on ONE row (label leading, control trailing — the pane's rhythm),
                    // then the two hints below (leading). A custom SegmentedControl (not the native
                    // Picker) so the trailing "Custom" segment can be an indicator that lights up but is
                    // not selectable; clicking it opens a popover explaining how to reach it.
                    HStack {
                        Text("Change UI preset")
                        Spacer()
                        SegmentedControl(
                            segments: AppearancePreset.allCases.map {
                                .init(value: AppearancePreset?.some($0), title: $0.displayName)
                            } + [.init(value: AppearancePreset?.none, title: "Custom", selectable: false,
                                       inactiveHelp: "Change any option below to craft your own custom setup.")],
                            active: model.activePreset,
                            onSelect: { picked in if let preset = picked { model.apply(preset) } })
                    }
                    SettingsHint(text: "Sets all the options below at once. Pick one of three, from "
                        + "calmest to loudest: *highlight only critical states* → *also nudge you "
                        + "when you're underpacing* → *show every indicator*.")
                    SettingsHint(text: "This overwrites your current choices.", warning: true)
                }
            }

            // Bar presentation style (#224) — a segmented control governing BOTH the menu-bar widget and
            // the dropdown popup. Its own section (no header) because it spans both surfaces. Both modes
            // show pacing by colour; "Pace & Time" additionally marks where you are in the window.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bar style")
                        Spacer()
                        SegmentedControl(
                            segments: [
                                .init(value: BarStyle.simple, title: "Pace"),
                                .init(value: BarStyle.mixed, title: "Mixed"),
                                .init(value: BarStyle.pacing, title: "Pace & Time"),
                            ],
                            active: model.barStyle,
                            onSelect: { model.setBarStyle($0) })
                    }
                    SettingsHint(text: "*Pace* shows a colour ribbon from the left; *Pace & Time* adds "
                        + "the time marker. Both use the same state color and ribbon size.")
                    SettingsHint(text: "*Mixed* keeps the compact menu-bar bar as *Pace* and shows "
                        + "*Pace & Time* in the dropdown.")
                }
            }

            // Far-behind (green→blue) threshold (#224) — how big a surplus turns the behind side blue.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Far behind pace interval")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.farBehindInterval },
                            set: { model.setFarBehindInterval($0) })) {
                            Text("1h on the 5-hour bar; 1d on the 7-day bar").tag(FarBehindInterval.short)
                            Text("2h on the 5-hour bar; 2d on the 7-day bar").tag(FarBehindInterval.medium)
                            Text("3h on the 5-hour bar; 3d on the 7-day bar").tag(FarBehindInterval.long)
                            Text("Less blue, please!").tag(FarBehindInterval.off)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsHint(text: "How much of a surplus tells apart \"on-pace\" green from "
                        + "\"far-behind\" blue. Larger needs a bigger surplus before a bar turns blue.")
                }
            }

            Section("Menu Bar Widget") {
                // Calm non-critical colors (#224) — a three-way choice (merged the old Calm + Work
                // harder toggles): which calm colours mute to white. "Yellow + Green + Blue" is
                // disabled when there is no blue to mute (Far behind = "Less blue, please!"), with a
                // popover explaining why — mirroring the preset "Custom" indicator.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Calm non-critical colors")
                        Spacer()
                        SegmentedControl(
                            segments: [
                                .init(value: CalmColorMode.off, title: "Off"),
                                .init(value: CalmColorMode.yellowGreen, title: "Yellow + Green"),
                                .init(value: CalmColorMode.yellowGreenBlue, title: "+ Blue",
                                      selectable: model.farBehindInterval != .off,
                                      inactiveHelp: model.farBehindInterval == .off
                                        ? "There's no blue to mute while *Far behind pace interval* is "
                                          + "*Less blue, please!*. Pick an interval first."
                                        : nil),
                            ],
                            active: model.calmColorMode,
                            onSelect: { model.setCalmColorMode($0) })
                    }
                    SettingsHint(text: "Which calm colours mute to a neutral white. Orange/red warnings "
                        + "always stay coloured.")
                }

                // #194, #227 — the single "blocked" control. When fully blocked a red pause icon is
                // always shown; this toggle only decides whether it hides the bars or keeps them beside it.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Pause icon hides bars", isOn: Binding(
                        get: { model.pauseHidesBars }, set: { model.setPauseHidesBars($0) }))
                    SettingsHint(text: "When every limit is exhausted and extra-usage credits can't "
                        + "cover, a red pause icon appears. On shows only the icon and the reset "
                        + "countdown; off keeps the pacing bars beside it.")
                }

                // Shown to the user as "Show 7-day bar when calm" — the inverse of the stored
                // `hideCalmSevenDay` flag (off by default = the calm 7-day bar is hidden by default).
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show 7-day bar when calm", isOn: Binding(
                        get: { !model.hideCalmSevenDay }, set: { model.setHideCalmSevenDay(!$0) }))
                    SettingsHint(text: "Off hides the 7-day bar while it's calm, bringing it back "
                        + "when it turns orange or red.")
                }

                // Reset-countdown mode: a segmented control matching the pane's other three-way rows,
                // with the "Smart" behaviour explained on the line below.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Show reset countdown")
                        Spacer()
                        SegmentedControl(
                            segments: [
                                .init(value: ResetRadio.always, title: "Always"),
                                .init(value: ResetRadio.smart, title: "Smart"),
                                .init(value: ResetRadio.never, title: "Never"),
                            ],
                            active: model.resetRadio,
                            onSelect: { model.resetRadio = $0; model.commitResetCountdownMode() })
                    }
                    SettingsHint(text: "*Smart* shows the countdown only when you're pacing well ahead "
                        + "or a limit is reached.")
                }

                Toggle("Show extra-usage credits icon", isOn: Binding(
                    get: { model.showExtraUsage }, set: { model.setShowExtraUsage($0) }))
                Toggle("Show service status dot on issues", isOn: Binding(
                    get: { model.showServiceDot }, set: { model.setShowServiceDot($0) }))
            }

            // #211 — a popup-only option, so it lives in its own "Dropdown Widget" section rather than
            // in "Menu Bar Widget" above (whose toggles all govern the menu-bar widget).
            Section("Dropdown Widget") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show model & service limits", isOn: Binding(
                        get: { model.showModelSpecificLimits },
                        set: { model.setShowModelSpecificLimits($0) }))
                    SettingsHint(text: "Adds per-model or per-service 7-day rows. Off keeps only "
                        + "5-hour and 7-day base limits.")
                }

                Toggle("Show ticks on bars", isOn: Binding(
                    get: { model.showTicks }, set: { model.setShowTicks($0) }))
            }
        }
        .formStyle(.grouped)
    }
}
