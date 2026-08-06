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
                        Text("Back to work")
                        Spacer()
                        // "Preview" fires the notification on demand for verification (#193). It sits
                        // before the on/off switch and is always enabled — even with the feature off:
                        // the post checks support + authorization itself (a silent no-op if not granted).
                        Button("Preview") { model.tryBackToWork() }
                        Toggle("Back to work", isOn: Binding(
                            get: { model.backToWorkEnabled },
                            set: { model.setBackToWork($0) }))
                        .labelsHidden()
                        .disabled(!model.backToWorkMasterEnabled)
                    }
                    SettingsHint(
                        text: "If you hit a Claude usage limit, notifies you when it resets so you "
                            + "can get back to work.")
                    SettingsHint(
                        text: "It best suits the *Work harder!* and *Control freak* UI presets on the "
                            + "*Appearance* tab.")
                    SettingsHint(text: model.backToWorkHint, warning: !model.backToWorkHint.isEmpty)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Switching to Extra Usage")
                        Spacer()
                        // "Preview" fires the banner on demand for verification, mirroring "Back to work" —
                        // always enabled (the post gates on support + authorization itself).
                        Button("Preview") { model.tryExtraUsage() }
                        Toggle("Switching to Extra Usage", isOn: Binding(
                            get: { model.extraUsageNotifyEnabled },
                            set: { model.setExtraUsageNotify($0) }))
                        .labelsHidden()
                        .disabled(!model.backToWorkMasterEnabled)
                    }
                    SettingsHint(
                        text: "Notifies you the moment work starts running on paid Extra Usage Credit "
                            + "— with the amount spent and your limit, if set.")
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
