import Foundation

// MARK: - StatusPayloadFingerprint

/// A digest of the **material** content of one status poll, so the dev payload log writes a line
/// only when something actually changed (ADR-0071 §10).
///
/// The status endpoint is polled every 60 s during an incident. Logging every response would bury
/// the handful of transitions worth studying under hundreds of identical payloads; logging only on a
/// changed fingerprint keeps the file readable and small enough to hand around.
///
/// ## What counts as material
///
/// - every component's `name:status` — the state the whole app is driven by;
/// - per incident: its `id`, its workflow `status`, and the set of `incident_updates[].id`.
///
/// ## What deliberately does not
///
/// Timestamps. `components[].updated_at` moves only when a status changes, so it adds nothing; and
/// incident updates are **edited retroactively** (`71wxpw067nx2`: created 07:05, updated 09:13), so
/// including `updated_at` would log a "change" that carries no new information. Identity is `id`.
///
/// ## Why the sorting is load-bearing
///
/// Statuspage does not guarantee array order. Without sorting, a reordered-but-identical payload
/// fingerprints differently and writes a duplicate line on **every poll** — which defeats the entire
/// purpose of the gate. The order-independence test is the one that matters most here.
public enum StatusPayloadFingerprint {

    /// The fingerprint of one decoded summary. Equal fingerprints mean "nothing worth recording
    /// changed"; the caller skips the write.
    public static func of(_ summary: StatusSummary) -> String {
        let components = summary.components
            .map { "\($0.name)=\($0.status)" }
            .sorted()
            .joined(separator: ";")

        let incidents = summary.incidents
            .map { incident in
                let updates = incident.incidentUpdates.map(\.id).sorted().joined(separator: ",")
                return "\(incident.id)=\(incident.status)[\(updates)]"
            }
            .sorted()
            .joined(separator: ";")

        return "c{\(components)}i{\(incidents)}"
    }
}
