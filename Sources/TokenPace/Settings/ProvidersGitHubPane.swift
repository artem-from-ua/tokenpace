import SwiftUI
import TokenPaceKit

// MARK: - ProvidersGitHubPane (#454, ADR-0084/0085/0094)

/// Settings → Providers › GitHub: the one thing TokenPace does for GitHub — watch its status page.
///
/// The page is deliberately **half** of Claude's. There is no `Token limits usage` section because
/// GitHub publishes no subscription limit for the bars to draw, and none is planned: adding one to
/// restore symmetry would invent a quantity that does not exist.
///
/// There is no provider-level master switch either. On Claude's page a master switch would have to
/// mean either "collect usage" or "watch services", and whichever it meant the other would be the
/// surprise. Here the question does not arise for a different reason: with a single service, the
/// service switch **is** the provider switch, and a second control above it would just be the same
/// state written twice.
struct ProvidersGitHubPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Development services", isOn: Binding(
                        get: { model.githubDevelopmentServicesEnabled },
                        set: { model.setGitHubDevelopmentServices($0) }))
                    // Names the five constituents, because the switch aggregates them worst-of-5 and
                    // the popup shows only the ones that break. Without this the user would have to
                    // infer the group's membership from an outage.
                    SettingsHint(
                        text: "Git operations, API requests, issues, pull requests and Actions — "
                            + "what `gh` and the website depend on.")
                    // ⚠️-class hint: it reports a condition holding the feature back, like the
                    // Sessions-backup hints (#306). Shown only while the switch is off — with it on
                    // there is nothing being withheld to warn about.
                    if !model.githubDevelopmentServicesEnabled {
                        SettingsHint(
                            text: "With this off, GitHub is not monitored and never appears in the "
                                + "menu bar or the dropdown.",
                            warning: true)
                        .transition(SettingsRowReveal.transition)
                    }
                }
            } header: {
                // Same caveat as Claude's page: under a data stub the status page is never fetched,
                // so the switch picks between canned components rather than live ones (#187).
                SectionHeaderWithHint(title: "Monitored services",
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
            }
        }
        .formStyle(.grouped)
        .animation(SettingsRowReveal.animation, value: model.githubDevelopmentServicesEnabled)
    }
}
