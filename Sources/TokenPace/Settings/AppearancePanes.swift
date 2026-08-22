import SwiftUI
import TokenPaceKit

// MARK: - The Appearance panes (#168, ADR-0042)

/// Settings → Appearance, and the two surface pages drilled into from it: ``MenuBarPane``,
/// ``DropdownPane``. The split axis is the surface each option configures.
///
/// The page keeps what applies to the whole widget rather than to one surface: the preset picker and
/// its copy-config button, then the two navigator rows.
///
/// Bar style is *not* here despite looking like a single setting: it is two independent values, one
/// per surface (ADR-0080), so each sits with its own surface.
///
/// The preset control and the copy button work across the split without knowing about it: both read
/// `SettingsModel.liveAppearanceValues`, which reads the model's fields directly rather than
/// anything a view holds.
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
            // First section: Appearance presets (#215, #224) — a **radio group**, one row per preset,
            // each setting every option on both child pages at once. `AppearancePreset.summary` holds
            // the prose line beside each preset's name.
            //
            // **Clicking previews; only `Apply` commits.** A click puts the preset in
            // `PersistedConfig`'s overlay, which every Appearance getter consults, so both surfaces draw
            // it while the store is untouched — and closing the window drops it.
            //
            // The fourth row is that config itself — "My setup".
            // MARK: The legend — its own section, above everything (#261)
            //
            // First on the page, and alone in its section, because it is the only row here that
            // **explains** rather than configures: read the marks, then change them. Not folded into
            // the surfaces' section below: those two rows lead to controls, and a reference page filed
            // beside them would promise settings it does not have.
            Section {
                SettingsNavigationRow(
                    title: SettingsChildPage.appearanceLegend.title,
                    subtitle: "What the colors, bars and icons mean.",
                    badge: .page(.appearanceLegend),
                    action: { model.drill(into: .appearanceLegend) })
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    // Heading block: the section's own label with the hint directly under it. Its 4 pt
                    // spacing (against the 10 pt below) is what keeps the two lines reading as one
                    // heading instead of as a fifth entry.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try an appearance preset")
                        SettingsHint(text: "Click one to see it live. "
                                         + "Nothing is saved until you press Apply.")
                    }
                    RadioGroup(
                        options: AppearancePreset.allCases.map { preset in
                            .init(value: AppearanceChoice.preset(preset), title: preset.displayName,
                                  summary: preset.summary,
                                  trailing: { AnyView(applyButton(for: preset)) })
                        } + [.init(value: AppearanceChoice.mySetup, title: "My setup",
                                   titleNote: mySetupNote,
                                   // States what the row is *for* rather than what it happens to hold,
                                   // and names the one thing the preview model makes people ask: what
                                   // happens when I close the window without applying anything.
                                   summary: "Your saved config — restored when you close Settings.",
                                   trailing: { AnyView(copyConfigButton) })],
                        active: model.selectedAppearanceChoice,
                        onSelect: { picked in
                            switch picked {
                            case .preset(let preset): model.previewPreset(preset)
                            case .mySetup: model.endPreview()
                            }
                        })
                }
            }

            // MARK: The two surfaces — unlabelled on purpose
            //
            // The two row titles already say which surface each is. Row order is menu bar then
            // dropdown, which is the order a user meets them: the widget is on screen at all times,
            // the popup only once clicked.
            Section {
                ForEach(SettingsChildPage.pages(of: .appearance)) { page in
                    SettingsNavigationRow(
                        title: page.title,
                        subtitle: model.surfaceSummary(for: page),
                        badge: .page(page),
                        action: { model.drill(into: page) })
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: The "My setup" row and the Apply button

    /// The note after the fourth row's name: the preset its **stored** values happen to equal, or
    /// nothing once the config is a combination of the user's own.
    ///
    /// It is a **statement about the saved config**, not a selection: a config that matches `Chill`
    /// today stops matching the moment any option changes, and selecting the `Chill` row would promise
    /// it keeps following that preset.
    ///
    /// Drawn in secondary ink by `RadioGroup` (see `Option.titleNote`), so it reads as an observation
    /// rather than as part of the row's name. It rides with the title rather than in the summary,
    /// which is a fixed description of the row that must not reflow the list under the pointer while
    /// the user is clicking through it.
    ///
    /// The preset's name is italicised (`*…*`, rendered by `RadioGroup` through `Text(.init(_:))`)
    /// because it is a name being quoted, not a word in the sentence. It also keeps `Work harder!` from
    /// reading as an exclamation the note itself is making.
    private var mySetupNote: String? {
        model.storedPresetName.map { "· same as *\($0.displayName)* preset" }
    }

    /// The `Apply` button on a preset row: makes the preview permanent.
    ///
    /// Present on **every** preset row rather than only the previewed one, and disabled where it would
    /// do nothing. A button that came and went with the selection would change the row's width as the
    /// user clicked down the list; one that is simply dim says "nothing to apply here" without moving
    /// anything. Its tooltip explains the dim state, which the button alone cannot.
    private func applyButton(for preset: AppearancePreset) -> some View {
        let isPreviewed = model.previewedPreset == preset
        let canApply = isPreviewed && model.canApplyPreviewedPreset
        return Button("Apply") { model.applyPreviewedPreset() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canApply)
            // Shown only on the row being previewed: on the others the button is dim simply because
            // they are not selected, which needs no explanation.
            .help(isPreviewed && !canApply ? "Already matches your setup" : "")
            .accessibilityLabel("Apply the \(preset.displayName) preset")
            // The row it sits on is the selected one; hiding it elsewhere would be a layout change, so
            // it stays put and only its enabled state moves.
            .opacity(isPreviewed ? 1 : 0)
            .allowsHitTesting(isPreviewed)
    }

    // MARK: Copy config (#257)

    /// The copy-to-clipboard button on the **"My setup" row**: it puts the stored Appearance values
    /// (plus the preset they match and the app version) on the clipboard as pretty-printed JSON, so
    /// "what does your setup look like?" is one click instead of a screenshot tour of three pages.
    ///
    /// It sits on that row rather than in the section heading because that is what it copies — the
    /// saved configuration, read past any preview. From the heading it would have looked like it
    /// copied whatever was on screen, which during a preview is a preset the user has not chosen.
    ///
    /// `doc.on.doc` is the same glyph as the Troubleshoot window's copy button, keeping one visual
    /// vocabulary for "copy" across the app — a share icon would promise a share sheet that isn't
    /// there. The hint rides as a native tooltip rather than a `SettingsHint` row: the section already
    /// carries a hint line, and a second would crowd it.
    private var copyConfigButton: some View {
        Button {
            copyConfigToClipboard()
        } label: {
            Image(systemName: didCopyConfig ? CopyFeedback.confirmedSymbol : CopyFeedback.restingSymbol)
                // A fixed box for **both** dimensions: the checkmark is narrower and shorter than
                // `doc.on.doc`, so without it the button's neighbours slide and the row jolts on every
                // click. Sized off the resting glyph, which is the taller of the two.
                .frame(width: Self.copyGlyphBox, height: Self.copyGlyphBox)
        }
        .buttonStyle(.borderless)
        // The swap is a state report, not a transition: SwiftUI's implicit animation cross-fades and
        // re-measures the two glyphs, which is the second half of the jolt the fixed box addresses.
        // Same treatment the dependent rows on `ProvidersPane` get, and for the same reason.
        .animation(nil, value: didCopyConfig)
        .help("Copy \(Self.copyTarget) to the clipboard")
        .accessibilityLabel(didCopyConfig
            ? CopyFeedback.confirmedLabel
            : CopyFeedback.restingLabel(Self.copyTarget))
    }

    /// What this button copies — used in the tooltip and the accessibility label.
    private static let copyTarget = "my appearance settings"

    /// The fixed box the copy glyph draws in, so neither of the two symbols can move the layout when
    /// they swap. Square: the resting `doc.on.doc` is the larger glyph in both dimensions, and one
    /// number for both keeps the button reading as a square hit target rather than a slot.
    private static let copyGlyphBox: CGFloat = 16

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

// MARK: - MenuBarPane (#333)

/// Settings → Appearance › Menu bar: everything that configures the **menu-bar widget** — its bar
/// style, which colours it mutes, and which indicators it may draw.
struct MenuBarPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // Bar style, menu-bar copy. All three show the pacing state by colour and differ in
                // *scale*: Progress marks positions in the window, Pressure measures the gap against
                // the time left, Balance measures the same thing from a centred zero so the underpace
                // side is drawn too.
                //
                // Picked by picture, System-Settings-Appearance style — the difference between the
                // three is purely visual, so three words never carried it. No hint under the row: the
                // preview is in the row itself.
                //
                // Top-aligned, not centred: the picker is roughly three times the height of a normal
                // control row, and a vertically centred label floats in the middle of that block
                // instead of heading it.
                HStack(alignment: .top) {
                    Text("Style")
                    Spacer()
                    BarStylePicker(
                        surface: .menuBar,
                        active: model.menuBarStyle,
                        onSelect: { model.setMenuBarStyle($0) })
                }

                // "Colors tell me" — which pacing advice keeps its colour. Named for the advice, not
                // for the hues it mutes. Segments run quiet-first, like every other control on the page.
                //
                // **Disabled under Pressure, and shown on `Slow down`.** Pressure draws the whole quiet
                // side at zero length (`BarLayout.pressureLength` = `max(0, balanceOffset)`) *and*
                // `StatusItemView` mutes it to white there regardless of this value, so every segment
                // would render the same bar; `Slow down` is the segment that describes what is actually
                // on screen. Disabled rather than hidden, so the page still answers "what will the
                // colours do?" — same treatment `AboutPane` gives a switch whose feature cannot work
                // (`installAutoEnabled`).
                //
                // **The stored value is never written here.** `displayedColorAdvice` swaps only what is
                // *drawn*; `PersistedConfig.colorsTell` keeps whatever the user last chose, so switching
                // back to Balance or Progress restores it with no bookkeeping of a "previous" value.
                HStack {
                    // The title dims with the control below it — `.disabled` sits on the whole `HStack`,
                    // and `SettingsDisabledLabel` turns that environment flag into AppKit's own
                    // `disabledControlTextColor`. A plain `Text` is nobody's label as far as SwiftUI is
                    // concerned, so without it a full-strength title would sit over a greyed control.
                    SettingsDisabledLabel("Colors tell me")
                    Spacer()
                    SegmentedControl(
                        segments: AppearanceColorAdvice.segments,
                        active: model.displayedColorAdvice,
                        onSelect: { model.setColorAdvice($0) })
                }
                .disabled(model.menuBarStyle == .pressure)

                // Whether the top (5-hour) bar steps aside until it needs attention (ADR-0086, narrowed
                // to one window by ADR-0090). The row names the bar, so the segments only say *when* —
                // reading as one sentence: "Hide the top 5h bar — until it needs attention".
                //
                // The hint describes what happens at a limit, which this row does *not* govern
                // (ADR-0091) and which nothing else in Settings explains.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Hide the top 5h bar")
                        Spacer()
                        SegmentedControl(
                            segments: AppearanceTopBarHiding.segments,
                            active: model.hideTop5hBar,
                            onSelect: { model.setTopBarHiding($0) })
                    }
                    SettingsHint(text: "Either way, once a limit is actually reached both bars give way "
                        + "to the countdown to it.")
                }
            }

            // The service dot gets its own card: the three rows above are about the **pacing bars** and
            // read `PacingModel`, while this one is about **external incidents** and reads
            // `ProviderMonitoring`. A single row needs no section header, like the polling-pause section
            // on `ProvidersPane`.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show service status dot", isOn: Binding(
                        get: { model.showServiceDot }, set: { model.setShowServiceDot($0) }))
                    SettingsHint(text: "Appears next to the bars when a monitored service reports an "
                        + "outage.")
                }
            }
        }
        .formStyle(.grouped)
        // Picking a tile moves the `Colors tell me` row's highlight (to `Slow down` under Pressure, back
        // to the stored choice otherwise) and greys the control out. Animated so the two read as one
        // consequence of the click. Scoped to `menuBarStyle` so a bare `.animation(_:)` doesn't also
        // animate every *segment* change on this page.
        .animation(SettingsRowReveal.animation, value: model.menuBarStyle)
    }

}

// MARK: - DropdownPane (#333)

/// Settings → Appearance › Dropdown: everything that configures the **popup** — its bar style and
/// which of its sections are listed when.
struct DropdownPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                // Bar style, dropdown copy — the same three styles as the menu bar, chosen separately.
                // The hint states the Extra-usage exception: that bar is always Progress whatever is
                // picked here, so a Progress bar under a column of Pressure/Balance bars reads as
                // documented behaviour. It names the *bar*, not the section.
                //
                // Row and hint share one `VStack` so the hint reads as the caveat on the control
                // directly above it rather than a stray statement.
                //
                // Top-aligned for the same reason the menu-bar row is: the picker is roughly three times
                // the height of a normal control row, and a vertically centred label floats in the
                // middle of that block instead of heading it.
                //
                // The hint sits **under the label**, inside the row's left column, rather than under the
                // whole row, so it stays close to the control it qualifies instead of running the full
                // pane width beneath the tiles.
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Style")
                        SettingsHint(text: "*Extra usage* bar always draws in *Progress* style.")
                    }
                    Spacer()
                    BarStylePicker(
                        surface: .dropdown,
                        active: model.dropdownStyle,
                        onSelect: { model.setDropdownStyle($0) })
                }
            }

            // The visibility rows get their own section: the Style row is three tiles plus a hint tall,
            // and the two rows below are about *which sections appear at all* — a different decision.
            Section {
                // No `SettingsHint` under either row: the segment labels ("Always" / "Once used" /
                // "When it needs attention") already say when the group shows. The two rows offer
                // *different* segment sets — see the constants below.
                HStack {
                    // "per-model and per-service": these are the limits belonging to one model or one
                    // service, as against the 5h/7d windows above them. "per-" is also the code's own
                    // word for these rows (`PopupLayout.perModelRows`).
                    Text("Show per-model and per-service limits")
                    Spacer()
                    SegmentedControl(
                        segments: Self.modelLimitsSegments,
                        active: model.showPerModelLimits,
                        onSelect: { model.setModelLimitsVisibility($0) })
                }

                HStack {
                    // *Extra usage* is the name of the dropdown's own section, so it is capitalised and
                    // italicised as one — matching the Style row's hint above, which already refers to
                    // it that way. `Text(.init(_:))` forces the `LocalizedStringKey` initializer, which
                    // is what makes inline markdown render (the plain `Text(String)` one would print the
                    // asterisks); same idiom as `SettingsHint`.
                    Text(.init("Show *Extra usage*"))
                    Spacer()
                    SegmentedControl(
                        segments: Self.extraUsageSegments,
                        active: model.showExtraUsage,
                        onSelect: { model.setExtraUsageVisibility($0) })
                }
            }

            // The ⌥ caption (#475), in its own unnamed section at the foot of the page.
            //
            // **The one control on this pane that is not a preset value.** Everything above is an
            // `AppearancePresetValues` member: picking a preset rewrites it, and Copy config carries it
            // to another Mac. This switch does neither, on purpose — it records that its owner already
            // knows the shortcut, a fact about a person rather than about how the dropdown should look.
            //
            // No `SettingsHint`: the label names the caption verbatim and the caption says what it does.
            Section {
                Toggle("Show «hold ⌥ Option» hint", isOn: Binding(
                    get: { model.showOptionHint },
                    set: { model.setShowOptionHint($0) }))
            }
        }
        .formStyle(.grouped)
    }

    /// The two rows above offer **different** segment sets, so neither is built from `allCases` — both
    /// are spelled out here, the way `AppearanceBarStyle.segments` is.
    ///
    /// Ordered **quietest first**, matching every segmented control in Appearance: the leftmost option
    /// puts the least on screen, the rightmost the most.
    ///
    /// ⌥ is OR'd into every mode, so holding it already reveals the group whichever one is picked.
    /// Stored values resolve through `PopupSectionVisibility.legacyRawValues`.
    private static let modelLimitsSegments: [SegmentedControl<PopupSectionVisibility>.Segment] =
        [.whenItNeedsAttention, .onceUsed, .always].map { .init(value: $0, title: $0.displayName) }

    /// Extra usage omits `.whenItNeedsAttention`. Credits severity comes from `credits.bar`, which is
    /// `nil` on an **unlimited** money cap — so that mode would hide a paying user's spend forever — and
    /// when a cap does exist, "spent > 0" always fires before orange, leaving the mode no behaviour of
    /// its own. Stored values of it resolve to `.onceUsed` through the enum's legacy table.
    ///
    /// Which leaves this row a plain pair, quietest first: show it from the first cent spent, or always.
    /// Built from `PopupSectionVisibility.creditsOffered` rather than spelled out here: multiple paths
    /// can put a value in this row's key (the getter, an imported config), and each has to fold the
    /// mode this control does not offer. One list, consulted by all, is what keeps them from
    /// disagreeing — a value the control lacks opens it with no segment highlighted.
    private static let extraUsageSegments: [SegmentedControl<PopupSectionVisibility>.Segment] =
        PopupSectionVisibility.creditsOffered.map { .init(value: $0, title: $0.displayName) }
}

// MARK: - Shared across the surface panes

/// The ``BarStyle`` segments, shared by the Menu bar and Dropdown panes so the two surfaces always
/// offer the same choices in the same order.
///
/// The two consumers are not the same control: Menu bar renders these through ``BarStylePicker``
/// (preview pictures), Dropdown through ``SegmentedControl`` (text). Both read `value` and `title`
/// from here, including for the release-notes recipe in `docs/guides/releasing.md`, which greps the
/// titles out of this file.
///
/// Ordered **Pressure · Balance · Progress**, not by `allCases`: it reads as a gradient of how much
/// positional information the bar carries — length alone, then length plus direction, then two
/// positions on the window. Declaration order is pinned by its own test and is free to differ.
@MainActor
enum AppearanceBarStyle {
    static let segments: [SegmentedControl<BarStyle>.Segment] = [
        // Titles from `BarStyle.displayName`, not literals here — one source, one rename.
        .init(value: .pressure, title: BarStyle.pressure.displayName),
        .init(value: .balance, title: BarStyle.balance.displayName),
        .init(value: .progress, title: BarStyle.progress.displayName),
    ]
}

/// The ``TopBarHiding`` segments for the Menu bar pane's "Hide the top 5h bar" row (ADR-0086, narrowed
/// to one window by ADR-0090).
///
/// Spelled out rather than mapped from `allCases`, like every other segment list here. The order on
/// screen is a **presentation** decision — quietest option leftmost — and deriving it from the enum
/// would make the enum's declaration order load-bearing for the UI.
@MainActor
enum AppearanceTopBarHiding {
    static let segments: [SegmentedControl<TopBarHiding>.Segment] =
        [.untilItNeedsAttention, .never].map { .init(value: $0, title: $0.displayName) }
}

/// The ``ColorAdvice`` segments for the Menu bar pane's "Colors tell me" row.
///
/// Quietest first, like its neighbours: `Slow down` keeps colour on one piece of advice, `How it's
/// going` keeps it on everything. The titles are the advice itself, so the row and a segment read as
/// one sentence — "Colors tell me — slow down" — and no hint is needed to explain either end.
@MainActor
enum AppearanceColorAdvice {
    static let segments: [SegmentedControl<ColorAdvice>.Segment] = [
        .init(value: .slowDown, title: "Slow down"),
        .init(value: .slowDownOrSpeedUp, title: "Slow down or speed up"),
        .init(value: .howItsGoing, title: "How it's going"),
    ]
}
