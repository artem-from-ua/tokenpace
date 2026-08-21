import SwiftUI
import TokenPaceKit

// MARK: - GeneralPane (#168, ADR-0042)

/// Settings → General: how the app lives on this Mac — launch-at-login and the usage journal — plus the
/// one dropdown switch that is not an appearance choice (the ⌥ caption, #475; see its section below).
///
/// The screen-lock polling pause used to sit here; it moved to `Providers`, where the polling it
/// suspends is configured.
///
/// **Usage history belongs here rather than with a provider** (#317): the journal is a feature of
/// the app — it feeds the Insights window (ADR-0067) — and providers are merely sources of records
/// in it. A second provider adds rows to the same single journal, so the switch that owns it stays
/// app-wide. (It spent #242…#317 on the "Extra features" pane, retired in #341.)
struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    // The control dims; the hint below does **not** (#381).
                    //
                    // The hint here is the *reason* the control is unavailable — "Unavailable in
                    // development builds." — and dimming an explanation is backwards: it is the one line
                    // the user still needs to read. Same split `AboutPane` uses for auto-install, where
                    // the deferral reasons stay at full strength beside a greyed switch.
                    //
                    // This is the distinction `SettingsHint`'s environment-driven dimming cannot make on
                    // its own: a hint that *describes* a control follows it down, a hint that *explains
                    // its absence* must not. So the scope is the control, not the row.
                    // The title is a `SettingsDisabledLabel`, not the `Toggle`'s own string, because
                    // SwiftUI's `Form` on macOS dims **only the switch** when a `Toggle` is disabled —
                    // the label stays at full strength, so a disabled row reads as half-live (verified on
                    // screen, not assumed). Handing the title to a sibling view that reads `\.isEnabled`
                    // is what actually dims it.
                    Toggle(isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.toggleLaunchAtLogin($0) })) {
                        SettingsDisabledLabel("Launch TokenPace at login")
                    }
                    .disabled(!model.launchToggleEnabled)

                    SettingsHint(text: model.launchHint.text, warning: model.launchHint.devBuild)
                }
            }

            // MARK: Usage history (usage journal collector, #242 — moved here by #317)
            Section("Usage history") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Record usage history", isOn: Binding(
                        get: { model.journalEnabled },
                        set: { model.setJournalEnabled($0) }))
                    SettingsHint(text: "Saves each usage reading to a local file so *Insights* can show trends over time. The data stays on this Mac and never leaves it.")
                }

                // Read-only destination: the journal lives in Application Support and is not
                // user-relocatable, but the folder can be revealed in Finder. Shown only when on.
                // The path control is display-only (no click) and hugs its content — right-aligned
                // before the button, since a separate "Open in Finder" button already reveals it.
                if model.journalEnabled {
                    LabeledContent("Location") {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            PathControlView(url: journalDirectoryURL, clickToReveal: false)
                                .fixedSize()
                            Button("Open in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([journalDirectoryURL])
                            }
                        }
                    }
                    .transition(SettingsRowReveal.transition)
                }
            }

            // MARK: Dropdown — the ⌥ caption (#475)
            //
            // On *this* pane, not on Appearance › Dropdown where it would seem to belong, because it must
            // not travel in an appearance preset or in an exported config: it records that this person
            // already knows the shortcut, which is not a look worth carrying to another Mac. Membership
            // in `AppearancePresetValues` is what decides that, and this setting stays out of it.
            //
            // Its own `Section` rather than a row among the app-lifetime switches above: the pane's other
            // controls answer "how does TokenPace live on this Mac", and this one answers "what does the
            // dropdown say" — a different question deserves its own card. Appearance › Dropdown points
            // here so it is findable from where it is missed (#476).
            // No `SettingsHint` under the row: the label names the caption verbatim, and the caption says
            // what it does. A line explaining that ⌥ still works without it would be telling the reader
            // something the switch's own wording already implies.
            Section("Dropdown") {
                Toggle("Show «hold ⌥ Option» hint in dropdown", isOn: Binding(
                    get: { model.showOptionHint },
                    set: { model.setShowOptionHint($0) }))
            }
        }
        .formStyle(.grouped)
        // The Location row folds out of the toggle above it rather than blinking (#381) — see
        // `SettingsRowReveal` for why the previous `.animation(nil, …)` was the worse of the two.
        .animation(SettingsRowReveal.animation, value: model.journalEnabled)
    }

    /// The fixed journal directory in Application Support — read-only, revealed via Finder.
    private var journalDirectoryURL: URL { UsageJournal.defaultDirectory }
}
