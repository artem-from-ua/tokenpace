import Foundation

// MARK: - StatusComponent

/// One entry of the `components[]` array from `GET https://status.claude.com/api/v2/summary.json`
/// (Statuspage.io summary format).
///
/// `status` is the **raw** API string — `operational`, `degraded_performance`, `partial_outage`,
/// `major_outage`, or `under_maintenance`. It is deliberately **not** mapped to a semantic enum
/// here: that mapping lives in exactly one place, ``ServiceStatus/init(rawAPIValue:)``, so this
/// layer stays a thin, allocation-free decode (mirrors how ``UsageWindow`` forwards its raw
/// `resets_at` string to ``ResetClock``).
///
/// Statuspage emits many more per-component keys (`id`, `position`, `group_id`, `showcase`, …);
/// `Decodable` ignores unknown keys, so they are tolerated without any work.
public struct StatusComponent: Sendable, Equatable, Decodable {
    /// Human-readable component name, matched verbatim against the two we care about
    /// (`"Claude Code"`, `"Claude API (api.anthropic.com)"`) in ``StatusHealth/from(_:)``.
    public let name: String
    /// Raw Statuspage status string, forwarded verbatim to ``ServiceStatus/init(rawAPIValue:)``.
    public let status: String
    /// Raw `updated_at` — when this component last **changed status**, so `now - updatedAt` is how
    /// long it has been in its current state (#279: the age shown before the popup's status word).
    ///
    /// Verified against seven captured payloads: the timestamp moves exactly when `status` changes
    /// and holds still across polls while the status is unchanged (`14:14:35` persisted through four
    /// consecutive summaries). That is why the age needs **no** persisted "when we first saw it red"
    /// of our own — and so it survives a restart mid-outage, which a self-measured clock would not.
    ///
    /// Optional: a component predating the field, or a malformed value, must not fail the summary —
    /// the row then simply shows no age. Parsed by ``ResetClock/parse(_:)`` at the view seam (it
    /// already strips the fractional seconds Statuspage emits).
    public let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case name, status
        case updatedAt = "updated_at"
    }

    public init(name: String, status: String, updatedAt: String? = nil) {
        self.name = name
        self.status = status
        self.updatedAt = updatedAt
    }
}

// MARK: - StatusIncidentUpdate

/// One entry of an incident's `incident_updates[]` — a timestamped human note from Anthropic.
///
/// Only the fields that are actually used are modeled, and the omissions are deliberate (ADR-0071
/// measured each one and rejected it):
///
/// - **`affected_components`** — rejected alternative F: recovery is sometimes **silent** (in
///   `mgp99sn4ynd4` the components went green with no update at all), so an updates-driven listener
///   would have stayed quiet for 43 minutes. Recovery comes from ``StatusComponent/status``.
/// - **`deliver_notifications`** — rejected alternative G: inconsistent. It was `false` on the
///   `resolved` update of `bdr3fq2rkchr`, i.e. exactly the event a user waits for.
/// - **`updated_at`** — updates are edited retroactively (`71wxpw067nx2`: created 07:05, updated
///   09:13), so it would replay a banner with stale content. Identity is ``id``, not time.
///
/// Modeling a field invites the next reader to trust it; these three must stay unmodeled.
public struct StatusIncidentUpdate: Sendable, Equatable, Decodable {
    /// Stable identity of this update — the **only** deduplication key (ADR-0071 §7).
    public let id: String
    /// Raw workflow status this update carried (`investigating`, `identified`, `monitoring`, …).
    public let status: String
    /// The human-readable note. Source of banner **text**, never a trigger.
    public let body: String
    /// Raw `created_at` timestamp.
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, status, body
        case createdAt = "created_at"
    }

    public init(id: String, status: String, body: String, createdAt: String? = nil) {
        self.id = id
        self.status = status
        self.body = body
        self.createdAt = createdAt
    }
}

// MARK: - StatusIncident

/// One entry of `incidents[]` from the summary endpoint — an incident as **context**, never as a
/// source of service state (ADR-0071 §1 narrows, but does not repeal, ADR-0013 §2: the dots and
/// words still come solely from `components[].status`).
///
/// `components[]` inside an incident is a **live mirror** of the top-level array, not a snapshot of
/// how things were when the incident opened: verified byte-identical in the captured payloads, and
/// in `03-monitoring-green` a still-open incident lists every component as `operational`. So it
/// answers "is this incident hurting me *right now*" — and must **never** be read as historical
/// evidence of how severe the incident once was.
///
/// `monitoring_at` is deliberately unmodeled (rejected alternative E): populated in only 28 of 49
/// incidents, and in `bdr3fq2rkchr` the components went green under `investigating` anyway.
public struct StatusIncident: Sendable, Equatable, Decodable {
    /// Stable Statuspage identity.
    public let id: String
    /// The incident's headline — and its **only** descriptive text. Statuspage has no separate
    /// description field; everything else lives in ``incidentUpdates``.
    public let name: String
    /// Raw workflow status (`investigating`, `identified`, `monitoring`, `postmortem`, `resolved`).
    public let status: String
    /// Raw `impact` (`none`, `minor`, `major`, `critical`). Decoded but **unused**: measured to
    /// correlate poorly with real pain — both 2026-08-05 incidents were `minor` while part of the
    /// models were unusable for six hours (ADR-0071 open question #5).
    public let impact: String?
    /// Permalink to this specific incident. Kept as a `String`, not a `URL`: a malformed value must
    /// degrade to "no link" rather than fail the whole summary decode.
    public let shortlink: String?
    /// Raw `started_at` — the incident's own age (what the popup row shows), not the age of its
    /// current stage.
    public let startedAt: String?
    /// Raw `created_at`, the fallback when `started_at` is absent.
    public let createdAt: String?
    /// Raw `resolved_at`. Present for bookkeeping only — **not** a recovery signal: it lags the
    /// components going green by 6 min (median) to 480 min (max), 66 min in the live measurement
    /// (rejected alternative D).
    public let resolvedAt: String?
    /// The components this incident lists, carrying their **current** status (see the type doc).
    public let components: [StatusComponent]
    /// The incident's updates, oldest-first as the API returns them.
    public let incidentUpdates: [StatusIncidentUpdate]

    private enum CodingKeys: String, CodingKey {
        case id, name, status, impact, shortlink, components
        case startedAt = "started_at"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
        case incidentUpdates = "incident_updates"
    }

    public init(
        id: String,
        name: String,
        status: String,
        impact: String? = nil,
        shortlink: String? = nil,
        startedAt: String? = nil,
        createdAt: String? = nil,
        resolvedAt: String? = nil,
        components: [StatusComponent] = [],
        incidentUpdates: [StatusIncidentUpdate] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.impact = impact
        self.shortlink = shortlink
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.components = components
        self.incidentUpdates = incidentUpdates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.status = try container.decode(String.self, forKey: .status)
        self.impact = try container.decodeIfPresent(String.self, forKey: .impact)
        self.shortlink = try container.decodeIfPresent(String.self, forKey: .shortlink)
        self.startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        self.createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        self.resolvedAt = try container.decodeIfPresent(String.self, forKey: .resolvedAt)
        // Both arrays harden to `[]` the way `StatusSummary.components` does: an incident that
        // arrives without them is still a usable row (name + stage), and a whole-summary failure
        // here would grey out every service line for a cosmetic omission.
        self.components = try container.decodeIfPresent([StatusComponent].self, forKey: .components) ?? []
        self.incidentUpdates =
            try container.decodeIfPresent([StatusIncidentUpdate].self, forKey: .incidentUpdates) ?? []
    }
}

// MARK: - StatusSummary

/// Decoded, immutable result of one successful poll of the Claude status page.
///
/// `components[]` drives **all** service state — the dots, the words, the menu-bar indicator
/// (ADR-0013 §2). That has not changed: no incident field (`status`, `impact`, `resolved_at`) may
/// ever influence a service's rendered state.
///
/// `incidents[]` is decoded too (ADR-0071 §1 narrows ADR-0013 §2) as a **second, separate layer**:
/// incidents answer "what exactly is broken and for how long", which a per-component colour cannot.
/// The summary endpoint already carries them in full — including each incident's `components[]` and
/// `incident_updates[]` — so no second request is needed. (The design note's claim that
/// `components[]` is populated only in `unresolved.json` holds for `incidents.json`, **not** for
/// `summary.json`, which is the only endpoint TokenPace calls.)
///
/// Still **not** decoded: `status` (overall indicator), `scheduled_maintenances[]` (ADR-0071 open
/// question #5 — a maintenance window is only interesting if it falls inside the user's active
/// hours, which is separate logic), and `page`. `Decodable` drops them for free.
///
/// The custom ``init(from:)`` hardens both arrays: an omitted array decodes to `[]` rather than
/// failing the whole summary (mirrors ``UsageSnapshot``'s handling of `limits`). The memberwise
/// initializer is kept so tests can build fixtures directly.
public struct StatusSummary: Sendable, Equatable, Decodable {
    public let components: [StatusComponent]
    /// Every incident the page currently lists, including already-`resolved` ones it has not yet
    /// dropped. Filtering to what the user should actually see is ``IncidentVisibility``'s job, not
    /// the decoder's.
    public let incidents: [StatusIncident]

    private enum CodingKeys: String, CodingKey {
        case components, incidents
    }

    public init(components: [StatusComponent], incidents: [StatusIncident] = []) {
        self.components = components
        self.incidents = incidents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An omitted/`null` `components` array decodes to `[]` instead of failing — a malformed
        // summary then yields two `.unknown` lines (honest "don't know") rather than a hard error.
        self.components = try container.decodeIfPresent([StatusComponent].self, forKey: .components) ?? []
        // Same hardening, and it matters more here: incidents are a context layer, so a malformed
        // `incidents[]` must cost the user their incident rows — never their service status.
        self.incidents = try container.decodeIfPresent([StatusIncident].self, forKey: .incidents) ?? []
    }
}
