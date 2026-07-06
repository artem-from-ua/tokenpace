import Foundation

// MARK: - DelegatedRefresher

/// The delegated-refresh seam — spawn the `claude` CLI so Claude Code refreshes and rewrites
/// its **own** Keychain credentials, then let the caller re-read them (ADR-0017, issue #8).
///
/// TokenPace never performs the OAuth `refresh_token` grant itself: Anthropic rotates refresh
/// tokens, so a self-refresh without a write-back would desync Claude Code's stored pair and
/// log the user out of the CLI. Delegating keeps this app strictly read-only w.r.t. the
/// `Claude Code-credentials` item.
///
/// A protocol because process spawning is a platform side-effect: production is
/// `ClaudeCLIRefresher` in the shell, tests inject a stub returning a scripted outcome
/// (mirrors ``ClaudeActivityProbe``/``PollScheduler``).
public protocol DelegatedRefresher: Sendable {
    /// Attempt one delegated refresh. Fail-safe by contract: never throws, never hangs
    /// (the implementation owns a hard timeout) — every failure mode is an outcome case.
    func refresh() async -> DelegatedRefreshOutcome
}

// MARK: - DelegatedRefreshOutcome

/// Distinguishable results of one delegated-refresh attempt. Only `.refreshed` means the
/// Keychain now holds a newer pair; everything else is folded into ``RefreshGate`` as a
/// failure so the engine does not respawn the CLI on every poll.
public enum DelegatedRefreshOutcome: Sendable, Equatable {
    /// The CLI ran and the stored `expiresAt` moved forward — re-read the Keychain and go.
    case refreshed
    /// The CLI ran (exit 0) but the Keychain did not change. On an *expired* token this is
    /// a failure; the CLI may also legitimately skip a refresh while the token is fresh.
    case unchanged
    /// No `claude` binary at any known location — only opening Claude Code can help.
    case cliNotFound
    /// The CLI outlived the hard timeout and was killed.
    case timedOut
    /// The CLI exited non-zero (or its exit status could not be read).
    case failed(exitCode: Int32?)
}

// MARK: - RefreshGate

/// Pure, value-type anti-flap gate for delegated-refresh attempts.
///
/// An expired token surfaces on **every** poll until it is fixed; without a gate the engine
/// would spawn a `claude` process every cycle (60 s floor). After each failed attempt the
/// gate blocks the next one for an escalating cooldown `1 → 5 → 30 → 60 min`, holding at
/// 60 min until an attempt succeeds (mirrors ``PollingBackoff``: no timer, no clock — `now`
/// is injected, every transition returns a copy and is exhaustively unit-tested).
public struct RefreshGate: Sendable, Equatable {

    /// Escalating post-failure cooldowns, **in seconds**: 1, 5, 30, 60 min. The last value
    /// is the ceiling held while failures continue (e.g. the CLI is uninstalled).
    /// `stepsAreInSeconds` guards the unit in the tests.
    public static let steps: [TimeInterval] = [60, 5 * 60, 30 * 60, 60 * 60]

    /// Failed attempts since the last success — indexes into ``steps`` (clamped).
    public private(set) var consecutiveFailures: Int

    /// The instant the next attempt becomes allowed; `nil` means no cooldown is active.
    public private(set) var nextAttemptAllowed: Date?

    /// A fresh gate: first attempt allowed immediately.
    public init() {
        self.consecutiveFailures = 0
        self.nextAttemptAllowed = nil
    }

    /// Whether an attempt may run at `now` — `true` when no cooldown is active or the
    /// active one has elapsed (boundary counts as elapsed).
    public func allows(now: Date) -> Bool {
        guard let nextAttemptAllowed else { return true }
        return now >= nextAttemptAllowed
    }

    /// Reset after a successful refresh: failures cleared, next attempt allowed
    /// immediately. Returns a copy.
    public func afterSuccess() -> RefreshGate {
        RefreshGate()
    }

    /// Record a failed attempt: bump the failure count and block the next attempt for the
    /// matching ``steps`` cooldown (clamped to the ceiling). Returns a copy.
    public func afterFailure(now: Date) -> RefreshGate {
        var copy = self
        copy.consecutiveFailures += 1
        let step = Self.steps[min(copy.consecutiveFailures - 1, Self.steps.count - 1)]
        copy.nextAttemptAllowed = now.addingTimeInterval(step)
        return copy
    }
}
