import SwiftUI

// MARK: - SessionLogsPane (#168, ADR-0041)

/// Settings → Session Logs: the raw-log archiver (#110, ADR-0031) — enable, destination folder,
/// and the "Last archived …" status with an on-demand Archive Now.
struct SessionLogsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Archive session logs daily", isOn: Binding(
                    get: { model.archiveEnabled },
                    set: { model.setArchiveEnabled($0) }))

                // Destination + status are only relevant once archiving is on — hidden otherwise.
                if model.archiveEnabled {
                    LabeledContent("Destination") {
                        HStack(spacing: 8) {
                            Text(destinationDisplay)
                                .foregroundStyle(model.archiveDestination == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                // Take the available width and truncate inside it, so a long path can't
                                // push the button off the row.
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose…") { model.chooseArchiveFolder() }
                                .layoutPriority(1)
                        }
                    }

                    LabeledContent {
                        Button("Archive Now") { model.archiveNow() }
                            .disabled(model.archiveDestination == nil)
                    } label: {
                        Text(model.archiveStatusText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Show/hide the dependent rows without an insertion animation (avoids neighbour-height flicker).
        .animation(nil, value: model.archiveEnabled)
    }

    private var destinationDisplay: String {
        guard let path = model.archiveDestination else { return "No folder selected" }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
