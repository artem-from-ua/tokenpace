import Foundation

// MARK: - StubResolution

/// Pure, AppKit-free decision core for reading `TOKENPACE_STUB` (#267).
///
/// The scenario *registry* (`StubScenario`) has to live in the `TokenPace` target — every case owns a
/// `UsageTransport` and AppKit-facing display metadata. What can be tested in isolation, and is the
/// part that actually went wrong, is the **mapping rule**: given a raw env value and the kind of build,
/// which scenario runs, was it asked for deliberately, and was the value bogus. Keeping that rule here
/// follows the same pure-core / thin-shell split as ``LaunchAtLogin`` (ADR-0009, ADR-0010).
///
/// The bug this exists to prevent: `StubScenario(rawValue:) ?? .realNetwork` cannot distinguish
/// "nothing was requested" from "something unrecognized was requested", so a typo'd id resolved to the
/// live network. Every visible symptom still looked stubbed while the app polled production and read
/// the real `~/.claude` trees — a verification pass that silently means nothing.
public enum StubResolution {

    /// What a raw `TOKENPACE_STUB` value resolves to, independent of which scenario enum the caller uses.
    ///
    /// Generic over the scenario id so the pure core never needs to know the registry: the caller hands
    /// in the ids it recognizes and gets back the id to run.
    public struct Outcome: Equatable, Sendable {
        /// The id to drive the data source with — always one of the ids the caller supplied.
        public let id: String

        /// Whether this id was *asked for*: a recognized `TOKENPACE_STUB` value, or a plain `.app`
        /// launch with no env at all (production's normal mode). False when we fell back after a bad
        /// value, or when a dev build defaulted to the frozen frame.
        ///
        /// Gates anything that reads live user state — chiefly the awaiting-input watcher (#259),
        /// which scans the real `~/.claude` trees and must never come up on a live network nobody
        /// deliberately selected.
        public let isExplicit: Bool

        /// The unrecognized value that triggered the fallback, or `nil` on every normal path. Non-nil
        /// means the caller should warn: the run is *not* what was requested.
        public let unknownValue: String?

        public init(id: String, isExplicit: Bool, unknownValue: String?) {
            self.id = id
            self.isExplicit = isExplicit
            self.unknownValue = unknownValue
        }
    }

    /// Map a raw `TOKENPACE_STUB` value onto the id to run.
    ///
    /// An unrecognized value degrades **away** from live, onto the frozen screenshot frame, and reports
    /// the bad value. The one path that stays live by default is an installed `.app` with no env — a
    /// real user must see their own limits, not a canned frame.
    ///
    /// - Parameters:
    ///   - env: raw `TOKENPACE_STUB`; `nil` when the variable is absent entirely. An empty string is
    ///     *present but bogus* — no id may be empty (see `validate`).
    ///   - isAppBundle: whether this is an installed `.app` rather than a `swift run` dev build.
    ///   - liveID: the id meaning "real network".
    ///   - fallbackID: the id to run when there is nothing valid to run — the frozen screenshot frame.
    ///   - knownIDs: every id the registry recognizes.
    public static func resolve(
        env: String?,
        isAppBundle: Bool,
        liveID: String,
        fallbackID: String,
        knownIDs: [String]
    ) -> Outcome {
        guard let env else {
            // No env at all: production stays live; a dev build gets the reproducible frozen frame.
            return isAppBundle
                ? Outcome(id: liveID, isExplicit: true, unknownValue: nil)
                : Outcome(id: fallbackID, isExplicit: false, unknownValue: nil)
        }
        guard knownIDs.contains(env) else {
            return Outcome(id: fallbackID, isExplicit: false, unknownValue: env)
        }
        return Outcome(id: env, isExplicit: true, unknownValue: nil)
    }

    /// Whether a registry's ids can be resolved unambiguously: none empty, none duplicated.
    ///
    /// An empty id is the specific shape that caused #267 — it makes "absent env" and "this id" the
    /// same string, so intent becomes unrecoverable. Asserted by the test suite against the real
    /// registry, so re-introducing `case realNetwork = ""` fails the build's tests rather than
    /// silently restoring the bug.
    public static func idsAreResolvable(_ ids: [String]) -> Bool {
        !ids.contains(where: \.isEmpty) && Set(ids).count == ids.count
    }
}
