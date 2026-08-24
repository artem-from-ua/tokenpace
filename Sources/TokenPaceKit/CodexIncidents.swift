import Foundation

// MARK: - CodexIncidentFeed

/// The body of `GET https://status.openai.com/proxy/status.openai.com/incidents` — the status page's
/// own frontend backend, and the **only** source that says which components an incident touched.
///
/// A narrow decoder of its own rather than an attempt to widen ``StatusIncident``. The two shapes
/// differ in almost every key that matters: `published_at` instead of `created_at`, `to_status`
/// instead of `status` on an update, a rich-text `message` object where Statuspage has a plain
/// `body`, `affected_components[].component_id` where Statuspage has a nested component array, and
/// two extra arrays (`component_impacts`, `status_summaries`) with no Statuspage analogue. Bending
/// one type over both would leave every field optional and every reader guessing which feed it came
/// from.
///
/// It also emits a status vocabulary of its own: `full_outage` where Statuspage says `major_outage`
/// (measured — both appear in ``codexRawStatus(_:)``'s map, and neither page uses the other's word).
///
/// **Undocumented, and load-bearing only for incidents.** It can change shape or disappear without
/// notice, so a failure here degrades: the statuses keep rendering from `components.json`, a separate
/// request, and Codex incident rows vanish.
public struct CodexIncidentFeed: Sendable, Equatable, Decodable {
    public let incidents: [CodexIncident]

    private enum CodingKeys: String, CodingKey { case incidents }

    public init(incidents: [CodexIncident]) { self.incidents = incidents }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.incidents = try container.decodeIfPresent([CodexIncident].self, forKey: .incidents) ?? []
    }
}

// MARK: - CodexIncident

/// One incident from the proxy feed.
public struct CodexIncident: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
    /// The incident's own workflow status (`resolved`, `investigating`, …) — the same vocabulary
    /// ``IncidentStage`` already maps.
    public let status: String
    /// When the incident was published. The proxy has no `started_at`; this is the row's age.
    public let publishedAt: String?
    /// Which components the incident touched, by id — the attribution `/api/v2/incidents.json` omits.
    public let affectedComponents: [CodexAffectedComponent]
    /// Per-component impact windows. `start_at` here is the age of a component's current state, the
    /// answer `components[].updated_at` cannot give (it is the page's edit stamp, identical on all).
    public let componentImpacts: [CodexComponentImpact]
    public let updates: [CodexIncidentUpdate]

    private enum CodingKeys: String, CodingKey {
        case id, name, status, updates
        case publishedAt = "published_at"
        case affectedComponents = "affected_components"
        case componentImpacts = "component_impacts"
    }

    public init(
        id: String,
        name: String,
        status: String,
        publishedAt: String? = nil,
        affectedComponents: [CodexAffectedComponent] = [],
        componentImpacts: [CodexComponentImpact] = [],
        updates: [CodexIncidentUpdate] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.publishedAt = publishedAt
        self.affectedComponents = affectedComponents
        self.componentImpacts = componentImpacts
        self.updates = updates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.status = try container.decode(String.self, forKey: .status)
        self.publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        // Every array hardens to `[]`: an incident missing one is still a usable row, and a
        // whole-feed failure over a cosmetic omission would cost the user every incident.
        self.affectedComponents =
            try container.decodeIfPresent([CodexAffectedComponent].self, forKey: .affectedComponents) ?? []
        self.componentImpacts =
            try container.decodeIfPresent([CodexComponentImpact].self, forKey: .componentImpacts) ?? []
        self.updates = try container.decodeIfPresent([CodexIncidentUpdate].self, forKey: .updates) ?? []
    }
}

// MARK: - CodexAffectedComponent

/// One component an incident affected, identified by id.
public struct CodexAffectedComponent: Sendable, Equatable, Decodable {
    public let componentID: String
    /// The status this incident drove the component to — the proxy's own vocabulary, mapped by
    /// ``CodexStatusMapping/serviceStatus(fromProxy:)``.
    public let status: String
    /// The component's status **now**, which is what decides whether the incident still hurts.
    public let currentStatus: String?

    private enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case status
        case currentStatus = "current_status"
    }

    public init(componentID: String, status: String, currentStatus: String? = nil) {
        self.componentID = componentID
        self.status = status
        self.currentStatus = currentStatus
    }
}

// MARK: - CodexComponentImpact

/// One component's impact window inside an incident: when this component entered the state and, if
/// it has left it, when.
public struct CodexComponentImpact: Sendable, Equatable, Decodable {
    public let componentID: String
    public let status: String
    /// When the component entered this state — a **server** timestamp, so it survives a relaunch and
    /// a fresh install, which a locally measured clock would not.
    public let startAt: String?
    /// When it left, or `nil` while the impact is still open.
    public let endAt: String?

    private enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case status
        case startAt = "start_at"
        case endAt = "end_at"
    }

    public init(componentID: String, status: String, startAt: String? = nil, endAt: String? = nil) {
        self.componentID = componentID
        self.status = status
        self.startAt = startAt
        self.endAt = endAt
    }
}

// MARK: - CodexIncidentUpdate

/// One update on a proxy incident. `to_status` is the stage (Statuspage calls it `status`), and
/// `message_string` is the plain-text rendering of the rich `message` object — which is why the
/// object itself is not modelled: it is a ProseMirror document, and its plain form is already beside
/// it.
public struct CodexIncidentUpdate: Sendable, Equatable, Decodable {
    public let id: String
    public let toStatus: String
    public let messageString: String?
    public let publishedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case toStatus = "to_status"
        case messageString = "message_string"
        case publishedAt = "published_at"
    }

    public init(id: String, toStatus: String, messageString: String? = nil, publishedAt: String? = nil) {
        self.id = id
        self.toStatus = toStatus
        self.messageString = messageString
        self.publishedAt = publishedAt
    }
}

// MARK: - CodexStatusMapping

/// Turns the proxy feed into the values the rest of the app already speaks — component ids into
/// names, the proxy's status words into ``ServiceStatus``, and an incident into a
/// ``VisibleIncident``.
public enum CodexStatusMapping {

    /// Map the proxy's component-status word to a ``ServiceStatus``.
    ///
    /// `full_outage` is the one word Statuspage does not use — this page says it where Statuspage
    /// says `major_outage` (measured: `full_outage` appears in the proxy feed, `major_outage` never
    /// does). Everything else is spelled identically, so the shared
    /// ``ServiceStatus/init(rawAPIValue:)`` handles it and an unrecognised word still buckets to
    /// `.unknown` rather than breaking the build.
    public static func serviceStatus(fromProxy raw: String) -> ServiceStatus {
        raw == "full_outage" ? .majorOutage : ServiceStatus(rawAPIValue: raw)
    }

    /// `component_id` → component name, from the same `components.json` the statuses come from.
    /// Verified against the captured feed: all 93 incidents resolve with **zero** unknown ids.
    public static func componentNames(in summary: StatusSummary) -> [String: String] {
        var map: [String: String] = [:]
        for component in summary.components {
            guard let id = component.id else { continue }
            map[id] = component.name
        }
        return map
    }

    /// When each monitored component last entered its current state, from the incidents' own
    /// `component_impacts[]`.
    ///
    /// Only **open** impacts count — one whose `end_at` is set describes a state the component has
    /// already left, so using its `start_at` would date the current (recovered) state from an
    /// incident that is over. The newest open impact per component wins, since a component can be
    /// touched by more than one live incident.
    public static func changedAt(
        in feed: CodexIncidentFeed,
        componentNames names: [String: String]
    ) -> [String: Date] {
        var newest: [String: Date] = [:]
        for incident in feed.incidents {
            for impact in incident.componentImpacts where impact.endAt == nil {
                guard let name = names[impact.componentID],
                      let start = ResetClock.parse(impact.startAt) else { continue }
                if let existing = newest[name], existing >= start { continue }
                newest[name] = start
            }
        }
        return newest
    }

    /// The incidents to render for Codex — the proxy feed put through the same gate
    /// ``IncidentVisibility`` applies to every other provider: closed ones dropped, ones touching
    /// none of the monitored components dropped, ones whose monitored components are all green
    /// dropped, and — when configured — ones too old to still be the answer to "can I work".
    ///
    /// - Parameters:
    ///   - feed: The decoded proxy body.
    ///   - componentNames: `component_id` → name, from ``componentNames(in:)``.
    ///   - monitored: The names this user watches — Codex's own, never crossed with another
    ///     provider's, since `CLI` and `API Requests` are names more than one page uses.
    public static func visibleIncidents(
        in feed: CodexIncidentFeed,
        componentNames names: [String: String],
        monitoredComponentNames monitored: Set<String>,
        now: Date,
        maxAge: TimeInterval? = nil
    ) -> [VisibleIncident] {
        feed.incidents.compactMap { incident in
            let stage = IncidentStage(rawAPIValue: incident.status)
            guard !stage.isClosed else { return nil }

            let mine = incident.affectedComponents.filter {
                names[$0.componentID].map(monitored.contains) ?? false
            }
            guard !mine.isEmpty else { return nil }

            // Worst-of over *my* components, read from `current_status` — the state right now, which
            // is what decides whether the incident is still hurting. `status` is what the incident
            // drove them to when it opened, and in the captured feed every resolved incident still
            // carries a red one beside a `current_status` of `operational`.
            let severity = mine
                .map { serviceStatus(fromProxy: $0.currentStatus ?? $0.status) }
                .max(by: { $0.severity < $1.severity }) ?? .unknown
            guard severity.isProblem else { return nil }

            let startedAt = ResetClock.parse(incident.publishedAt)
            if let maxAge, let startedAt, now.timeIntervalSince(startedAt) > maxAge { return nil }

            return VisibleIncident(
                id: incident.id,
                name: incident.name,
                stage: stage,
                severity: severity,
                // The proxy has no `shortlink`, so a Codex incident row carries no external link.
                shortlink: nil,
                startedAt: startedAt,
                updateIDs: incident.updates.map(\.id),
                latestUpdateBody: incident.updates.last?.messageString)
        }
    }
}
