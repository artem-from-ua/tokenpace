import Foundation

// MARK: - IncidentStage

/// Where an incident sits in Statuspage's own workflow — the word the popup row renders as the link
/// to that incident (`identified`, `monitoring`, …).
///
/// This is **not** a ``ServiceStatus``: it says what Anthropic is *doing about it*, never how broken
/// anything is. The two are deliberately separate types so a stage can never be mistaken for state
/// (ADR-0071 §1: colour comes from `components[].status`, always).
///
/// ``unknown(_:)`` carries the raw string forward rather than dropping it — the set of stages is the
/// server's to grow, and an unrecognised one should still render its word, mirroring how
/// ``ServiceStatus/init(rawAPIValue:)`` buckets instead of failing.
public enum IncidentStage: Sendable, Equatable {
    /// `investigating` — the cause is not yet known.
    case investigating
    /// `identified` — the cause is known, a fix is being worked on.
    case identified
    /// `monitoring` — a fix has been deployed and is being watched.
    case monitoring
    /// `resolved` — Anthropic has closed the incident.
    case resolved
    /// `postmortem` — a write-up has been published.
    case postmortem
    /// Any stage the API grows that this build does not know, carrying the raw value.
    case unknown(String)

    /// Map one raw Statuspage `status` string to a stage. The only string→enum seam.
    public init(rawAPIValue raw: String) {
        switch raw {
        case "investigating": self = .investigating
        case "identified":    self = .identified
        case "monitoring":    self = .monitoring
        case "resolved":      self = .resolved
        case "postmortem":    self = .postmortem
        default:              self = .unknown(raw)
        }
    }

    /// Whether Anthropic considers the incident closed. `postmortem` counts: the write-up follows a
    /// resolution, so the work is over.
    public var isClosed: Bool {
        switch self {
        case .resolved, .postmortem: return true
        case .investigating, .identified, .monitoring, .unknown: return false
        }
    }

    /// Whether a fix is deployed and merely being watched — one of the two ways an episode ends
    /// (see ``EpisodeState``). Kept as a property rather than an `== .monitoring` at call sites so
    /// the meaning is named where it is used.
    public var isFixDeployed: Bool { self == .monitoring }
}

// MARK: - VisibleIncident

/// One incident the popup should actually show — the render-ready result of
/// ``IncidentVisibility/visible(in:config:now:maxAge:)``.
///
/// Carries no formatted text: the age is a `Date` and the stage an enum, so the view owns every
/// human string (ADR-0009/0013 localisation seam), exactly like ``ServiceCheck``.
public struct VisibleIncident: Sendable, Equatable, Identifiable {
    /// Statuspage identity — also the key subscriptions and dedup work against.
    public let id: String
    /// The incident's only descriptive text (its `name`). The popup wraps it across as many lines
    /// as it needs; Statuspage has no separate description field.
    public let name: String
    /// Where it sits in the workflow — the linked word in the row.
    public let stage: IncidentStage
    /// How badly this incident is hurting the user's **monitored** services right now: worst-of over
    /// the incident's monitored components only.
    ///
    /// Deriving the dot colour from components (not from `impact`) keeps ADR-0071 §1's invariant
    /// literally true, and makes the dot mean "how much this affects *you*" rather than how Anthropic
    /// graded it — measured to correlate poorly anyway (both 2026-08-05 incidents were `minor` while
    /// models were failing for six hours).
    public let severity: ServiceStatus
    /// Permalink to this specific incident, or `nil` when absent/malformed. Resolves ADR-0071 §3's
    /// side-issue: today every affected component links to the same generic status page.
    public let shortlink: URL?
    /// When the incident began — the row shows its age. Not the age of the current stage.
    public let startedAt: Date?
    /// Every update id this incident carries, oldest-first. The dedup key for notifications
    /// (ADR-0071 §7): not the component transition (inconsistent) and not `updated_at` (edited
    /// retroactively).
    public let updateIDs: [String]
    /// The newest update's text, for the banner body. `nil` when the incident has no updates —
    /// which happens: recovery is sometimes entirely silent.
    public let latestUpdateBody: String?

    public init(
        id: String,
        name: String,
        stage: IncidentStage,
        severity: ServiceStatus,
        shortlink: URL? = nil,
        startedAt: Date? = nil,
        updateIDs: [String] = [],
        latestUpdateBody: String? = nil
    ) {
        self.id = id
        self.name = name
        self.stage = stage
        self.severity = severity
        self.shortlink = shortlink
        self.startedAt = startedAt
        self.updateIDs = updateIDs
        self.latestUpdateBody = latestUpdateBody
    }

    /// How long the incident has been running at `now`, or `nil` when its start is unknown.
    public func age(at now: Date) -> TimeInterval? {
        startedAt.map { max(0, now.timeIntervalSince($0)) }
    }
}

// MARK: - IncidentVisibility

/// The pure gate deciding **which** incidents the popup shows (#279, ADR-0071 §4 and §9).
///
/// A stateless namespace mirroring ``StatusHealth``: `Foundation` only, fully unit-tested, no I/O.
/// The shell calls it once per successful status poll and hands the result to the view.
///
/// The filter chain, in order — each step exists for a measured reason:
///
/// 1. **Closed incidents are dropped.** Statuspage keeps `resolved` incidents in `summary.json` for
///    a while; showing them contradicts "can I work right now".
/// 2. **Not mine → dropped** (§9). An incident is the user's if its `components[]` intersects the
///    names ``MonitoredServices`` resolves to. An incident naming no components cannot pass a filter
///    it carries no data for.
/// 3. **All my components green → dropped** (§4). The popup answers "can I work"; green means yes,
///    and a still-open incident does not argue otherwise. This matters in practice: the live
///    measurement sat 66 minutes in exactly this state, and the gap runs to 480 minutes.
/// 4. **Too old → dropped** (§9), when a maximum age is configured — the sample contained a "zombie"
///    open for 2741 minutes.
///
/// Steps 2 and 3 both read the incident's own `components[]`, which mirrors *live* status (see
/// ``StatusIncident``), so one pass answers both "is it mine" and "is it still hurting".
public enum IncidentVisibility {

    /// The incidents to render, in the order the API returned them.
    ///
    /// - Parameters:
    ///   - summary: The decoded poll.
    ///   - config: Which logical services the user monitors — the same config that builds the rows.
    ///   - now: Injected for determinism (never `Date()` in here).
    ///   - maxAge: Hide incidents older than this. `nil` = no limit.
    public static func visible(
        in summary: StatusSummary,
        config: MonitoredServices,
        now: Date,
        maxAge: TimeInterval? = nil
    ) -> [VisibleIncident] {
        let monitored = StatusHealth.monitoredComponentNames(for: config)
        return summary.incidents.compactMap { incident in
            let stage = IncidentStage(rawAPIValue: incident.status)
            guard !stage.isClosed else { return nil }

            // The incident's own components, narrowed to the ones this user monitors. Empty means
            // either "names nothing" or "names nothing of mine" — both are "not mine".
            let mine = incident.components.filter { monitored.contains($0.name) }
            guard !mine.isEmpty else { return nil }

            // Worst-of over *my* components. `.operational` here means the incident is no longer
            // hurting this user, whatever the ticket still says.
            let severity = mine
                .map { ServiceStatus(rawAPIValue: $0.status) }
                .max(by: { $0.severity < $1.severity }) ?? .unknown
            guard severity.isProblem else { return nil }

            let startedAt = ResetClock.parse(incident.startedAt ?? incident.createdAt)
            if let maxAge, let startedAt, now.timeIntervalSince(startedAt) > maxAge { return nil }

            return VisibleIncident(
                id: incident.id,
                name: incident.name,
                stage: stage,
                severity: severity,
                shortlink: incident.shortlink.flatMap(URL.init(string:)),
                startedAt: startedAt,
                updateIDs: incident.incidentUpdates.map(\.id),
                latestUpdateBody: incident.incidentUpdates.last?.body)
        }
    }
}
