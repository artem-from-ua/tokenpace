import SwiftUI
import AppKit

// MARK: - AboutPane (#168, ADR-0041)

/// Settings → About: a header (app icon + name + tagline, System Settings-style), version + source
/// link, and the Updates card (#37) — the daily-check toggle, Check Now, the nested "Install updates
/// automatically" toggle, and the update-available row.
struct AboutPane: View {
    @Bindable var model: SettingsModel

    /// The app icon for the header — the app's own icon, exactly as Launchpad/Dock show it
    /// (`NSApp.applicationIconImage`): the custom icon once the bundle has one, or the system's default
    /// grid placeholder until then. On a bare `swift run` dev build this resolves to a folder-looking
    /// image (no bundle), but in the real `.app` it is the proper app icon.
    private static var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSWorkspace.shared.icon(for: .application)
    }

    /// One-line description of what TokenPace is, shown under the app name (System Settings shows the
    /// same kind of tagline under its pane title).
    private static let tagline =
        "A minimal, unobtrusive menu-bar companion for agentic coding. It surfaces exactly what you "
        + "need — usage, limits and budgets across Claude Code (more coming) — so you pace yourself "
        + "and stay productive without leaving your flow."

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("TokenPace")
                        .font(.title2).bold()
                    Text(Self.tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

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
                // The periodic-check switch, with "Check Now" as a trailing button on the same row.
                LabeledContent {
                    HStack(spacing: 10) {
                        Button("Check Now") { model.checkForUpdatesNow() }
                        Toggle("", isOn: Binding(
                            get: { model.automaticUpdateChecks },
                            set: { model.setAutomaticUpdateChecks($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                } label: {
                    Text("Check for updates periodically")
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
                        // Only the dev-build ⚠️ note remains; the enabled description was dropped.
                        if model.installAutoHint.devBuild {
                            SettingsHint(text: model.installAutoHint.text, warning: true)
                        }
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
        // Show/hide the dependent row without an insertion animation — otherwise the neighbouring row
        // visibly changes height during the transition (SwiftUI Form quirk).
        .animation(nil, value: model.automaticUpdateChecks)
    }
}
