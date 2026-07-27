import SwiftUI

// MARK: - AboutPane (#168, ADR-0041)

/// Settings → About: version + source link, and the Updates card (#37) — the daily-check toggle,
/// Check Now, the nested "Install updates automatically" toggle, and the update-available row.
struct AboutPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text(model.versionText).foregroundStyle(.secondary)
                }
                LabeledContent("Source code") {
                    Button(SettingsLinks.repoDisplay) { model.openRepo() }
                        .buttonStyle(.link)
                }
            }

            Section {
                Toggle("Check for updates periodically", isOn: Binding(
                    get: { model.automaticUpdateChecks },
                    set: { model.setAutomaticUpdateChecks($0) }))

                LabeledContent("Check for updates now") {
                    Button("Check Now") { model.checkForUpdatesNow() }
                }

                // Only meaningful when periodic checks are on — hidden entirely otherwise (not just
                // disabled), so the card shows only what applies.
                if model.automaticUpdateChecks {
                    VStack(alignment: .leading, spacing: 4) {
                        // When the feature can't work (a dev build), show the switch as OFF regardless
                        // of the stored value — an on-but-disabled switch reads as "it's on" when it
                        // isn't. The stored choice is preserved; it just isn't reflected while unusable.
                        Toggle("Install updates automatically", isOn: Binding(
                            get: { model.installAutoEnabled && model.installAutomatically },
                            set: { model.setInstallAutomatically($0) }))
                        .disabled(!model.installAutoEnabled)
                        SettingsHint(text: model.installAutoHint.text, warning: model.installAutoHint.devBuild)
                    }
                }

                if let release = model.latestRelease {
                    LabeledContent {
                        Button("Download") { model.openDownload() }
                            .buttonStyle(.link)
                    } label: {
                        Text("Update available: \(release.tagName)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
