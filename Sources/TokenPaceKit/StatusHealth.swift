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

// MARK: - ServiceID

/// A stable, rename-agnostic identifier for one logical service (#89). Its components carry the
/// matching names; the popup maps each component to a short display label in the view
/// (ADR-0009/0013: display text lives in the view, semantics in the kit), so the labels can change
/// without touching the persisted config or this enum.
public enum ServiceID: Sendable, Equatable {
    /// "Claude API" — the `Claude API (api.anthropic.com)` component. Present whenever anything at
    /// all is monitored, and locked on in the UI while it is (#341): the usage poll talks to this
    /// endpoint, and the other services are unreadable without knowing whether the API is up. It goes
    /// away only in the state where the user has turned everything off.
    case claudeAPI
    /// "Claude Code" — the `Claude Code` component (CLI product infrastructure: login, updater,
    /// model routing).
    case claudeCode
    /// "Claude WEB/Desktop" — `claude.ai`, plus `Claude Cowork` in the cowork mode.
    case webDesktop
    /// "Development services" — GitHub's `Git Operations`, `API Requests`, `Issues`, `Pull Requests`
    /// and `Actions` under one switch (#454). The first service of a **second provider**, which is
    /// why ``StatusHealth/pageURL(for:)`` exists: its rows link to `githubstatus.com`.
    case githubDevelopment

    /// Which provider this service belongs to — the popup groups its sections by this, and the
    /// journal tags its records with it.
    public var provider: ProviderID {
        switch self {
        case .claudeAPI, .claudeCode, .webDesktop: return .claude
        case .githubDevelopment:                   return .github
        }
    }
}

// MARK: - ProviderID

/// Which upstream a logical service belongs to (#454).
///
/// A provider is "one status page plus, optionally, a usage API": Claude has both, GitHub has only
/// the status page. The distinction matters wherever a value that used to be global becomes
/// per-provider — the popup's section headers, the poll cadence, the journal's records.
///
/// The raw values are stable snake-case strings **on purpose**: they are written into the usage
/// journal, where they outlive any build, exactly like ``ServiceStatus``'s journal spelling.
public enum ProviderID: String, Sendable, Equatable, Codable, CaseIterable {
    case claude
    case github

    /// The provider's name as the popup's section header shows it.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .github: return "GitHub"
        }
    }
}

// MARK: - ResolvedComponent

/// One status-page component within a logical service: its matching name (kit-side semantics,
/// compared verbatim against `components[].name`) and its current ``ServiceStatus``. The popup
/// renders one row per component, mapping this name to a short display label.
public struct ResolvedComponent: Sendable, Equatable {
    /// The component's matching name (verbatim against the API). This is **not** the popup's display
    /// label — it is the technical constituent name (e.g. `"Claude Cowork"`) the view maps to a short
    /// label via `displayName`.
    public let name: String
    /// The semantic status of this component.
    public let status: ServiceStatus
    /// When this component last changed status, from `components[].updated_at` — so the popup can
    /// show how long it has been degraded, or how recently it recovered (#279).
    ///
    /// `nil` when the API omitted it or it would not parse; the row then shows no age rather than a
    /// made-up one. Taken from the API rather than measured locally on purpose: a self-measured clock
    /// would reset on relaunch, in the middle of outages that run for hours.
    public let changedAt: Date?

    public init(name: String, status: ServiceStatus, changedAt: Date? = nil) {
        self.name = name
        self.status = status
        self.changedAt = changedAt
    }

    /// How long this component has held its current status at `now`, or `nil` when unknown.
    public func stateAge(at now: Date) -> TimeInterval? {
        changedAt.map { max(0, now.timeIntervalSince($0)) }
    }
}

// MARK: - ServiceCheck

/// One logical service resolved against a concrete ``StatusSummary``: its identifier, named
/// constituents, and an aggregated worst-of-N status.
///
/// This is a semantic descriptor (ADR-0013 §3, generalised): the kit reports **what** the service
/// covers (id + components + aggregate), the view decides how to render it. The popup iterates the
/// `components` (one row each); the aggregate ``status`` feeds nothing in the popup today but is the
/// worst-of-N a service-level summary would use, and mirrors how ``StatusHealth/worstProblem`` ranks
/// across all components for the menu-bar dot.
public struct ServiceCheck: Sendable, Equatable {
    /// Which logical service.
    public let id: ServiceID
    /// The constituents in display order, each with its own status — the popup renders one row each.
    public let components: [ResolvedComponent]

    public init(id: ServiceID, components: [ResolvedComponent]) {
        self.id = id
        self.components = components
    }

    /// Worst-of-N across the constituents via ``ServiceStatus/severity`` (ADR-0013 §8). An empty
    /// `components` (should not happen for a well-formed `from`) reads as `.unknown`.
    public var status: ServiceStatus {
        components.map(\.status).max(by: { $0.severity < $1.severity }) ?? .unknown
    }
}

// MARK: - StatusHealth

/// The state of every **enabled** Claude logical service — the pure result of mapping a
/// ``StatusSummary`` (or a failed fetch) against a ``MonitoredServices`` config (#89).
///
/// Was: two fixed component dots. Now: a collection of resolved services. Each carries its named
/// constituents (plus an aggregated worst-of-N), so the popup draws one row per component, while the
/// menu bar shows one dot that is the worst across all enabled services (ADR-0024).
///
/// `Claude API` is present as the first check whenever anything is monitored — the usage poll or
/// either toggleable service (#341). It has no switch of its own: enabling anything implies it, and
/// the only configuration without it is "monitor nothing", which yields an empty `checks`.
///
/// A failed status poll does not produce a distinct value: the shell maps any ``StatusFetchError``
/// to ``unknown(for:)`` (every enabled component grey), because the UI for "service is unknown" and
/// "we couldn't reach the status page" is identical — an honest grey `unknown` line — so the type
/// need not carry a separate failure flag.
public struct StatusHealth: Sendable, Equatable {
    /// The resolved logical services in display order (`Claude API`, then `Claude Code`, then
    /// `Claude WEB/Desktop` — the enabled ones). Contains the `Claude API` check whenever anything is
    /// monitored, and is empty only when the user has turned monitoring off entirely (#341).
    public let checks: [ServiceCheck]

    public init(checks: [ServiceCheck]) {
        self.checks = checks
    }

    /// The most severe non-operational state across **all** components of **all** enabled services
    /// (worst-of-all, including the cowork constituent only when the mode adds it), or `nil` when
    /// everything is operational. Drives the menu-bar status dot (ADR-0024): `nil` → no dot;
    /// otherwise the dot takes this state's colour. `unknown` counts (we surface "don't know").
    ///
    /// The signature is unchanged from the two-component era (`ServiceStatus?`), so the menu-bar
    /// and cadence consumers (`MenuBarLayout`, `StatusCadence`, `App`) need no change.
    public var worstProblem: ServiceStatus? {
        let worst = checks.flatMap(\.components).map(\.status).max(by: { $0.severity < $1.severity })
        return worst.flatMap { $0.isProblem ? $0 : nil }
    }

    // MARK: per-provider

    /// The checks belonging to one provider, in display order.
    public func checks(of provider: ProviderID) -> [ServiceCheck] {
        checks.filter { $0.id.provider == provider }
    }

    /// Whether this provider is monitored at all in this health — i.e. it contributed any check.
    /// The popup uses it to decide whether to draw the provider's section header.
    public func monitors(_ provider: ProviderID) -> Bool {
        checks.contains { $0.id.provider == provider }
    }

    /// The worst state across one provider's components, **including `operational`** — the value the
    /// popup's section-header dot draws (#454).
    ///
    /// Deliberately **not** `worstProblem`'s shape. That one returns `nil` when everything is fine,
    /// because the menu-bar dot disappears on a calm state (ADR-0013 §8) — silence is the answer
    /// there. A section header answers a different question: it labels a section that is *present*,
    /// so it must say "healthy" out loud rather than by omission. Returns `nil` only when the
    /// provider contributes no components at all, which is "not monitored", not "fine".
    public func aggregate(of provider: ProviderID) -> ServiceStatus? {
        checks(of: provider).flatMap(\.components).map(\.status)
            .max(by: { $0.severity < $1.severity })
    }

    /// The worst **problem** for one provider, or `nil` when that provider is calm — the per-provider
    /// twin of ``worstProblem``.
    ///
    /// This is what a per-provider poll cadence must read: `StatusCadence`'s problem floor drops the
    /// interval to 60 s, and feeding it the app-wide ``worstProblem`` would let a Claude incident
    /// accelerate polling against GitHub's third-party page — the exact impoliteness the floor exists
    /// to prevent (#454, #455).
    public func worstProblem(of provider: ProviderID) -> ServiceStatus? {
        aggregate(of: provider).flatMap { $0.isProblem ? $0 : nil }
    }

    // MARK: matching names

    /// The component names we match verbatim against the API's `components[].name` (kit-side
    /// semantics). `public` so the view can map a resolved component back to its short display label
    /// (`displayName`), keeping the human strings in the view — ADR-0009/0013.
    public static let claudeAPIComponentName = "Claude API (api.anthropic.com)"
    public static let claudeCodeComponentName = "Claude Code"
    public static let claudeWebComponentName = "claude.ai"
    public static let claudeCoworkComponentName = "Claude Cowork"

    /// The five GitHub components behind the single `Development services` logical service (#454),
    /// verbatim against `components[].name` on `githubstatus.com`.
    ///
    /// They are **one** service rather than five switches because they answer one question — "is my
    /// development workflow working" — and splitting them would ask the user to classify an outage
    /// before knowing what broke. The worst-of-5 is the answer; the rows behind it say which part.
    ///
    /// The feed carries seven more components (`Copilot`, `Copilot AI Model Providers`, `Packages`,
    /// `Pages`, `Codespaces`, `Webhooks`, and a non-service row literally named `Visit
    /// www.githubstatus.com for more information`). None is monitored and none needs filtering:
    /// matching is by exact name, so a component we never ask for is never selected.
    public static let githubGitOperationsComponentName = "Git Operations"
    public static let githubAPIRequestsComponentName = "API Requests"
    public static let githubIssuesComponentName = "Issues"
    public static let githubPullRequestsComponentName = "Pull Requests"
    public static let githubActionsComponentName = "Actions"

    /// The constituents of `Development services`, in display order.
    static let githubDevelopmentComponentNames = [
        githubGitOperationsComponentName,
        githubAPIRequestsComponentName,
        githubIssuesComponentName,
        githubPullRequestsComponentName,
        githubActionsComponentName,
    ]

    /// The status page the popup's status word links to (ADR-0013). Force-unwrapped: a literal
    /// constant whose failure would be a programmer error, not a runtime condition.
    ///
    /// Kept under its original name and value so every existing call site reads unchanged;
    /// ``pageURL(for:)`` is the one that knows there is more than one page (#454).
    public static let pageURL = URL(string: "https://status.claude.com")!

    /// GitHub's status page — the link target for `Development services` rows.
    public static let githubPageURL = URL(string: "https://www.githubstatus.com")!

    /// GitHub's summary endpoint — the same Statuspage v2 shape Claude's page serves, which is what
    /// lets `StatusSummary` decode both without a second decoder.
    ///
    /// Declared here beside the page it belongs to rather than in `StatusClient`: the client is being
    /// made endpoint-agnostic in #455, so the URL is a property of the *provider*, not of the client.
    public static let githubEndpoint = URL(string: "https://www.githubstatus.com/api/v2/summary.json")!

    /// The status page a logical service belongs to. Per **provider**, not per app: the popup turns
    /// the status word into a link, and a GitHub row pointing at Anthropic's page would be a dead end.
    public static func pageURL(for id: ServiceID) -> URL {
        switch id {
        case .claudeAPI, .claudeCode, .webDesktop: return pageURL
        case .githubDevelopment:                   return githubPageURL
        }
    }

    // MARK: from

    /// Map a decoded summary to the enabled logical services. A component absent from `components[]`
    /// (Anthropic renamed or removed it) maps to ``ServiceStatus/unknown`` rather than silently
    /// defaulting to operational (ADR-0013 §1). Every other component in the array is ignored.
    public static func from(
        _ summary: StatusSummary,
        config: MonitoredServices,
        usageApiEnabled: Bool = true
    ) -> StatusHealth {
        StatusHealth(checks: checks(for: config, usageApiEnabled: usageApiEnabled) { name in
            guard let component = summary.components.first(where: { $0.name == name }) else {
                return (.unknown, nil)
            }
            return (ServiceStatus(rawAPIValue: component.status), ResetClock.parse(component.updatedAt))
        })
    }

    /// The value the shell substitutes when a status poll fails (network or decode): every enabled
    /// component grey, so the popup shows honest `unknown` lines for exactly the services being
    /// monitored. Depends on the config (which services/components exist), so it is a function, not
    /// a `static let`.
    public static func unknown(for config: MonitoredServices, usageApiEnabled: Bool = true) -> StatusHealth {
        StatusHealth(checks: checks(for: config, usageApiEnabled: usageApiEnabled) { _ in (.unknown, nil) })
    }

    /// The component names a config resolves to — the join key ``IncidentVisibility`` intersects an
    /// incident's `components[]` against to decide "is this incident mine" (#279).
    ///
    /// Derived from ``checks(for:statusOf:)``, the same single source of truth that builds the popup
    /// rows, rather than re-listing the names: a service added there must never silently fail to
    /// filter incidents here. `StatusHealthTests` pins the two together for every config permutation.
    ///
    /// Matching is by **name**, deliberately — not by the `code`/`id` Statuspage also emits. ADR-0013
    /// §1 chose names as the single identity axis; a second one would need an id↔name map maintained
    /// against Anthropic's renames. The accepted cost: a renamed component stops matching, so its
    /// incidents quietly stop showing (the service line already degrades to `unknown` in that case).
    public static func monitoredComponentNames(
        for config: MonitoredServices,
        usageApiEnabled: Bool = true
    ) -> Set<String> {
        Set(
            checks(for: config, usageApiEnabled: usageApiEnabled) { _ in (.unknown, nil) }
                .flatMap(\.components).map(\.name))
    }

    // MARK: - GitHub (#454)

    /// Map GitHub's status summary to its logical services. The GitHub twin of ``from(_:config:)``,
    /// and a **separate** function on purpose: the two providers publish two different pages, so a
    /// single summary can never resolve both. Each poll produces its provider's checks; the shell
    /// merges them into one ``StatusHealth`` (see ``merging(_:)``).
    public static func fromGitHub(_ summary: StatusSummary, config: GitHubMonitoring) -> StatusHealth {
        StatusHealth(checks: githubChecks(for: config) { name in
            guard let component = summary.components.first(where: { $0.name == name }) else {
                return (.unknown, nil)
            }
            return (ServiceStatus(rawAPIValue: component.status), ResetClock.parse(component.updatedAt))
        })
    }

    /// What the shell substitutes when a **GitHub** status poll fails: its components grey, and
    /// nothing said about Claude. The isolation is the point — an unreachable `githubstatus.com` is
    /// no evidence about `status.claude.com`.
    public static func unknownGitHub(for config: GitHubMonitoring) -> StatusHealth {
        StatusHealth(checks: githubChecks(for: config) { _ in (.unknown, nil) })
    }

    /// GitHub's component names — the same join key ``IncidentVisibility`` needs to decide whether a
    /// GitHub incident is one of ours. Derived from ``githubChecks(for:statusOf:)``, so a change to
    /// the group cannot silently fail to filter incidents.
    public static func monitoredGitHubComponentNames(for config: GitHubMonitoring) -> Set<String> {
        Set(githubChecks(for: config) { _ in (.unknown, nil) }.flatMap(\.components).map(\.name))
    }

    /// The single source of truth for GitHub's services — the twin of ``checks(for:statusOf:)``.
    private static func githubChecks(
        for config: GitHubMonitoring,
        statusOf: (String) -> (status: ServiceStatus, changedAt: Date?)
    ) -> [ServiceCheck] {
        guard config.developmentServicesEnabled else { return [] }
        let components = githubDevelopmentComponentNames.map { name -> ResolvedComponent in
            let resolved = statusOf(name)
            return ResolvedComponent(name: name, status: resolved.status, changedAt: resolved.changedAt)
        }
        return [ServiceCheck(id: .githubDevelopment, components: components)]
    }

    // MARK: - merging

    /// This health with `other`'s checks appended — how two providers, polled independently on two
    /// cadences, become the one value the menu bar and popup read (#454).
    ///
    /// Checks of the providers present in `other` are **replaced**, not accumulated: a fresh GitHub
    /// poll supersedes the previous GitHub checks and leaves Claude's alone. That is what lets one
    /// provider's poll fail, retry and recover without ever touching the other's rows — and it keeps
    /// the merge idempotent, so re-applying the same poll changes nothing.
    public func merging(_ other: StatusHealth) -> StatusHealth {
        let replaced = Set(other.checks.map(\.id.provider))
        let kept = checks.filter { !replaced.contains($0.id.provider) }
        // Provider order is display order: Claude first, then GitHub — the popup renders sections in
        // the order the checks arrive, and a merge must not shuffle them by who polled last.
        let merged = (kept + other.checks).sorted {
            ProviderID.allCases.firstIndex(of: $0.id.provider)!
                < ProviderID.allCases.firstIndex(of: $1.id.provider)!
        }
        return StatusHealth(checks: merged)
    }

    /// The single source of truth for **which** services and constituents exist under a config —
    /// shared by ``from(_:config:)`` and ``unknown(for:)``, which differ only in how each
    /// component's status is obtained (`statusOf`: from a summary, vs the constant `.unknown`).
    ///
    /// `Claude API` is emitted as the first check whenever **anything** is monitored — the usage poll
    /// (`usageApiEnabled`) or either toggleable service (#341); `Claude Code` and `Claude WEB/Desktop`
    /// follow when their flags are set, WEB/Desktop adding `Claude Cowork` in the cowork mode. With
    /// everything off the result is empty, which is what makes "monitor nothing" representable.
    ///
    /// `usageApiEnabled` arrives as a separate argument rather than a field of `config` on purpose:
    /// it belongs to ``ProviderMonitoring``, not to the status-page config (whose docblock says
    /// exactly what it holds). It defaults to `true` so the many call sites that only care about
    /// services — tests included — read unchanged.
    private static func checks(
        for config: MonitoredServices,
        usageApiEnabled: Bool = true,
        statusOf: (String) -> (status: ServiceStatus, changedAt: Date?)
    ) -> [ServiceCheck] {
        func component(_ name: String) -> ResolvedComponent {
            let resolved = statusOf(name)
            return ResolvedComponent(name: name, status: resolved.status, changedAt: resolved.changedAt)
        }
        let monitoring = ProviderMonitoring(usageApiEnabled: usageApiEnabled, services: config)
        var checks: [ServiceCheck] = []
        if monitoring.claudeApiLocked {
            checks.append(ServiceCheck(id: .claudeAPI, components: [
                component(claudeAPIComponentName),
            ]))
        }
        if config.claudeCodeEnabled {
            checks.append(ServiceCheck(id: .claudeCode, components: [
                component(claudeCodeComponentName),
            ]))
        }
        if config.webDesktopEnabled {
            var components = [
                component(claudeWebComponentName),
            ]
            if config.webDesktopMode == .chatAndCowork {
                components.append(component(claudeCoworkComponentName))
            }
            checks.append(ServiceCheck(id: .webDesktop, components: components))
        }
        return checks
    }
}

// MARK: - StatusFetchError

/// Why a status poll failed — a narrow error type kept distinct from ``UsageError`` so a status
/// failure never escalates the usage-API 429 backoff or surfaces auth detail. The shell catches it
/// and substitutes ``StatusHealth/unknown``; it never reaches the view verbatim.
///
/// Only **one** code is modelled individually — `429` — because it is the only one the caller reacts
/// to differently: it feeds the status source's own ``PollingBackoff`` hold (ADR-0119). Everything
/// else still collapses into ``decode``, deliberately: a status page carries no auth detail and no
/// per-code meaning for us beyond "not 200".
public enum StatusFetchError: Error, Equatable {
    /// A transport/connectivity failure (offline, TLS, timeout, DNS, non-HTTP response).
    case transport(String)
    /// HTTP 429. Carries the parsed `Retry-After` seconds when the server sent them in the
    /// delta-seconds form, so the status source's backoff can hold for exactly that long; `nil`
    /// (absent, malformed, or the HTTP-date form) → the backoff's own 180 s default.
    ///
    /// Mirrors ``UsageError/rateLimited(retryAfter:)`` in shape, but is a **separate** value in a
    /// **separate** error type: a rate-limited status page must never advance the usage backoff, nor
    /// the other way round.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-2xx HTTP status, or a 200 body that did not decode as a ``StatusSummary``.
    case decode
}
