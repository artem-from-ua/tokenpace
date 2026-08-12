import SwiftUI
import TokenPaceKit

// MARK: - AppearancePane (#168, ADR-0042; split into child pages #333, ADR-0082)

/// Settings → Appearance, the **parent** page: what applies to the widget as a whole — the preset
/// picker with its copy-config button, the awaiting-input master switch, and the two navigator rows
/// leading to the per-surface pages.
///
/// The split follows one axis: anything that configures a **single surface** lives on that surface's
/// child page (``AppearanceMenuBarPane`` / ``AppearanceDropdownPane``), anything spanning both stays
/// here. That is why the bar style is *not* here despite looking like one setting — since #329 it is
/// two independent values, one per surface (ADR-0080), so each belongs with its own surface.
///
/// The preset control and the copy button keep working across the split without knowing about it:
/// both read `SettingsModel.liveAppearanceValues`, which reads the model's fields directly rather
/// than anything a view holds.
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
            // option on both child pages at once).
            //
            // The trailing "Custom" segment is a **real slot** since #333, not the pure indicator it
            // was: applying a preset stashes the setup it overwrites, so Custom can restore it. It
            // falls back to indicator-only (unselectable, with a popover explaining how to reach it)
            // while nothing is stashed — a fresh install has nothing to come back to.
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
                            } + [.init(value: AppearancePreset?.none, title: "Custom",
                                       // Selectable once there is a setup to go back to (#333); until
                                       // then it stays the indicator it always was, and explains itself.
                                       selectable: model.canRestoreCustom,
                                       inactiveHelp: "Change any option below to craft your own custom setup.")],
                            active: model.activePreset,
                            onSelect: { picked in
                                if let preset = picked { model.apply(preset) } else { model.applySavedCustom() }
                            })
                    }
                    SettingsHint(text: "Sets all options on the *Menu bar* and *Dropdown* pages.")
                }
            }

            // The two per-surface pages. A section of their own rather than appended to the one above:
            // they are navigation, not settings, and System Settings likewise groups its drill-in rows
            // into their own card.
            Section {
                ForEach(SettingsChildPage.pages(of: .appearance)) { page in
                    SettingsNavigationRow(page: page) { model.drill(into: page) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Copy config (#257)

    /// The copy-to-clipboard button sitting immediately **left of** the preset segmented control:
    /// it puts the Appearance values (plus the active preset and app version) on the clipboard as
    /// pretty-printed JSON, so "what does your setup look like?" is one click instead of a
    /// screenshot tour of the pane — now of three pages, which is what makes it worth more than it
    /// was before the split.
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
}

// MARK: - AppearanceMenuBarPane (#333)

/// Settings → Appearance › Menu bar: everything that configures the **menu-bar widget** — its bar
/// style, which colours it mutes, and which indicators it may draw.
struct AppearanceMenuBarPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // Bar style, menu-bar copy (#224, rescaled in #307, per-surface since #329). All three
                // show the pacing state by colour and differ in *scale*: Progress marks positions in
                // the window, Pressure measures the gap against the time left, Gauge measures the same
                // thing from a centred zero so the underpace side is drawn too. The full explanation
                // lives here; the Dropdown page's copy points back at it rather than repeating it.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bar style")
                        Spacer()
                        SegmentedControl(
                            segments: AppearanceBarStyle.segments,
                            active: model.menuBarStyle,
                            onSelect: { model.setMenuBarStyle($0) })
                    }
                    SettingsHint(text: "*Progress* puts two marks on the window: where you are in "
                        + "time, and how much you have spent.")
                    SettingsHint(text: "*Pressure* grows as you get ahead of pace and shrinks back "
                        + "as time catches up. The tick marks exactly on pace; a full bar means the "
                        + "limit is spent.")
                    SettingsHint(text: "*Gauge* starts from the middle: it grows right as you get "
                        + "ahead of pace and left as you fall behind, so the quota you are not "
                        + "getting to spend shows up too.")
                }

                // Calm non-critical colors (#224) — a three-way choice (merged the old Calm + Work
                // harder toggles): which calm colours mute to white. Every segment is always
                // selectable: the far-behind blue can no longer be switched off, so there is no state
                // where "+ Blue" would have nothing to mute.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Calm non-critical colors")
                        Spacer()
                        SegmentedControl(
                            segments: [
                                .init(value: CalmColorMode.off, title: "Off"),
                                .init(value: CalmColorMode.yellowGreen, title: "Yellow + Green"),
                                .init(value: CalmColorMode.yellowGreenBlue, title: "+ Blue"),
                            ],
                            active: model.calmColorMode,
                            onSelect: { model.setCalmColorMode($0) })
                    }
                    SettingsHint(text: "Which calm colors mute to a neutral white. Orange/red warnings "
                        + "always stay colored.")
                }

                // Awaiting-input in the menu bar (#233). The feature itself is switched on in Extra
                // features, which is what puts the count in the dropdown; this row decides whether the
                // menu bar carries it too (a leading hand icon). Meaningless while the feature is off,
                // so it's disabled — with a ⚠️ hint — then. A data stub is a third state: the watcher
                // never runs, so the hint says so.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show sessions awaiting input", isOn: Binding(
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

                // Reset-countdown mode: a segmented control matching the page's other three-way rows,
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
        }
        .formStyle(.grouped)
    }

    /// The hint under the awaiting-input row, in priority order: the feature is off (nothing to place
    /// anywhere) → a stub is driving the app (the watcher doesn't run at all) → the plain
    /// description. The first two are ⚠️ states; see ``awaitingInputHintIsWarning``.
    private var awaitingInputHint: String {
        guard model.awaitingInputEnabled else {
            return "Enable *Show sessions awaiting input* in Extra features first."
        }
        if model.stubScenarioActive { return SettingsStubHint.text }
        return "Adds a hand icon to the menu bar (leading) when sessions are waiting. "
            + "The count itself is shown only in the dropdown."
    }

    private var awaitingInputHintIsWarning: Bool {
        !model.awaitingInputEnabled || model.stubScenarioActive
    }
}

// MARK: - AppearanceDropdownPane (#333)

/// Settings → Appearance › Dropdown: everything that configures the **popup** — its bar style and
/// which of its sections are listed when.
struct AppearanceDropdownPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // Bar style, dropdown copy (#329) — the same three styles as the menu bar, chosen
                // separately. One hint instead of the three on the Menu bar page: repeating the full
                // descriptions would pad the page without adding anything.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bar style")
                        Spacer()
                        SegmentedControl(
                            segments: AppearanceBarStyle.segments,
                            active: model.dropdownStyle,
                            onSelect: { model.setDropdownStyle($0) })
                    }
                    SettingsHint(text: "The same three styles, picked separately for the dropdown. "
                        + "The roomier bars here can carry a denser style than the menu bar.")
                }

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

    /// The three ``PopupSectionVisibility`` segments, shared by both rows above so they can never
    /// drift apart. Labels are deliberately terse — three segments plus a full-width row title leave
    /// no room for prose, which lives in each row's `SettingsHint` instead.
    private static let visibilitySegments: [SegmentedControl<PopupSectionVisibility>.Segment] =
        PopupSectionVisibility.allCases.map { .init(value: $0, title: $0.displayName) }
}

// MARK: - Shared across the Appearance pages

/// The ``BarStyle`` segments, shared by the Menu bar and Dropdown pages (#329) so the two surfaces
/// always offer the same choices in the same order — now that the two controls live on separate
/// pages, a shared constant is the only thing keeping them from drifting apart unnoticed.
///
/// Ordered **Pressure · Gauge · Progress**, not by `allCases`: it reads as a gradient of how much
/// positional information the bar carries — length alone, then length plus direction, then two
/// positions on the window. Declaration order is pinned by its own test and is free to differ.
@MainActor
enum AppearanceBarStyle {
    static let segments: [SegmentedControl<BarStyle>.Segment] = [
        .init(value: .pressure, title: "Pressure"),
        .init(value: .gauge, title: "Gauge"),
        .init(value: .progress, title: "Progress"),
    ]
}
