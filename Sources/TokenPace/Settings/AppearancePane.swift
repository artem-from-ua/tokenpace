import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0042)

/// Settings → Appearance: the menu-bar widget options in a "Menu Bar Widget" section, plus a
/// "Dropdown" section for popup-only options (the per-model limits toggle, #211).
struct AppearancePane: View {
    @Bindable var model: SettingsModel

    /// Ephemeral "copied!" feedback for the config-copy button (#257): the glyph flips to a checkmark
    /// per ``CopyFeedback``, the shared spec the Troubleshoot window's copy button also follows, so
    /// both copy affordances behave identically. Local `@State` rather than model state: throwaway UI
    /// feedback, not configuration. The clipboard is invisible, so without it there is no sign the
    /// click did anything.
    @State private var didCopyConfig = false
    /// The in-flight reset back to the copy glyph, cancelled and restarted on each click so rapid
    /// clicks don't let an earlier timer clear the checkmark early.
    @State private var copyFeedbackTask: Task<Void, Never>?

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
                        copyConfigButton
                        SegmentedControl(
                            segments: AppearancePreset.allCases.map {
                                .init(value: AppearancePreset?.some($0), title: $0.displayName)
                            } + [.init(value: AppearancePreset?.none, title: "Custom", selectable: false,
                                       inactiveHelp: "Change any option below to craft your own custom setup.")],
                            active: model.activePreset,
                            onSelect: { picked in if let preset = picked { model.apply(preset) } })
                    }
                    SettingsHint(text: "Set all the options below at once. Pick one of three, from "
                        + "calmest to loudest: *highlight only critical states* → *also nudge you "
                        + "when you're underpacing* → *show every indicator*.")
                    SettingsHint(text: "This overwrites your current choices.", warning: true)
                }
            }

            // Bar presentation style (#224, rescaled in #307) + far-behind (green→blue) threshold (#224) —
            // both govern the pacing bars across BOTH surfaces, so they share one header-less section
            // rather than sitting in two adjacent bordered cards. "Bar style": both modes show pacing by
            // colour, but on different scales — Progress marks positions in the window, Pressure measures
            // the gap against the time left. "Far behind pace interval": how big a surplus turns the
            // behind side blue.
            // The case names are the pre-#307 ones (`.simple`/`.pacing`) — see `BarStyle` for why the
            // raw values were kept when the UI names changed.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bar style")
                        Spacer()
                        SegmentedControl(
                            segments: [
                                .init(value: BarStyle.simple, title: "Pressure"),
                                .init(value: BarStyle.mixed, title: "Mixed"),
                                .init(value: BarStyle.pacing, title: "Progress"),
                            ],
                            active: model.barStyle,
                            onSelect: { model.setBarStyle($0) })
                    }
                    SettingsHint(text: "*Progress* puts two marks on the window: where you are in "
                        + "time, and how much you have spent.")
                    SettingsHint(text: "*Pressure* fills the bar as your spending closes on the time "
                        + "left before the reset — a full bar means the gap is wider than the time "
                        + "remaining.")
                    SettingsHint(text: "*Mixed* keeps the compact menu-bar bar as *Pressure* and shows "
                        + "*Progress* in the dropdown.")
                }

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
                    SettingsHint(text: "How much of a surplus separates \"on-pace\" green from "
                        + "\"far-behind\" blue. A larger interval needs a bigger surplus before a bar "
                        + "turns blue.")
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
                    SettingsHint(text: "Which calm colors mute to a neutral white. Orange/red warnings "
                        + "always stay colored.")
                }

                // Awaiting-input in the menu bar (#233). The popup always shows the indicator while the
                // feature is on; this adds the menu-bar copy (a leading hand icon). Meaningful only
                // while the master toggle in Extra features is on, so it's disabled — with a ⚠️ hint —
                // otherwise. A data stub is a third state: the watcher never runs, so the hint says so.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show awaiting-input icon in the menu bar", isOn: Binding(
                        get: { model.awaitingInputInMenuBar },
                        set: { model.setAwaitingInputInMenuBar($0) }))
                    .disabled(!model.awaitingInputEnabled)
                    SettingsHint(text: awaitingInputHint, warning: awaitingInputHintIsWarning)
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

                Toggle("Show extra-usage credits icon", isOn: Binding(
                    get: { model.showExtraUsage }, set: { model.setShowExtraUsage($0) }))

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

                Toggle("Show service status dot on issues", isOn: Binding(
                    get: { model.showServiceDot }, set: { model.setShowServiceDot($0) }))
            }

            // #211 — a popup-only option, so it lives in its own "Dropdown Widget" section rather than
            // in "Menu Bar Widget" above (whose toggles all govern the menu-bar widget).
            Section("Dropdown Widget") {
                // No `SettingsHint` under either row: the segment labels ("Always" / "Non-calm only" /
                // "With ⌥ Option") already say when the group shows, and a hint repeating that would
                // crowd two rows that sit directly above the plain "Show ticks" toggle.
                HStack {
                    Text("Show model & service limits")
                    Spacer()
                    SegmentedControl(
                        segments: Self.visibilitySegments,
                        active: model.modelLimitsVisibility,
                        onSelect: { model.setModelLimitsVisibility($0) })
                }

                HStack {
                    Text("Show extra usage")
                    Spacer()
                    SegmentedControl(
                        segments: Self.visibilitySegments,
                        active: model.extraUsageVisibility,
                        onSelect: { model.setExtraUsageVisibility($0) })
                }

                Toggle("Show ticks on bars", isOn: Binding(
                    get: { model.showTicks }, set: { model.setShowTicks($0) }))
            }
        }
        .formStyle(.grouped)
    }

    /// The three ``PopupSectionVisibility`` segments, shared by both Dropdown-Widget rows so they can
    /// never drift apart. Labels are deliberately terse — three segments plus a full-width row title
    /// leave no room for prose, which lives in each row's `SettingsHint` instead.
    private static let visibilitySegments: [SegmentedControl<PopupSectionVisibility>.Segment] =
        PopupSectionVisibility.allCases.map { .init(value: $0, title: $0.displayName) }

    // MARK: Copy config (#257)

    /// The copy-to-clipboard button sitting immediately **left of** the preset segmented control:
    /// it puts the twelve Appearance values (plus the active preset and app version) on the clipboard
    /// as pretty-printed JSON, so "what does your setup look like?" is one click instead of a
    /// screenshot tour of the pane.
    ///
    /// `doc.on.doc` is the same glyph as the Troubleshoot window's copy button, keeping one visual
    /// vocabulary for "copy" across the app — a share icon would promise a share sheet that isn't
    /// there. The hint rides as a native tooltip rather than a `SettingsHint` row: the preset row
    /// already carries two hint lines explaining the presets, and a third would crowd them.
    private var copyConfigButton: some View {
        Button {
            copyConfigToClipboard()
        } label: {
            Image(systemName: didCopyConfig ? CopyFeedback.confirmedSymbol : CopyFeedback.restingSymbol)
                // A fixed width keeps the segmented control from shifting sideways when the glyph
                // swaps to the (narrower) checkmark and back.
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help("Copy \(Self.copyTarget) to the clipboard")
        .accessibilityLabel(didCopyConfig
            ? CopyFeedback.confirmedLabel
            : CopyFeedback.restingLabel(Self.copyTarget))
    }

    /// What this button copies — used in the tooltip and the accessibility label.
    private static let copyTarget = "Appearance settings"

    /// Write the model's JSON dump to the general pasteboard and show the checkmark. The pasteboard
    /// write lives here rather than in `SettingsModel` so the model stays free of AppKit.
    private func copyConfigToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.appearanceConfigJSON(), forType: .string)
        AppLogger.ui.notice("appearance config copied to clipboard")

        didCopyConfig = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(CopyFeedback.duration))
            guard !Task.isCancelled else { return }
            didCopyConfig = false
        }
    }

    /// The hint under the awaiting-input menu-bar toggle, in priority order: the master toggle is off
    /// (nothing to place anywhere) → a stub is driving the app (the watcher doesn't run at all) → the
    /// plain description. The first two are ⚠️ states; see ``awaitingInputHintIsWarning``.
    private var awaitingInputHint: String {
        guard model.awaitingInputEnabled else {
            return "Enable *Show sessions awaiting input* in Extra features first."
        }
        if model.stubScenarioActive { return ExtraFeaturesPane.stubbedHint }
        return "Adds a hand icon to the menu bar (leading) when sessions are waiting. "
            + "The count is shown only in the dropdown."
    }

    private var awaitingInputHintIsWarning: Bool {
        !model.awaitingInputEnabled || model.stubScenarioActive
    }
}
