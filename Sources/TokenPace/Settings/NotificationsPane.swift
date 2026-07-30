import SwiftUI
import TokenPaceKit

// MARK: - NotificationsPane (#168, ADR-0042)

/// Settings → Notifications: the "Back to work!" notification (#160, ADR-0039) — a master switch, the
/// allowed-hours window with a live duration, and a weekend-suppress picker.
struct NotificationsPane: View {
    @Bindable var model: SettingsModel

    /// A stable anchor day for the time pickers — only the hour/minute are ever read back, so the
    /// calendar day is arbitrary. Fixed once per view so the picker's `Date` doesn't drift across days.
    @State private var anchor = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Back to work")
                        Spacer()
                        // "Try" fires the notification on demand for verification (#193). It sits
                        // before the on/off switch and is enabled only while the feature is on and a
                        // banner could actually be delivered (see `tryBackToWorkEnabled`).
                        Button("Try") { model.tryBackToWork() }
                            .disabled(!model.tryBackToWorkEnabled)
                        Toggle("Back to work", isOn: Binding(
                            get: { model.backToWorkEnabled },
                            set: { model.setBackToWork($0) }))
                        .labelsHidden()
                        .disabled(!model.backToWorkMasterEnabled)
                    }
                    SettingsHint(
                        text: "If you hit a Claude usage limit, notifies you when it resets so you "
                            + "can get back to work.")
                    SettingsHint(text: model.backToWorkHint, warning: !model.backToWorkHint.isEmpty)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Extra Usage Credit", isOn: Binding(
                        get: { model.extraUsageNotifyEnabled },
                        set: { model.setExtraUsageNotify($0) }))
                    .disabled(!model.backToWorkMasterEnabled)
                    SettingsHint(
                        text: "Notifies you the moment work starts running on paid Extra Usage Credit "
                            + "— with the amount spent and your limit, if set.")
                }

                // The allowed-hours window and weekend-suppress apply to every notification — shown when
                // any is on, hidden (not just disabled) otherwise.
                if model.anyNotificationEnabled {
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
        }
        .formStyle(.grouped)
        // Show/hide dependent rows without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.anyNotificationEnabled)
    }
}
