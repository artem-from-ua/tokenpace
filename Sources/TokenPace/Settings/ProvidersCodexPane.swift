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
/// The quota switch leads, as it does on Claude's page — it is what the bars are drawn from, and the
/// services below it explain an outage rather than fill a bar. It stays off by default all the same:
/// watching a status page is an HTTP GET against a public URL, while reading the quota runs `codex` on
/// this Mac, which is a different class of act and is asked for rather than assumed.
///
/// The rows are generated from `StatusHealth.codexServices`, the same table that resolves the feed —
/// a switch here cannot name a service the poll does not monitor.
struct ProvidersCodexPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Collect subscription quota", isOn: Binding(
                    get: { model.codexMonitoring.usageEnabled },
                    set: { model.setCodexUsage($0) }))
                // ⚠️-class, and it names the condition rather than the feature: the collector works,
                // the endpoint it reads does not yet behave. A weekly window has been observed
                // reporting 0 % with a reset that advances on every request, and returning to its
                // previous figure hours later — so a reading here can be wrong until OpenAI settles it.
                SettingsHint(
                    text: "Experimental. OpenAI's usage endpoint currently reports a weekly window "
                        + "that can read as empty and then return to its previous figure, so these "
                        + "numbers may be wrong until they fix it.",
                    warning: true)
            } header: {
                SectionHeaderWithHint(title: "Token limits usage",
                                      hint: model.stubScenarioActive ? SettingsStubHint.text : nil)
            } footer: {
                SettingsHint(
                    text: "TokenPace runs the installed codex command to read your plan's usage. "
                        + "Nothing is sent anywhere, and your account email is never read.")
            }

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
