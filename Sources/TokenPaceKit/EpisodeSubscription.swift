import Foundation

// MARK: - EpisodeSubscription

/// The persisted state of the user's subscription to the **current episode** (#279).
///
/// An episode is "something I depend on is broken", not a Statuspage ticket. That shape came from
/// how the feature is actually reached: a user subscribes when they can see their own services are
/// down, and they have no way of knowing which of several concurrent incidents is the one hurting
/// them. So one control covers everything currently wrong, and incidents that open while it is live
/// are swept in without asking again.
///
/// This supersedes ADR-0071 §5's per-incident subscription, and with it the ADR's open questions #1
/// (several simultaneous incidents) and #6 (where the per-incident icon lives) — neither arises once
/// there is a single control.
public struct EpisodeSubscription: Sendable, Equatable, Codable {
    /// Whether the user is currently following. `false` is the whole default state: nothing is ever
    /// delivered until they ask (ADR-0071 §5 — opt-in on click, no global toggle).
    public var isFollowing: Bool
    /// Update ids already accounted for, so a banner fires once per genuine update.
    ///
    /// Deduplicating by id rather than by content is deliberate: updates are edited retroactively
    /// (`71wxpw067nx2` was created 07:05 and edited 09:13), so a content- or timestamp-based key
    /// would replay an old update as new (ADR-0071 §7).
    public var seenUpdateIDs: Set<String>
    /// When the episode first looked over — the debounce anchor. `nil` whenever it does not.
    ///
    /// Components flap: on 2026-08-05 they went green at 13:08, red again at 13:51 (through a
    /// *different* incident), then green. Announcing recovery on the first green poll would have
    /// produced a false all-clear, so the end has to hold for a while before it counts.
    public var pendingEndSince: Date?

    public init(
        isFollowing: Bool = false,
        seenUpdateIDs: Set<String> = [],
        pendingEndSince: Date? = nil
    ) {
        self.isFollowing = isFollowing
        self.seenUpdateIDs = seenUpdateIDs
        self.pendingEndSince = pendingEndSince
    }

    /// The state a fresh install (or a closed episode) sits in.
    public static let none = EpisodeSubscription()

    /// Decode defensively so an older or truncated blob degrades to "not following" rather than
    /// failing — the worst case must be a missed banner, never a broken popup.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isFollowing = try container.decodeIfPresent(Bool.self, forKey: .isFollowing) ?? false
        self.seenUpdateIDs = try container.decodeIfPresent(Set<String>.self, forKey: .seenUpdateIDs) ?? []
        self.pendingEndSince = try container.decodeIfPresent(Date.self, forKey: .pendingEndSince)
    }
}

// MARK: - EpisodeEvent

/// Something worth telling a following user about.
public enum EpisodeEvent: Sendable, Equatable {
    /// A new `incident_updates[]` entry appeared on an incident in the episode.
    case update(incidentID: String, name: String, body: String, severity: ServiceStatus)
    /// The episode is over: either every monitored component is `operational` again, or every active
    /// incident has reached `monitoring`. Carries which of the two, because they mean different
    /// things to a user deciding whether to go back to work.
    case ended(reason: EpisodeEndReason)
}

/// Why an episode ended — the two conditions are genuinely different claims.
public enum EpisodeEndReason: Sendable, Equatable {
    /// Every monitored component is back to `operational`. The strong signal.
    case componentsGreen
    /// Every active incident reached `monitoring`: Anthropic says the fix is deployed and is watching,
    /// while components may still be yellow. Weaker, and the banner must not overstate it.
    case fixDeployed
}

// MARK: - EpisodeEvaluator

/// The pure state machine behind the subscribe row and its banners (#279).
///
/// Everything is a function of (previous state, this poll): no clocks read internally, no I/O, no
/// stored state of its own. The shell persists what comes back and posts what is returned, which
/// makes the entire notification decision unit-testable without mocking `UNUserNotificationCenter` —
/// the same split as `WorkAvailability` + `NotificationSchedule` for "Back to work!".
public enum EpisodeEvaluator {

    /// How long the end condition must hold before it is announced (ADR-0071 open question #4).
    ///
    /// 90 seconds is a provisional default, deliberately: it is a parameter of ``evaluate`` rather
    /// than a constant here, so retuning it once the dev payload log has watched a real incident is a
    /// one-line change with the tests already written. It will not catch the measured 43-minute flap
    /// — nothing short of an unusable delay would — but it does absorb single-poll noise at the
    /// 60-second problem cadence, which is the failure mode that would otherwise fire a false
    /// all-clear.
    public static let defaultDebounce: TimeInterval = 90

    /// What the popup's subscribe row should show, given what is visible right now.
    ///
    /// - Returns: `nil` when there is nothing to subscribe to, so the row is omitted entirely rather
    ///   than shown inert.
    public static func rowState(
        incidents: [VisibleIncident],
        subscription: EpisodeSubscription
    ) -> EpisodeSubscriptionState? {
        guard !incidents.isEmpty else { return nil }
        // Every active incident has a fix deployed → the episode is over for subscription purposes,
        // whatever the components still say. Offering "notify me when it's fixed" here would be
        // offering to answer a question already answered.
        if incidents.allSatisfy({ $0.stage.isFixDeployed }) { return .fixDeployed }
        return subscription.isFollowing ? .subscribed : .notSubscribed
    }

    /// Fold one poll into the subscription state.
    ///
    /// - Parameters:
    ///   - subscription: The persisted state from the previous poll.
    ///   - incidents: What ``IncidentVisibility`` says is visible now.
    ///   - now: Injected instant.
    ///   - debounce: How long the end condition must hold (see ``defaultDebounce``).
    /// - Returns: The banners to post and the state to persist. The state is returned **regardless**
    ///   of whether the user is following, so toggling the feature on or off never replays or forgets
    ///   an edge — the discipline `detectBackToWorkEdge` already follows.
    public static func evaluate(
        subscription: EpisodeSubscription,
        incidents: [VisibleIncident],
        now: Date,
        debounce: TimeInterval = defaultDebounce
    ) -> (events: [EpisodeEvent], next: EpisodeSubscription) {
        var next = subscription
        var events: [EpisodeEvent] = []

        // Nothing visible at all — either everything recovered or the incidents aged out. Either way
        // the episode is over.
        guard !incidents.isEmpty else {
            if subscription.isFollowing {
                return endIfHeld(
                    subscription: next, reason: .componentsGreen, now: now, debounce: debounce)
            }
            return ([], .none)
        }

        // Every active incident is in `monitoring`: the fix is out and Anthropic is watching. This is
        // the second way an episode ends, added on top of ADR-0071 §6's components-only signal —
        // measured to arrive earlier than components going green, and it is the moment the user
        // actually wants to hear about.
        if incidents.allSatisfy({ $0.stage.isFixDeployed }), subscription.isFollowing {
            return endIfHeld(subscription: next, reason: .fixDeployed, now: now, debounce: debounce)
        }

        // Still broken: any pending end was a blip (the 13:08→13:51 flap), so clear the anchor.
        next.pendingEndSince = nil

        guard subscription.isFollowing else {
            // Not following: track nothing, remember nothing. Seeding `seenUpdateIDs` happens at
            // subscribe time (`follow`), so a click never fires a banner for history already on screen.
            return ([], next)
        }

        // One event per genuinely new update, oldest-first — incidents in API order, updates in theirs.
        for incident in incidents {
            for id in incident.updateIDs where !next.seenUpdateIDs.contains(id) {
                next.seenUpdateIDs.insert(id)
                // Only the newest update carries text worth showing; older unseen ones (a poll that
                // missed a window) are folded in silently rather than fired as a burst of stale news.
                if id == incident.updateIDs.last, let body = incident.latestUpdateBody {
                    events.append(.update(
                        incidentID: incident.id, name: incident.name,
                        body: body, severity: incident.severity))
                }
            }
        }
        return (events, next)
    }

    /// Start following everything currently broken.
    ///
    /// Seeds `seenUpdateIDs` with every update already visible, so subscribing never immediately
    /// notifies about text the user just read in the popup.
    public static func follow(incidents: [VisibleIncident]) -> EpisodeSubscription {
        EpisodeSubscription(
            isFollowing: true,
            seenUpdateIDs: Set(incidents.flatMap(\.updateIDs)),
            pendingEndSince: nil)
    }

    /// Stop following. Returns the empty state: an episode the user walked away from leaves nothing
    /// behind to replay if they subscribe again later.
    public static func unfollow() -> EpisodeSubscription { .none }

    /// Announce the end once the condition has held for `debounce`; otherwise start (or keep) the
    /// anchor and stay quiet.
    private static func endIfHeld(
        subscription: EpisodeSubscription,
        reason: EpisodeEndReason,
        now: Date,
        debounce: TimeInterval
    ) -> (events: [EpisodeEvent], next: EpisodeSubscription) {
        guard let since = subscription.pendingEndSince else {
            var next = subscription
            next.pendingEndSince = now
            return ([], next)
        }
        guard now.timeIntervalSince(since) >= debounce else { return ([], subscription) }
        return ([.ended(reason: reason)], .none)
    }
}
