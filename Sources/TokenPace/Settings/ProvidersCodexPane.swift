import SwiftUI
import TokenPaceKit

// MARK: - ProvidersCodexPane (#503)

/// Settings → Providers › Codex: which of OpenAI's Codex surfaces TokenPace watches.
///
/// Five switches where GitHub's page has one. GitHub's components answer a single question through
/// entangled paths, so splitting them would ask the user to classify an outage before knowing what
/// broke. Codex's are separate surfaces — someone in the terminal and someone in Codex Web hit
/// different failures — so "CLI down, Web fine" is an action rather than noise.
///
/// No `Token limits usage` section yet: the quota half is declared in ``CodexMonitoring`` but nothing
/// reads it, and a switch over a collector that does not exist would be a promise the page cannot
/// keep.
///
/// The rows are generated from `StatusHealth.codexServices`, the same table that resolves the feed —
/// a switch here cannot name a service the poll does not monitor.
struct ProvidersCodexPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(StatusHealth.codexServices, id: \.id) { service in
                    Toggle(Self.title(service.component), isOn: Binding(
                        get: { model.codexMonitoring.isEnabled(service.id) },
                        set: { model.setCodexService(service.id, $0) }))
                }
                // ⚠️-class hint, like the Sessions-backup ones: it reports a condition holding the
                // feature back. Shown only with everything off — with anything on there is nothing
                // being withheld to warn about.
                if !model.codexMonitoring.isMonitoringAnything {
                    SettingsHint(
                        text: "With all of these off, Codex is not monitored and never appears in "
                            + "the menu bar or the dropdown.",
                        warning: true)
                    .transition(SettingsRowReveal.transition)
                }
            } header: {
                // Same caveat as the other provider pages: under a data stub the status page is never
                // fetched, so a switch picks between canned components rather than live ones (#187).
                SectionHeaderWithHint(title: "Monitored services",
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
            } footer: {
                // `Login` is on the same page and is deliberately absent: the feed carries it twice
                // under two different ids, so an exact-name match resolves to an arbitrary one of
                // them. Said here so its absence reads as a decision rather than an oversight.
                SettingsHint(
                    text: "OpenAI's status page also lists a Login component twice, under two "
                        + "different ids — TokenPace cannot tell them apart, so it watches neither.")
            }
        }
        .formStyle(.grouped)
        .animation(SettingsRowReveal.animation, value: model.codexMonitoring.isMonitoringAnything)
    }

    /// The switch's label — the feed's component name, with the ones that read as bare technical
    /// fragments spelled out. `CLI` alone under a `Codex` page title says which CLI.
    private static func title(_ component: String) -> String {
        switch component {
        case StatusHealth.codexAPIComponentName:            return "API"
        case StatusHealth.codexCLIComponentName:            return "CLI"
        case StatusHealth.codexVSCodeComponentName:         return "VS Code extension"
        case StatusHealth.codexWebComponentName:            return "Web"
        case StatusHealth.codexChatGPTDesktopComponentName: return "ChatGPT Desktop app"
        default:                                            return component
        }
    }
}
