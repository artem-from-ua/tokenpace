import SwiftUI

// MARK: - InsightsPane (#242)

/// Settings → Insights: the usage journal (#242) — the append-only record of every poll that the
/// downstream Insights features (#238) read back. One opt-in toggle; the file lives in Application
/// Support and needs no user-chosen destination (unlike the session-log archiver, it copies numbers,
/// not transcripts).
struct InsightsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Record usage history", isOn: Binding(
                    get: { model.journalEnabled },
                    set: { model.setJournalEnabled($0) }))
            } footer: {
                Text("Saves each usage reading to a local file so future charts can show trends over "
                   + "time. The data stays on this Mac and never leaves it.")
            }
        }
        .formStyle(.grouped)
    }
}
