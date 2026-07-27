import SwiftUI

// MARK: - SessionLogsPane (#168, ADR-0042)

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
                    // Label on the leading edge; the path control + Choose button sit together on the
                    // trailing edge (the path control is right-aligned before the button, not stretched
                    // across the whole row). Native NSPathControl — folder icon + name, self-truncating,
                    // click → Finder (ADR-0040).
                    LabeledContent("Destination") {
                        HStack(spacing: 8) {
                            PathControlView(url: destinationURL)
                            Button("Choose…") { model.chooseArchiveFolder() }
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

    private var destinationURL: URL? {
        guard let path = model.archiveDestination else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
