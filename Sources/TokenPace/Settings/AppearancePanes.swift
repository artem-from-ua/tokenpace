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
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    // Heading block: the section's own label with the copy-config button trailing, and
                    // the hint directly under it — the hint explains what picking *any* option below
                    // does, so it belongs to the heading, not to the last radio. Its own 4 pt spacing
                    // (rather than the 10 pt between the block and the radios) is what keeps the two
                    // lines reading as one heading instead of as a fifth entry in the list.
                    //
                    // The radios sit below the block rather than beside the label — four two-line
                    // options are a block, not a control that fits at the end of a row.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Change appearance preset")
                            Spacer()
                            copyConfigButton
                        }
                        SettingsHint(text: "Set all the options for *Menu bar* and *Dropdown* at once.")
                    }
                    RadioGroup(
                        options: AppearancePreset.allCases.map {
                            .init(value: AppearancePreset?.some($0), title: $0.displayName,
                                  summary: $0.summary)
                        } + [.init(value: AppearancePreset?.none, title: "Custom",
                                   // Names what it actually holds: the setup as it stood the last time
                                   // a preset overwrote it. Saying "your settings" would imply a slot
                                   // the user maintains, when it is a snapshot the app takes for them
                                   // — and one that a *new* hand-made setup replaces (`apply(_:)`
                                   // re-stashes only when the live config matches no preset).
                                   // Worded to hold in **both** states, because the line never swaps:
                                   // on a fresh install there is no such setup yet, and the sentence
                                   // then reads as what the option is *for* rather than as a promise
                                   // about something that exists. A second wording that appeared only
                                   // while the option was inert would move the rows under the pointer.
                                   summary: "The setup you had before switching to a predefined preset.",
                                   // Selectable once there is a setup to go back to (#333); until then
                                   // it stays the indicator it always was.
                                   selectable: model.canRestoreCustom)],
                        active: model.activePreset,
                        onSelect: { picked in
                            if let preset = picked { model.apply(preset) } else { model.applySavedCustom() }
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
    private static let copyTarget = "appearance settings"

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
                // the window, Pressure measures the gap against the time left, Gauge measures the same
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
                // **Hidden under Pressure**, which is why it shares a card with `Style` rather than
                // sitting with the row below: Pressure draws the whole calm side as zero
                // (`BarLayout.pressureLength` = `max(0, gaugeOffset)`), so neither muting mode has any
                // ribbon to colour and the choice cannot show itself. A row that appears and disappears
                // with its neighbour's value has to be next to that neighbour, or the disappearance
                // reads as a glitch. The stored value is untouched while hidden — switching back to
                // Gauge or Progress restores the same choice.
                if model.menuBarStyle != .pressure {
                    HStack {
                        Text("Colors tell me")
                        Spacer()
                        SegmentedControl(
                            segments: AppearanceColorAdvice.segments,
                            active: model.colorsTell,
                            onSelect: { model.setColorAdvice($0) })
                    }
                    // The row slides out of the card edge and fades, rather than blinking in and out.
                    //
                    // This is the **opposite** of what every other conditional row in Settings does
                    // (`GeneralPane`, `ProvidersPane`, `ProvidersClaudePane`, `AboutPane` all carry
                    // `.animation(nil, …)`), and deliberately so: those rows are gated by a *toggle the
                    // user just clicked directly above them*, where the causal link is obvious and the
                    // animation is pure motion. This one is gated by a **picture** two rows up, so the
                    // motion is doing work — it draws the eye from the tile that was clicked to the row
                    // that answered, which is what keeps the disappearance from reading as a glitch.
                    //
                    // `.top` on the transition, not `.identity`: the row belongs to the block above it,
                    // so it should look like it folded into `Style` rather than dropping out of the
                    // card's bottom edge.
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

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
        // Drives the `Colors tell me` row's transition above. Scoped to `menuBarStyle` on purpose: a bare
        // `.animation(_:)` would also animate every *segment* change on this page, so picking a different
        // `Hide the top 5h bar` mode would slide its own control around.
        //
        // 0.2 s matches the tile picker's own press feedback, so the tile and the row read as one gesture
        // rather than two events; `easeInOut` because the card is changing height, and a spring would
        // overshoot the neighbouring section.
        .animation(.easeInOut(duration: 0.2), value: model.menuBarStyle)
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
                // column of Pressure/Gauge bars reads as documented behaviour rather than a bug worth
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
                    // "per-model & per-service", not "model & service": these are the limits belonging to
                    // one model or one service, as against the 5h/7d windows above them, and the bare
                    // form left that to inference. The hyphenated "model- & service-specific" says the
                    // same thing with a harder-to-read chain of hyphens; "per-" is also the code's own
                    // word for these rows (`PopupLayout.perModelRows`).
                    Text("Show per-model & per-service limits")
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
