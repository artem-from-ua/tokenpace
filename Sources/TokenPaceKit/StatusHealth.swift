import Foundation

// MARK: - ServiceStatus

/// The semantic, user-facing state of one Claude service component — the popup's status line is
/// built entirely from this.
///
/// It collapses the raw Statuspage strings (`operational`, `degraded_performance`, …) into the
/// distinctions the popup renders, with no locale-dependent text of its own: the human word and
/// the indicator colour are assembled in `PopupViewController` (the localisation seam), exactly
/// like ``FailureReason`` / ``PacingState`` (ADR-0009, ADR-0013).
///
/// The ``init(rawAPIValue:)`` map is the **single** place raw strings become semantics. An
/// unrecognised value maps to ``unknown`` — a forward-compatible bucket, not a build break, since
/// the set of statuses is the server's to grow, not ours.
public enum ServiceStatus: Sendable, Equatable {
    /// `operational` — the component is healthy (green).
    case operational
    /// `degraded_performance` — slow or partially impaired (yellow).
    case degraded
    /// `partial_outage` — some requests failing (orange).
    case partialOutage
    /// `major_outage` — the component is down (red).
    case majorOutage
    /// `under_maintenance` — planned work in progress (blue).
    case underMaintenance
    /// An unrecognised raw status **or** the state the shell substitutes when our own fetch
    /// failed (network/decode): an honest "we don't know" (grey), never a false `operational`.
    case unknown

    /// Map one raw Statuspage `status` string to its semantic state. The only string→enum seam.
    public init(rawAPIValue raw: String) {
        switch raw {
        case "operational": self = .operational
        case "degraded_performance": self = .degraded
        case "partial_outage": self = .partialOutage
        case "major_outage": self = .majorOutage
        case "under_maintenance": self = .underMaintenance
        default: self = .unknown
        }
    }

    /// Whether this state is anything other than fully healthy — i.e. worth surfacing as a
    /// menu-bar dot (ADR-0013). `unknown` counts as a problem: "we don't know" is not "fine".
    public var isProblem: Bool { self != .operational }

    /// Severity ranking for "worst of several" comparisons (higher = more severe). The order
    /// mirrors how a user would triage: a maintenance window or an unknown state is milder than an
    /// observed degradation, which is milder than an outage. `operational` is the floor.
    /// Exhaustive `switch`, no `default` — a new case must be ranked consciously.
    var severity: Int {
        switch self {
        case .operational:      return 0
        case .underMaintenance: return 1
        case .unknown:          return 2
        case .degraded:         return 3
        case .partialOutage:    return 4
        case .majorOutage:      return 5
        }
    }
}

// MARK: - StatusHealth

/// The two service states the popup renders, one line each — the pure result of mapping a
/// ``StatusSummary`` (or a failed fetch) into semantics.
///
/// The two components are **independent**: each gets its own line with its own colour dot, with
/// no aggregation into a single "overall" state (ADR-0013). Incidents, the overall indicator, and
/// scheduled maintenances are deliberately not part of this type — they are not decoded at all.
///
/// A failed status poll does not produce a distinct value: the shell maps any ``StatusFetchError``
/// to ``unknown`` (both components grey), because the UI for "service is unknown" and "we couldn't
/// reach the status page" is identical — an honest grey `unknown` line — so the type need not carry
/// a separate failure flag.
public struct StatusHealth: Sendable, Equatable {
    /// State of the `Claude Code` component (the CLI product infrastructure: login, updater,
    /// model routing).
    public let claudeCode: ServiceStatus
    /// State of the `Claude API (api.anthropic.com)` component (the inference backend the CLI
    /// calls — 5xx/429/529 in the CLI mean this is degraded).
    public let claudeAPI: ServiceStatus

    public init(claudeCode: ServiceStatus, claudeAPI: ServiceStatus) {
        self.claudeCode = claudeCode
        self.claudeAPI = claudeAPI
    }

    /// Both components unknown — the value the shell substitutes when a status poll fails
    /// (network or decode), so the popup shows two honest grey `unknown` lines.
    public static let unknown = StatusHealth(claudeCode: .unknown, claudeAPI: .unknown)

    /// The most severe non-operational state across the two components, or `nil` when **both** are
    /// operational. Drives the menu-bar status dot (ADR-0013): `nil` → no dot; otherwise the dot
    /// takes this state's colour. `unknown` counts (we surface "don't know" rather than hide it).
    public var worstProblem: ServiceStatus? {
        let worst = claudeCode.severity >= claudeAPI.severity ? claudeCode : claudeAPI
        return worst.isProblem ? worst : nil
    }

    /// The two component names we track, matched verbatim against the API's `components[].name`.
    static let claudeCodeName = "Claude Code"
    static let claudeAPIName = "Claude API (api.anthropic.com)"

    /// The status page the popup's status word links to (ADR-0013). Force-unwrapped: a literal
    /// constant whose failure would be a programmer error, not a runtime condition.
    public static let pageURL = URL(string: "https://status.claude.com")!

    // MARK: from

    /// Map one decoded summary to the two component states. A component absent from `components[]`
    /// (Anthropic renamed or removed it) maps to ``ServiceStatus/unknown`` rather than silently
    /// defaulting to operational. Every other component in the array is ignored.
    public static func from(_ summary: StatusSummary) -> StatusHealth {
        StatusHealth(
            claudeCode: status(of: claudeCodeName, in: summary),
            claudeAPI: status(of: claudeAPIName, in: summary)
        )
    }

    /// The semantic status of the named component, or ``ServiceStatus/unknown`` if it is not
    /// present in the array.
    private static func status(of name: String, in summary: StatusSummary) -> ServiceStatus {
        guard let component = summary.components.first(where: { $0.name == name }) else {
            return .unknown
        }
        return ServiceStatus(rawAPIValue: component.status)
    }
}

// MARK: - StatusFetchError

/// Why a status poll failed — a narrow error type kept distinct from ``UsageError`` so a status
/// failure never escalates the usage-API 429 backoff or surfaces auth detail. The shell catches it
/// and substitutes ``StatusHealth/unknown``; it never reaches the view verbatim.
public enum StatusFetchError: Error, Equatable {
    /// A transport/connectivity failure (offline, TLS, timeout, DNS, non-HTTP response).
    case transport(String)
    /// A non-2xx HTTP status, or a 200 body that did not decode as a ``StatusSummary``.
    case decode
}
