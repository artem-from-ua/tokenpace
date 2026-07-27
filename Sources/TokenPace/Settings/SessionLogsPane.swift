import SwiftUI

// MARK: - SessionLogsPane (#168, ADR-0041)

/// Settings → Session Logs: the raw-log archiver (#110, ADR-0031) — enable, destination folder,
/// and the "Last archived …" status with an on-demand Archive Now.
struct SessionLogsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Archive session logs to a folder", isOn: Binding(
                    get: { model.archiveEnabled },
                    set: { model.setArchiveEnabled($0) }))

                LabeledContent("Destination") {
                    HStack(spacing: 8) {
                        Text(destinationDisplay)
                            .foregroundStyle(model.archiveDestination == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { model.chooseArchiveFolder() }
                            .disabled(!model.archiveEnabled)
                    }
                }

                LabeledContent {
                    Button("Archive Now") { model.archiveNow() }
                        .disabled(!(model.archiveEnabled && model.archiveDestination != nil))
                } label: {
                    Text(model.archiveStatusText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var destinationDisplay: String {
        guard let path = model.archiveDestination else { return "No folder selected" }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
