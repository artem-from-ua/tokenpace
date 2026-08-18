import Foundation

// MARK: - ResetSource

/// Where a window's `resets_at` came from — the honesty carrier for the journal and Troubleshoot,
/// so a reader can tell a server fact from something this app derived.
///
/// **Orthogonal to ``WeeklyUtilization/Source``**, which describes where the *utilization* came
/// from. The two axes move independently: measured over 5 029 journal samples, six of the eight
/// (util-source × reset-source) intersections are populated, including `degraded × reconstructed`
/// — a percentage degraded by a polling hole sitting beside a date invented during an API blackout.
/// One field could not have told both stories, which is why `WindowSample` carries `utilSrc` and
/// `resetSrc` separately.
///
/// ## Why a reconstruction exists at all
///
/// At every weekly reset the usage API stops sending `seven_day.resets_at` — the window object
/// arrives `null` and the matching `limits[]` entry carries no date either — until the first token
/// spend materialises a new session. Measured: 4–6 hours, every week. The app used to fill that gap
/// with `now + 7d` recomputed each poll, which drifted forward with the clock and pinned the time
/// marker to zero for hours. Rolling the *last known real* reset forward instead lands within
/// ±0.25 s of the value the server eventually sends (verified on two independent journals, one Max
/// 5x and one Pro, whose reset grids differ). See ADR-0107.
///
/// ## The `-rolled` suffix
///
/// ``ResetClock/optimisticReset(_:now:)`` rolls a window forward the instant its reset passes, so
/// the countdown never shows a non-positive remaining while the app waits for the next response.
/// That overlay composes with whatever produced the date underneath it, so the suffix is carried
/// separately from the base rather than replacing it: `reconstructed-rolled` says *both* that we
/// derived the date and that it has since elapsed — two steps away from the last server fact, which
/// is exactly what a reader diagnosing a stale bar needs to know. `rolled` is always the **last**
/// link in the pipeline, so base × suffix is the whole space; no combinatorial growth.
public enum ResetSource: String, Sendable, Equatable, Codable, CaseIterable {

    /// The window object carried its own `resets_at`. The common path.
    case server

    /// The window had no usable `resets_at`, but a matching `limits[]` entry did. A reset-boundary
    /// blip; still a server fact, just delivered by a different field.
    case limits

    /// Neither source had a date, so the last known **server-supplied** reset was rolled forward by
    /// whole windows (``ResetClock/rollForward(anchor:by:until:)``). Only `seven_day` reaches this:
    /// the five-hour window does not exist between sessions, so there is nothing to roll.
    case reconstructed

    /// No date from anywhere and no anchor to roll — a cold start that has never seen a real weekly
    /// reset. Nothing is invented; `resets_at` stays empty and the UI says so. Has no `-rolled`
    /// form: an empty date cannot elapse.
    case unknown

    /// ``server`` whose instant has since passed, rolled forward locally.
    case serverRolled = "server-rolled"

    /// ``limits`` whose instant has since passed, rolled forward locally.
    case limitsRolled = "limits-rolled"

    /// ``reconstructed`` whose instant has since passed — the blackout outlasted a whole window
    /// (a month-long break with the app closed, say).
    case reconstructedRolled = "reconstructed-rolled"

    // MARK: Composition

    /// This source with the `-rolled` suffix applied, or `self` when it cannot take one.
    ///
    /// Idempotent: rolling an already-rolled source returns it unchanged, because the suffix records
    /// *that* a local roll happened, not how many times. ``unknown`` is likewise unchanged — there is
    /// no date to roll.
    public func rolled() -> ResetSource {
        switch self {
        case .server:        return .serverRolled
        case .limits:        return .limitsRolled
        case .reconstructed: return .reconstructedRolled
        case .unknown, .serverRolled, .limitsRolled, .reconstructedRolled: return self
        }
    }

    /// Whether this is an **unmodified server fact** — the only kind worth persisting as the anchor
    /// that future reconstructions roll forward from.
    ///
    /// `true` for ``server`` and ``limits`` (both arrived from the API, merely by different fields);
    /// `false` for everything else. The long name is deliberate: a shorter `isFromServer` invites a
    /// later reader to "fix" it by including ``serverRolled`` — which would let the reconstruction
    /// feed on its own output, compounding error across a multi-hour blackout. That is the one
    /// invariant this type exists to protect.
    public var isUnrolledServerFact: Bool {
        switch self {
        case .server, .limits: return true
        case .reconstructed, .unknown, .serverRolled, .limitsRolled, .reconstructedRolled: return false
        }
    }

    /// How this source reads on the Troubleshoot pane — the *mode* the weekly reset is currently
    /// being computed in, in words rather than a raw case name.
    ///
    /// Deliberately says what the app **did**, not what the API sent, because during a blackout those
    /// differ and the difference is the whole point: a reconstructed date looks exactly like a real
    /// one on the bar, and this line is the only place that distinction survives.
    public var troubleshootDescription: String {
        switch self {
        case .server:              return "from the API"
        case .limits:              return "from limits[] (window was null)"
        case .reconstructed:       return "reconstructed — API sent none"
        case .unknown:             return "unknown — none sent, nothing to roll from"
        case .serverRolled:        return "from the API, rolled forward locally"
        case .limitsRolled:        return "from limits[], rolled forward locally"
        case .reconstructedRolled: return "reconstructed, then rolled forward locally"
        }
    }

    /// Whether the date was rolled forward locally after its instant passed.
    public var isRolled: Bool {
        switch self {
        case .serverRolled, .limitsRolled, .reconstructedRolled: return true
        case .server, .limits, .reconstructed, .unknown: return false
        }
    }
}
