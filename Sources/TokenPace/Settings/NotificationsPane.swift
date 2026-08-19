import SwiftUI
import TokenPaceKit

// MARK: - NotificationsPane (#168, ADR-0042)

/// Settings → Notifications: the "Back to work!" (#160, ADR-0039) and "Extra Usage Credit" (ADR-0050)
/// notification switches in one section, and a **separate "Schedule" section** — the allowed-hours
/// window with a live duration and a weekend-suppress picker — that gates both notifications alike.
struct NotificationsPane: View {
    @Bindable var model: SettingsModel

    /// A stable anchor day for the time pickers — only the hour/minute are ever read back, so the
    /// calendar day is arbitrary. Fixed once per view so the picker's `Date` doesn't drift across days.
    @State private var anchor = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        Form {
            // On a `swift run` dev build every notification is unavailable (authorization can't be
            // granted), so the warning belongs to the whole section, not to a single switch — a banner
            // above the toggles (#156 treatment) instead of a per-switch hint.
            if model.notificationsDevBuild {
                Section {
                    SettingsHint(text: "Unavailable in development builds.", warning: true)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // Everything that follows the feature's availability sits inside one `.disabled`
                        // (#381) — the title, the switch and the hints below. The toggle carries
                        // `.labelsHidden()`, so SwiftUI never treats this text as its label and would
                        // leave it at full strength over a greyed switch; and a hint explaining an
                        // unavailable control is itself unavailable.
                        //
                        // "Preview" stays **outside** that group: it fires the notification on demand for
                        // verification (#193) and works even with the feature off — the post checks
                        // support + authorization itself (a silent no-op if not granted). Left inside, it
                        // would be disabled along with the rest; `.disabled` accumulates down the tree and
                        // a nested `.disabled(false)` is not documented to undo an ancestor's `true`, so
                        // the button is placed beside the group rather than relying on that.
                        Group {
                            SettingsDisabledLabel("Back to work")
                            Spacer()
                        }
                        .disabled(!model.backToWorkMasterEnabled)

                        Button("Preview") { model.tryBackToWork() }

                        Toggle("Back to work", isOn: Binding(
                            get: { model.backToWorkEnabled },
                            set: { model.setBackToWork($0) }))
                        .labelsHidden()
                        .disabled(!model.backToWorkMasterEnabled)
                    }
                    // Descriptive hints dim with the control they describe (#381) …
                    Group {
                        SettingsHint(
                            text: "If you hit a Claude usage limit, notifies you when it resets so you "
                                + "can get back to work.")
                        SettingsHint(
                            text: "It best suits the *Work harder!* and *Control freak* presets on the "
                                + "*Appearance* page.")
                    }
                    .disabled(!model.backToWorkMasterEnabled)

                    // … but this one is the **reason** the switch is unavailable ("Notifications are
                    // turned off for TokenPace — enable them in System Settings"), so it stays at full
                    // strength. Dimming the recovery instructions along with the thing they recover is
                    // exactly backwards.
                    SettingsHint(text: model.backToWorkHint, warning: !model.backToWorkHint.isEmpty)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // Same arrangement as "Back to work" above: the title and the hint follow the
                        // feature's availability, while "Preview" stays outside the group because it
                        // works regardless (the post gates on support + authorization itself).
                        Group {
                            // *Extra usage* is the dropdown section's own name, so it is written and
                            // italicised exactly as the Appearance pane writes it (ADR-0113). The
                            // toggle's own label below stays plain: it is hidden from sight and read
                            // aloud by VoiceOver, where asterisks would be spoken as markup.
                            SettingsDisabledLabel("Switching to *Extra usage*")
                            Spacer()
                        }
                        .disabled(!model.backToWorkMasterEnabled)

                        Button("Preview") { model.tryExtraUsage() }

                        Toggle("Switching to Extra usage", isOn: Binding(
                            get: { model.extraUsageNotifyEnabled },
                            set: { model.setExtraUsageNotify($0) }))
                        .labelsHidden()
                        .disabled(!model.backToWorkMasterEnabled)
                    }
                    SettingsHint(
                        text: "Notifies you the moment work starts running on paid Extra usage "
                            + "credits — with the amount spent and your limit, if set.")
                        .disabled(!model.backToWorkMasterEnabled)
                }

                // The switch is on and disabled, mirroring the locked "Claude API" row in
                // Providers › Claude. There is nothing to turn off — an incident subscription is already
                // opt-in per episode from the popup — but omitting the control entirely left the row
                // visibly short next to its two neighbours and read as an oversight. Shown-on-and-
                // disabled says "always available" where a missing control says nothing at all.
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Claude service incidents")
                        Spacer()
                        // Fires all three at once — the update and both endings — because the useful
                        // question is whether they read as distinguishable side by side.
                        Button("Preview") { model.previewIncidentNotifications() }
                        Toggle("Claude service incidents", isOn: .constant(true))
                            .labelsHidden()
                            .disabled(true)
                    }
                    SettingsHint(
                        text: "When Claude services go down, the popup offers to notify you once "
                            + "they recover — and then tells you what changed until they do. "
                            + "Nothing arrives unless you ask for it there, so there is nothing to "
                            + "switch off here.")
                }

            }

            // The allowed-hours window and weekend-suppress apply to every notification — a separate
            // "Schedule" section that is **always visible and enabled**, even when no notification is on
            // (so the user can set their quiet hours up front). It gates both notifications alike.
            Section("Schedule") {
                LabeledContent("Allowed hours") {
                    HStack(spacing: 8) {
                        Text(model.notifyWindowLengthText).foregroundStyle(.secondary)
                        DatePicker("", selection: model.notifyStartBinding(anchor: anchor),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text("–").foregroundStyle(.secondary)
                        DatePicker("", selection: model.notifyEndBinding(anchor: anchor),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }

                Picker("Suppress on weekends", selection: Binding(
                    get: { model.suppressDays },
                    set: { model.setSuppressDays($0) })) {
                    ForEach(SuppressDays.allCases, id: \.self) { day in
                        Text(day.displayName).tag(day)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }
}
