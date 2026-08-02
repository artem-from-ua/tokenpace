import SwiftUI
import AppKit

// MARK: - AboutPane (#168, ADR-0042)

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

            // Identity: source, installed version, and (when newer exists) the availability row (#210).
            Section {
                LabeledContent("Source code") {
                    Button(SettingsLinks.repoDisplay) { model.openRepo() }
                        .buttonStyle(.link)
                }
                LabeledContent("Version") {
                    Text(model.versionText).foregroundStyle(.secondary)
                }

                if let release = model.latestRelease {
                    // "Release notes" sits by the label on the left; "Download" (the web release) is the
                    // trailing link on the right (#210). A blue status dot matches the dropdown's "new
                    // version available" item.
                    LabeledContent {
                        Button("Download") { model.openDownload() }
                            .buttonStyle(.link)
                    } label: {
                        HStack(spacing: 6) {
                            UpdateStatusDot(role: .blue)
                            Text("New version available: \(SettingsModel.displayTag(release.tagName))")
                            Button("Release notes") { model.openReleaseNotes(tag: release.tagName) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }

            // Update behaviour: the check/install toggles, and (when it happened) the last failure.
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

                // The previous auto-update failed (#210): a red status dot (matching the dropdown's
                // "update failed" item), the version + stage, and the raw reason — so the user knows
                // *why* the background update didn't land. The reason is technical and can be long, so
                // it is selectable and allowed to wrap.
                if let failure = model.lastUpdateFailure {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            UpdateStatusDot(role: .red)
                            Text("Update to version \(SettingsModel.displayTag(failure.tag)) failed during \(failure.stage.displayName).")
                        }
                        .font(.callout)
                        Text("Reason: \(failure.reason)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        // Show/hide the dependent row without an insertion animation — otherwise the neighbouring row
        // visibly changes height during the transition (SwiftUI Form quirk).
        .animation(nil, value: model.automaticUpdateChecks)
    }
}

// MARK: - UpdateStatusDot

/// A small filled status dot for an About-pane update row (#210), tinted from the **same**
/// `ColorStore` roles the dropdown's update item uses (`blue` for "available",
/// `red` for "failed") — so the two surfaces read as one signal.
private struct UpdateStatusDot: View {
    let role: ColorRole

    var body: some View {
        Circle()
            .fill(Color(nsColor: ColorStore.shared.color(role)))
            .frame(width: 8, height: 8)
    }
}
