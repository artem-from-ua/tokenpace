import SwiftUI
import TokenPaceKit

// MARK: - The Appearance panes (#168, ADR-0042; split by surface in #333, nested back under one
// section here)

/// Settings → Appearance, and the two surface pages drilled into from it: ``MenuBarPane``,
/// ``DropdownPane``. The split axis is unchanged from #333 — the surface each option configures —
/// but the three are one section again rather than three sidebar rows, so what says they belong
/// together is the navigation itself instead of a divider between siblings.
///
/// The page keeps what applies to the whole widget rather than to one surface: the preset picker and
/// its copy-config button, then the two navigator rows.
///
/// Bar style is *not* here despite looking like a single setting: since #329 it is two independent
/// values, one per surface (ADR-0080), so each sits with its own surface.
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
            // First section: one-click Appearance presets (#215, #224) — a **radio group**, one row per
            // preset. Picking Chill / Work harder! / Control freak applies it (sets every option on both
            // child pages at once).
            //
            // Radios rather than the segmented control this was until now: the three names read as
            // moods, and the question they leave open — *which signals does this make loudest?* — needs
            // a line of prose per option, which a segment has no room for. `AppearancePreset.summary`
            // holds those lines, beside the values they describe.
            //
            // "Custom" is a **real slot** since #333, not the pure indicator it was: applying a preset
            // stashes the setup it overwrites, so Custom can restore it. It falls back to
            // indicator-only (visible, highlightable, inert) while nothing is stashed — a fresh install
            // has nothing to come back to — and says so on its own second line.
            // MARK: The legend — its own section, above everything (#261)
            //
            // First on the page, and alone in its section, because it is the only row here that
            // **explains** rather than configures: read the marks, then change them. A divider is the
            // cheapest way to say that, and putting it first follows the order a newcomer needs — the
            // presets below are meaningless until the colours they set have names.
            //
            // Not folded into the surfaces' section below: those two rows lead to controls, and a
            // reference page filed beside them would promise settings it does not have.
            Section {
                SettingsNavigationRow(
                    title: SettingsChildPage.appearanceLegend.title,
                    subtitle: "What the colors, bars and icons mean.",
                    badge: .page(.appearanceLegend),
                    action: { model.drill(into: .appearanceLegend) })
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    // Heading block: the section's own label with the hint directly under it. The hint
                    // carries the whole mental model of this list — clicking previews, only Apply
                    // commits — so it belongs to the heading rather than to any one row. Its 4 pt
                    // spacing (against the 10 pt below) is what keeps the two lines reading as one
                    // heading instead of as a fifth entry.
                    //
                    // The copy button used to live here, trailing the label. It sits on the "My setup"
                    // row now: it copies the stored configuration, so it belongs to the row that names
                    // it rather than to a heading that covers all four.
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
            // A header here would have to be called something like "Surfaces", and the two row titles
            // already say which surface each is. The section's job is the divider above it: it
            // separates the preset row, which writes to both pages, from the pages it writes to.
            //
            // Row order is menu bar then dropdown, which is the order a user meets them: the widget is
            // on screen at all times, the popup only once clicked.
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
    /// it keeps following that preset. Naming the match beside the row says the same thing without the
    /// promise — and disappears by itself once the config drifts.
    ///
    /// Drawn in secondary ink by `RadioGroup` (see `Option.titleNote`), so it reads as an observation
    /// rather than as part of the row's name. It rides with the title rather than in the summary
    /// because the summary is a fixed description of the row; a second line that rewrote itself as
    /// state changed would reflow the list under the pointer, which is the one thing this control must
    /// not do while the user is clicking through it.
    private var mySetupNote: String? {
        model.storedPresetName.map { "· same as \($0.displayName) preset" }
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
                // A fixed box for **both** dimensions. Width was always needed — the checkmark is
                // narrower than `doc.on.doc`, so without it the button's neighbours slide sideways on
                // every click. Height became just as necessary once the button stopped sharing a row
                // with the segmented control: that control used to set the row's height, and now the
                // button sets it alone, so the checkmark's shorter glyph shrank the row and jolted
                // everything below it. Sized off the resting glyph, which is the taller of the two.
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
                // Bar style, menu-bar copy (#224, rescaled in #307, per-surface since #329). All three
                // show the pacing state by colour and differ in *scale*: Progress marks positions in
                // the window, Pressure measures the gap against the time left, Balance measures the same
                // thing from a centred zero so the underpace side is drawn too.
                //
                // Picked by picture, System-Settings-Appearance style: the difference between the
                // three is purely visual, so three words never carried it. Prose was tried and cut
                // (#341) for costing more vertical space than it bought.
                //
                // Still no hints under the row, but for a new reason. The old one cited the live
                // dropdown preview beside the window — which renders the **popup** (ADR-0083) and so
                // never showed this row's styles at all. Now the preview is in the row itself.
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

                // "Colors tell me" (#224, renamed and rescoped in #381) — which pacing advice keeps its
                // colour. Named for the advice, not for the hues it mutes: the reader is choosing what
                // they want to be told, and "Yellow + Green" / "+ Blue" answered a question about
                // mechanism instead. Segments run quiet-first, like every other control on the page.
                //
                // **Disabled under Pressure, and shown on `Slow down`** — which is why it shares a card
                // with `Style` rather than sitting with the row below.
                //
                // Pressure draws the whole quiet side at zero length (`BarLayout.pressureLength` =
                // `max(0, balanceOffset)`) *and* `StatusItemView` mutes it to white there regardless of
                // this value, so every segment would render the same bar. `Slow down` is the segment
                // that describes what is actually on screen — only the "too fast" orange keeps colour —
                // so the control reports the truth instead of offering a choice that does nothing.
                //
                // Disabled rather than hidden: a row that vanishes takes its own explanation with it,
                // and the user is left to guess whether the setting is gone or merely elsewhere. Greyed
                // out with the honest value showing, the page still answers "what will the colours do?"
                // — which is the question the row exists for. Same treatment `AboutPane` gives a switch
                // whose feature cannot work (`installAutoEnabled`).
                //
                // **The stored value is never written here.** `displayedColorAdvice` swaps only what is
                // *drawn*; `PersistedConfig.colorsTell` keeps whatever the user last chose, so switching
                // back to Balance or Progress restores it with no bookkeeping of a "previous" value — the
                // store already is that memory.
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
                // which makes it read as one sentence: "Hide the top 5h bar — until it needs attention".
                //
                // The hint keeps only its second sentence. The first ("hidden while it's calm and comes
                // back…") now duplicates the segment; this one describes what happens at a limit, which
                // this row does *not* govern (ADR-0091) and which nothing else in Settings explains —
                // and both bars vanishing at once is the app's most alarming transition.
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

            // The service dot gets its own card (#381): the three rows above are about the **pacing
            // bars** and read `PacingModel`, while this one is about **external incidents** and reads
            // `ProviderMonitoring`. A single row needs no section header, like the polling-pause section
            // on `ProvidersPane`.
            Section {
                // "on issues" left the label (#381): the dot only ever appears on an issue, so that was
                // describing the indicator's behaviour rather than offering a choice. The hint says it
                // instead, and names the link to Providers — nothing on this page defines "service".
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
        // consequence of the click rather than as the page flickering.
        //
        // Scoped to `menuBarStyle` on purpose: a bare `.animation(_:)` would also animate every *segment*
        // change on this page, so picking a different `Hide the top 5h bar` mode would slide its own
        // control around.
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
                // Bar style, dropdown copy (#329) — the same three styles as the menu bar, chosen
                // separately. Its hint states the Extra-usage exception, and states only the fact: that
                // bar is always Progress whatever is picked here, so a Progress bar sitting under a
                // column of Pressure/Balance bars reads as documented behaviour rather than a bug worth
                // reporting. The hint names the *bar*, not the section: this page sets how bars are
                // drawn, and the section also carries text and a badge that this exception says nothing
                // about. The reasons stay here rather than in the hint — its window is a calendar
                // month, which the bar's two captioned ends already name on the bar itself, so a user
                // who wonders why has the answer in front of them.
                //
                // Row and hint share one `VStack`, the same shape every other explained control on
                // these pages uses. Left as siblings of the `Section` they became two independent rows,
                // and the hint read as a stray statement about Extra usage rather than as the caveat on
                // the control directly above it — which is the only thing it is.
                // Top-aligned for the same reason the menu-bar row is: the picker is roughly three times
                // the height of a normal control row, and a vertically centred label floats in the
                // middle of that block instead of heading it.
                //
                // The hint sits **under the label**, inside the row's left column, rather than under the
                // whole row. Left below the `HStack` it ran the full pane width *beneath the tiles*,
                // which put a caveat about one bar's style a long way from the control it qualifies —
                // and left the picker looking like it had a footnote of its own. In the label's column
                // it reads as what it is: a note on this setting, next to the setting's name.
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

            // The visibility rows get their own section, matching the menu-bar page (#374): the Style
            // row is three tiles plus a hint tall, and the two rows below are about *which sections
            // appear at all* rather than about how a bar is drawn — a different decision, so a
            // different card.
            Section {
                // No `SettingsHint` under either row: the segment labels ("Always" / "Once used" /
                // "When it needs attention") already say when the group shows, and a hint repeating that would
                // crowd the two rows that close the section. The two rows offer *different* segment
                // sets — see the constants below.
                HStack {
                    // "per-model and per-service", not "model and service": these are the limits belonging to
                    // one model or one service, as against the 5h/7d windows above them, and the bare
                    // form left that to inference. The hyphenated "model- & service-specific" says the
                    // same thing with a harder-to-read chain of hyphens; "per-" is also the code's own
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
        }
        .formStyle(.grouped)
    }

    /// The two rows above offer **different** segment sets, so neither is built from `allCases` — both
    /// are spelled out here, the way `AppearanceBarStyle.segments` is.
    ///
    /// Ordered **quietest first** (#381), matching every segmented control in Appearance: the leftmost
    /// option puts the least on screen, the rightmost the most. Before #381 these two ran the other way
    /// (`Always` leftmost), which made the page's controls disagree about which direction meant "more".
    ///
    /// The retired `⌥ Option`-only segment (#374) is gone from the enum entirely as of #381: ⌥ is OR'd
    /// into every mode, so holding it already reveals the group whichever one is picked, and the mode's
    /// only distinct behaviour was hiding the group when its data had turned interesting. Stored values
    /// resolve through `PopupSectionVisibility.legacyRawValues`.
    private static let modelLimitsSegments: [SegmentedControl<PopupSectionVisibility>.Segment] =
        [.whenItNeedsAttention, .onceUsed, .always].map { .init(value: $0, title: $0.displayName) }

    /// Extra usage omits `.whenItNeedsAttention`. Credits severity comes from `credits.bar`, which is
    /// `nil` on an **unlimited** money cap — so that mode would hide a paying user's spend forever — and
    /// when a cap does exist, "spent > 0" always fires before orange, leaving the mode no behaviour of
    /// its own. Stored values of it resolve to `.onceUsed` through the enum's legacy table.
    ///
    /// Which leaves this row a plain pair, quietest first: show it from the first cent spent, or always.
    /// Built from `PopupSectionVisibility.creditsOffered` rather than spelled out here: three separate
    /// paths can put a value in this row's key (the #381 key migration, the getter, an imported config),
    /// and each has to fold the mode this control does not offer. One list, consulted by all four, is what
    /// keeps them from disagreeing — a value the control lacks opens it with no segment highlighted.
    private static let extraUsageSegments: [SegmentedControl<PopupSectionVisibility>.Segment] =
        PopupSectionVisibility.creditsOffered.map { .init(value: $0, title: $0.displayName) }
}

// MARK: - Shared across the surface panes

/// The ``BarStyle`` segments, shared by the Menu bar and Dropdown panes (#329) so the two surfaces
/// always offer the same choices in the same order — now that the two controls live on separate
/// panes, a shared constant is the only thing keeping them from drifting apart unnoticed.
///
/// The two consumers are no longer the same control: Menu bar renders these through
/// ``BarStylePicker`` (preview pictures), Dropdown still through ``SegmentedControl`` (text). Both
/// read `value` and `title` from here, so order and wording stay common across the split — including
/// for the release-notes recipe in `docs/guides/releasing.md`, which greps the titles out of this
/// file.
///
/// Ordered **Pressure · Balance · Progress**, not by `allCases`: it reads as a gradient of how much
/// positional information the bar carries — length alone, then length plus direction, then two
/// positions on the window. Declaration order is pinned by its own test and is free to differ.
@MainActor
enum AppearanceBarStyle {
    static let segments: [SegmentedControl<BarStyle>.Segment] = [
        // Titles from `BarStyle.displayName`, not literals here (#396): the dropdown now captions each
        // bar with the same word, and #388 renamed the centred style through it — one source, one
        // rename. Two literals here would have meant two half-renames.
        .init(value: .pressure, title: BarStyle.pressure.displayName),
        .init(value: .balance, title: BarStyle.balance.displayName),
        .init(value: .progress, title: BarStyle.progress.displayName),
    ]
}

/// The ``TopBarHiding`` segments for the Menu bar pane's "Hide the top 5h bar" row (ADR-0086, narrowed
/// to one window by ADR-0090).
///
/// Spelled out rather than mapped from `allCases` (#381), like every other segment list here. The order
/// on screen is a **presentation** decision — quietest option leftmost — and deriving it from the enum
/// made the enum's declaration order load-bearing for the UI, so a later re-ordering of the control
/// would have read as a change to the stored type.
@MainActor
enum AppearanceTopBarHiding {
    static let segments: [SegmentedControl<TopBarHiding>.Segment] =
        [.untilItNeedsAttention, .never].map { .init(value: $0, title: $0.displayName) }
}

/// The ``ColorAdvice`` segments for the Menu bar pane's "Colors tell me" row (#381).
///
/// Quietest first, like its neighbours: `Slow down` keeps colour on one piece of advice, `How it's
/// going` keeps it on everything. The titles are the advice itself, so the row and a segment read as one
/// sentence — "Colors tell me — slow down" — and no hint is needed to explain either end.
@MainActor
enum AppearanceColorAdvice {
    static let segments: [SegmentedControl<ColorAdvice>.Segment] = [
        .init(value: .slowDown, title: "Slow down"),
        .init(value: .slowDownOrSpeedUp, title: "Slow down or speed up"),
        .init(value: .howItsGoing, title: "How it's going"),
    ]
}
