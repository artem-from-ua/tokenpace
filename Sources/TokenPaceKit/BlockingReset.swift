import Foundation

// MARK: - BlockingReset

/// Which single exhausted limit's reset the UI should surface as the **blocking** one — the reset
/// that actually unblocks work (#158). Produced by ``BlockingReset/select(tokenWindows:creditsReset:)``
/// from the "last-stand" (credits-priority) rule below; a `nil` result means nothing is blocking.
///
/// The dropdown highlights this one reset in **red** (all other resets stay neutral, even when their
/// own limit is also at 100 %); the menu bar shows the **same** chosen reset as its countdown in the
/// blocked state. Both views read this one decision so they never disagree.
///
/// ## The "last stand" rule (credits reset priority)
/// You can work again the moment **any** path back opens. Paid extra-usage credits are the *last
/// stand*: when they are available and do **not** reset last, their reset is the **soonest** real
/// way back (once they reset there is money headroom again), so it wins. But when credits reset
/// **last** — typically the end of the calendar month, far past the token windows — the token limits
/// (5h / 7d) return you to work sooner, so the **latest token** reset wins instead. When credits are
/// not in play at all, the rule collapses to the latest exhausted token reset.
///
/// Concretely, over the exhausted resets `5` (5h), `7` (7d), `e` (credits):
/// ```
/// e present (credits active):
///     e is not the latest  →  e          (credits are the fastest way back)
///     e is the latest      →  max(5, 7)  (tokens return sooner than a far-off credits reset)
/// e absent                 →  max(5, 7)  (credits are not an option)
/// ```
public enum BlockingReset: Sendable, Equatable {

    // MARK: - Candidate

    /// One exhausted limit that is currently blocking work, paired with its reset instant. `id` is an
    /// opaque token the caller uses to map the winner back to a UI element (a popup row index, a
    /// window kind, …) — this type never interprets it.
    public struct TokenCandidate: Sendable, Equatable {
        /// Caller-defined identity of the row/window this reset belongs to.
        public let id: Int
        /// The reset instant of this exhausted token window.
        public let resetsAt: Date

        public init(id: Int, resetsAt: Date) {
            self.id = id
            self.resetsAt = resetsAt
        }
    }

    // MARK: - Result

    /// The chosen blocking reset — either a token window (carrying the caller's `id`) or the credits
    /// window. `Date` is the chosen reset instant, so the menu bar can format a countdown directly.
    public enum Choice: Sendable, Equatable {
        /// A token window (5h / 7d / per-model) identified by the caller's opaque `id`.
        case token(id: Int, resetsAt: Date)
        /// The extra-usage money-credits window (its reset is `CreditsPacing.monthEnd`).
        case credits(resetsAt: Date)

        /// The chosen reset instant, regardless of which kind won.
        public var resetsAt: Date {
            switch self {
            case let .token(_, at): return at
            case let .credits(at): return at
            }
        }
    }

    // MARK: - select

    /// Apply the last-stand rule to the currently-exhausted candidates.
    ///
    /// - Parameters:
    ///   - tokenWindows: Every exhausted **token** limit (5h / 7d / per-model, each `utilization >= 100`)
    ///     with a resolved reset instant. Order does not matter; the latest is picked internally.
    ///   - creditsReset: The credits reset instant (`CreditsPacing.monthEnd`) **iff** credits are in
    ///     play as an escape hatch (`CreditsPacing.isActive`), else `nil`. When `nil`, `e` is absent
    ///     and the rule uses the latest token reset.
    /// - Returns: The one reset to surface in red / as the countdown, or `nil` when nothing blocks
    ///   (no exhausted token windows **and** no credits reset).
    public static func select(tokenWindows: [TokenCandidate], creditsReset: Date?) -> Choice? {
        // The latest-resetting exhausted token — the token that frees you last, and so the one that
        // matters once credits are out of the running.
        let latestToken = tokenWindows.max { $0.resetsAt < $1.resetsAt }

        guard let creditsReset else {
            // Credits not in play → the latest token reset (or nothing, if no tokens exhausted).
            return latestToken.map { .token(id: $0.id, resetsAt: $0.resetsAt) }
        }

        guard let latestToken else {
            // Only credits are exhausted → credits reset is the blocker.
            return .credits(resetsAt: creditsReset)
        }

        // Both credits and at least one token are in play. Credits win unless they reset *last*
        // (strictly later than every token): a credits reset at or before the latest token is the
        // sooner — or joint-sooner — way back, so it takes priority ("last stand").
        return creditsReset <= latestToken.resetsAt
            ? .credits(resetsAt: creditsReset)
            : .token(id: latestToken.id, resetsAt: latestToken.resetsAt)
    }

    // MARK: - Snapshot bridge

    /// The blocking reset for a **blocked** snapshot (#158) — the single decision both the popup (red
    /// badge) and the menu bar (countdown) read, so they always agree. Works for both the idle-blocked
    /// state and a fully-exhausted active state (see ``CreditsPacing/isBlocked(in:)``).
    ///
    /// Builds the candidate set from the snapshot and applies ``select(tokenWindows:creditsReset:)``:
    /// - **Token candidates** are every base/per-model window with `utilization >= 100`, each keyed by
    ///   its **popup row index** — `0` = 5h, `1` = 7d, then `sevenDayOpus`, `sevenDaySonnet`, and the
    ///   `scopedModelWindows` in order (the exact order `PopupLayout.rows` builds). A window whose
    ///   `resets_at` does not parse is dropped (it cannot anchor a countdown). In the idle state the 5h
    ///   window is gone (util 0), so index `0` never appears; in an active exhausted state the 5h window
    ///   at 100 % *is* a candidate.
    /// - **Credits** contribute their `monthEnd` reset **iff** `CreditsPacing.isActive` (the escape
    ///   hatch is in play); otherwise `creditsReset` is `nil` and the rule uses tokens only.
    ///
    /// Returns `nil` when nothing blocks (no exhausted token parsed **and** credits inactive).
    public static func forBlocked(snapshot: UsageSnapshot, now: Date) -> Choice? {
        var tokens: [TokenCandidate] = []
        func consider(_ index: Int, _ window: UsageWindow) {
            guard window.utilization >= 100, let at = ResetClock.parse(window.resetsAt) else { return }
            tokens.append(TokenCandidate(id: index, resetsAt: at))
        }
        consider(0, snapshot.fiveHour)
        consider(1, snapshot.sevenDay)
        var index = 2
        if let opus = snapshot.sevenDayOpus { consider(index, opus); index += 1 }
        if let sonnet = snapshot.sevenDaySonnet { consider(index, sonnet); index += 1 }
        for scoped in snapshot.scopedModelWindows { consider(index, scoped.window); index += 1 }

        let creditsReset: Date? = {
            guard let spend = snapshot.spend, CreditsPacing.isActive(spend) else { return nil }
            return CreditsPacing.monthEnd(now: now)
        }()

        return select(tokenWindows: tokens, creditsReset: creditsReset)
    }
}
