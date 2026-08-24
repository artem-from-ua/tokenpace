import Foundation

// MARK: - CodexMonitoring

/// What TokenPace watches for the **Codex** provider (#503): five status-page services, plus the
/// usage half's switch declared here ahead of the collector that reads it.
///
/// Five flags rather than one group, unlike ``GitHubMonitoring``. GitHub's five components answer one
/// question through entangled paths — a `gh pr create` is `API Requests`, the page it prints is
/// `Pull Requests` — so splitting them would ask the user to classify an outage before knowing what
/// broke. Codex's are genuinely different surfaces: someone running `codex` in a terminal and someone
/// in Codex Web hit different failures, and "CLI red, Web green" is an action, not noise.
///
/// A **separate** persisted key, never folded into another provider's blob — the rule
/// `GitHubMonitoring` already states: an older build that rewrites the blob knows nothing of this
/// provider and would silently erase the user's choice.
///
/// There is no derived lock analogous to `ProviderMonitoring.claudeApiLocked`. That one exists
/// because Claude's usage poll talks to the very component `Claude API` reports on. Codex's quota
/// comes from a local `codex` subprocess, not from `Codex API`, so a lock here would assert a
/// dependency that does not exist.
public struct CodexMonitoring: Sendable, Equatable, Codable {
    public var apiEnabled: Bool
    public var cliEnabled: Bool
    public var vsCodeEnabled: Bool
    public var webEnabled: Bool
    public var chatGPTDesktopEnabled: Bool

    /// Whether the subscription-quota half is collected. Declared here, at default **false**, before
    /// anything reads it — so the `Codable` shape does not change a second time when the collector
    /// lands.
    ///
    /// Off by default while every status flag is on, and the asymmetry is the point: watching a
    /// status page is an HTTP GET against a public URL, while reading the quota spawns a process on
    /// the user's machine. That is a different class of action and should be asked for. The GitHub
    /// argument — that a monitor nobody enables reports nothing, which is the same as not shipping it
    /// — is answered differently here: onboarding detects an installed `codex` with credentials and
    /// offers to turn it on, so the feature is proposed at the moment it is visibly applicable rather
    /// than hidden in Settings.
    public var usageEnabled: Bool

    public init(
        apiEnabled: Bool = true,
        cliEnabled: Bool = true,
        vsCodeEnabled: Bool = true,
        webEnabled: Bool = true,
        chatGPTDesktopEnabled: Bool = true,
        usageEnabled: Bool = false
    ) {
        self.apiEnabled = apiEnabled
        self.cliEnabled = cliEnabled
        self.vsCodeEnabled = vsCodeEnabled
        self.webEnabled = webEnabled
        self.chatGPTDesktopEnabled = chatGPTDesktopEnabled
        self.usageEnabled = usageEnabled
    }

    /// The default: every status service on, the quota off.
    public static let `default` = CodexMonitoring()

    /// Whether one logical service is watched. The mapping is exhaustive over Codex's own cases and
    /// answers `false` for anyone else's, so `StatusHealth.codexChecks` can filter a shared table.
    public func isEnabled(_ id: ServiceID) -> Bool {
        switch id {
        case .codexAPI:             return apiEnabled
        case .codexCLI:             return cliEnabled
        case .codexVSCode:          return vsCodeEnabled
        case .codexWeb:             return webEnabled
        case .codexChatGPTDesktop:  return chatGPTDesktopEnabled
        case .claudeAPI, .claudeCode, .webDesktop, .githubDevelopment: return false
        }
    }

    /// The same switch, settable — what the Settings page binds each generated row to.
    public mutating func setEnabled(_ id: ServiceID, _ on: Bool) {
        switch id {
        case .codexAPI:            apiEnabled = on
        case .codexCLI:            cliEnabled = on
        case .codexVSCode:         vsCodeEnabled = on
        case .codexWeb:            webEnabled = on
        case .codexChatGPTDesktop: chatGPTDesktopEnabled = on
        case .claudeAPI, .claudeCode, .webDesktop, .githubDevelopment: break
        }
    }

    /// Whether this provider contributes any **status** check. `usageEnabled` is deliberately not
    /// part of it: the status loop asks this question to decide whether to poll a status page, and a
    /// quota switch is no reason to make that request.
    public var isMonitoringAnything: Bool {
        apiEnabled || cliEnabled || vsCodeEnabled || webEnabled || chatGPTDesktopEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case apiEnabled, cliEnabled, vsCodeEnabled, webEnabled, chatGPTDesktopEnabled, usageEnabled
    }

    /// Decode defensively, mirroring ``GitHubMonitoring/init(from:)``: an omitted key takes the
    /// default rather than failing the whole config, so a blob written by a build that predates a
    /// future key still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodexMonitoring.default
        self.apiEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiEnabled) ?? d.apiEnabled
        self.cliEnabled = try container.decodeIfPresent(Bool.self, forKey: .cliEnabled) ?? d.cliEnabled
        self.vsCodeEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .vsCodeEnabled) ?? d.vsCodeEnabled
        self.webEnabled = try container.decodeIfPresent(Bool.self, forKey: .webEnabled) ?? d.webEnabled
        self.chatGPTDesktopEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .chatGPTDesktopEnabled)
            ?? d.chatGPTDesktopEnabled
        self.usageEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .usageEnabled) ?? d.usageEnabled
    }
}
