---
status: accepted
date: 2026-08-13
---

# ADR-0085: Usage collection and service monitoring are two different things

> Refines [ADR-0024](0024-configurable-logical-services.md) and
> [ADR-0013](0013-claude-status-line.md): `Claude API` is no longer "always monitored
> unconditionally" — it is monitored **as long as anything at all is enabled**, and its state is
> derived, not stored. The rest of both ADRs (worst-of-N, component semantics, identity by name)
> still stands.

## Context

The row in Settings said `Claude API — always monitored`, and the `MonitoredServices` doc comment
explained why:

> `Claude API (api.anthropic.com)` is deliberately **not** represented here: it is always monitored
> and not user-configurable (TokenPace's own ability to call the usage API depends on it).

That single sentence conflated **two different things**:

1. **incident monitoring** of `api.anthropic.com` on the status page — the same thing we do for
   Claude Code and claude.ai;
2. **our own data collection's dependency** on that endpoint being alive.

The consequence was not cosmetic. The user had no way to say "don't poll the usage API" — and that
is a legitimate wish: someone might not want the app hitting their token every three minutes,
someone might only want incidents. The only available gesture was to turn everything off and quit
the app.

[#341](https://github.com/artem-from-ua/tokenpace/issues/341) splits these two things apart.

## Decision

### 1. A composite, not a merge

A new Kit type, `ProviderMonitoring`, holds **the two halves side by side**:

```swift
public struct ProviderMonitoring: Sendable, Equatable, Codable {
    public var usageApiEnabled: Bool         // usage collection — what feeds the bars
    public var services: MonitoredServices   // status page — UNCHANGED

    public var claudeApiLocked: Bool {
        usageApiEnabled || services.claudeCodeEnabled || services.webDesktopEnabled
    }
}
```

`MonitoredServices` is **not changed at all**. This is not tidiness for its own sake: its doc
comment says "which Claude **status-page services** to monitor," and putting the usage-collection
flag there would recreate exactly the conflation this ticket exists to untangle, just one level
down. A type that lies about its own name is the same problem, just in code instead of the UI.

### 2. `claudeApiLocked` — computed, never stored

`Claude API` has no switch of its own. It is enabled **as long as anything at all is enabled**: the
usage poll hits it directly, and Claude Code or claude.ai incidents are unreadable without an answer
to "is the API itself alive." The only configuration without it is the one where everything is off,
and there it is not needed either.

Derivation removes the impossible state **at the root**: there is no second copy that can drift out
of sync, no normalization is needed in `init(from:)`, and the memberwise `init` cannot construct the
forbidden combination. The alternative — a stored `claudeApiEnabled` field that would have to be
normalized at every entry point — would leave a whole class of bugs that simply does not exist here.

### 3. Two keys in `UserDefaults`, not one blob

`usageApiEnabled` is a separate scalar key next to the `monitoredServices` JSON blob, not a field
inside it.

The reason is downgrade safety. If the flag lived in the blob, an older build that doesn't know
about it would overwrite the blob on the very next settings change and **silently erase** the
user's choice. Two keys survive a downgrade; one blob does not.

### 4. "Nothing is monitored" is a legal state, not an error

An empty set is now representable: `StatusHealth.checks` returns an empty array, `worstProblem` is
`nil`, `monitoredComponentNames` is an empty set (so no incident is ever "mine").

This changes a long-standing invariant that "`Claude API` is always present." The new formulation:
**`Claude API` is present whenever anything at all is enabled.** The tests were not deleted —
they were rewritten for the new formulation, with a `usageApiEnabled` dimension added to the
permutations.

### 5. A third state for `UsageHealth`

`UsageHealth` used to have exactly two states: healthy (`failingSince == nil`) and failing.
"Deliberately not polling" fit neither, and **both** workarounds break:

| Workaround | What breaks |
|---|---|
| return **failing** | the popup shows a red error banner **immediately** (it has no 30-minute threshold — that threshold belongs to the bar), and the bar gives ⚠️ after 30 minutes, then a bare ⚠️ after 60. The user's deliberate choice **itself** degrades into a broken-app message |
| return **healthy** | `lastSuccess` lies: the popup says "Updated just now" with no data behind it, and `wakeRearmInterval` suppresses the immediate poll after wake |

Hence a **field**, `notPolling: Bool`, rather than an enum case. `UsageHealth` is a `struct` of
three `let`s, and there is no `switch` over it anywhere in the code: every consumer reads boolean
predicates. An enum case would give compiler checking, but would require turning the `let`s into
computed properties — source-breaking for the memberwise `init` and the auto-synthesized
`Equatable`, i.e. **not** an additive change.

The cost of the field is known and paid explicitly: the compiler will show **zero** call sites, so
every consumer was found and fixed by hand. So the next consumer doesn't miss it silently, the type
gives two **named** predicates instead of a bare flag:

- `isCollectingUsage` — "is data being collected at all";
- `hasLiveUsageData` — "the data is fresh: we're polling **and** not failing."

A call site that asks `!isFailing` when it really means the second one now reads as a bug.

### 6. Entering the mode clears `lastSnapshot`

The shared root of the two sharpest defects: leaving a stale snapshot in place creates a pair that
**did not exist before** — "not failing, and a snapshot in hand," with nothing ever refreshing it.
That pair is exactly what breaks naive consumers:

- `brokenData` (`!isFailing && snapshot?.hasBrokenActiveReset`) would raise a red
  `.serverProblem` banner from a frozen read;
- `detectBackToWorkEdge` / `detectExtraUsageEdge` (`failingSince == nil` + `let snapshot`) would
  fire a "Back to work!" notification **on every tick**, instead of on a transition.

Removing the fuel is more honest than patching every consumer individually. `lastSuccess`
**survives** this — it is honest history ("here is when the data was last fresh"), and the popup uses it to
explain the age.

### 7. Polling: the same heartbeat, a different request

`apply()` is not split. When `usageApiEnabled == false`, the engine still ticks on the same
heartbeat, but `pollOnce` is not called at all — so **the Keychain is never read**, and no network
traffic goes to the usage endpoint. The status poll, which already rode the same heartbeat, remains
the only data source.

The flag is injected through a `@Sendable () -> Bool` seam that reads `PersistedConfig` **live on
every iteration**. So the Settings toggle takes effect from the next tick — and `.manualRefresh`,
which sends `providerMonitoringChanged`, makes that "next tick" immediate instead of "up to 15
minutes."

### 8. The popup shows the age of **what was actually polled**

`PopupLayout.lastUpdateAge` was computed solely from `health.lastSuccess`, i.e. from the usage
poll — in `servicesOnly` mode it would show "0 s ago" for data that nobody ever fetched.

A separate source of truth already exists: `App.lastStatusSuccess`. It is threaded through with the
graft method `withStatusAge(_:)`, following the existing `withIncidents` / `withSubscription` /
`withPlanLabel` pattern — whose doc comment says outright "instead of threading them through
`make`." These values ride the status poll's **own** cadence, and `lastStatusSuccess` is exactly
that same class. The cost is zero: none of the ~30 calls to `PopupLayout.make` in the tests changed.

At the same time, `lastStatusSuccess` was switched from `Date()` to `currentDate()`: it now lands in
the deterministic layer, whereas under a stub with mocked time a wall-clock timestamp would produce
a negative or jumpy age.

### 9. Two new widget states

| State | Menu bar | Popup |
|---|---|---|
| Usage API off, services on | **`zzz`**, no bars or time | "All services" tile + status poll's age |
| Nothing enabled | **⚠️**, no bars or time | gray "Monitoring is off" block + a line in Settings |

Both are **separate cases** of `MenuBarMode`, not `.error` with `nil`s. `.error` is already
overloaded (cold start **and** "failing for over 60 minutes") and degrades to ⚠️ by construction;
reusing it would mean letting the user's deliberate choice age into a broken-app report.

`zzz` was checked on a live system through `NSImage(systemSymbolName:)` — which also revealed that
`zzz.circle` **does not exist**. This is a temporary icon; the app's own icon comes later.

**The status dot stays in `zzz` mode.** It is drawn outside the switch, and in this mode it is the
**only** piece of information the item carries; removing it would leave a widget that says nothing
at all.

> ⚠️ Not to be confused with *session* idle ([ADR-0027](0027-session-idle-no-phantom-reset.md), "no
> active 5h session"), which is drawn as **zero on the bar**
> ([ADR-0078](0078-idle-drawn-as-zero-in-both-styles.md)). That one is about data; this one is about
> the user having turned monitoring off.

## Consequences

- **The journal needed no extra work.** `UsageJournal` already has two write methods:
  `append(_:at:expectedInterval:)` runs gap detection, while `appendStatus(_:at:)` writes past it
  and does **not** touch the usage clock. Status polls already went through the second one. So in
  "usage off" mode the journal keeps filling with status lines, the usage clock stands still, and
  `ResumeMarker` becomes **semantically correct** on return: the gap in usage samples was real. All
  that was left was to stop writing `error` lines on every tick.
- **The plan label disappears.** The "Max 5×" label comes from `diagnostics.token`; without a poll,
  it's left as plain "Claude." Accepted deliberately — this is not a violation of "don't read the
  Keychain," it's a lost label.
- **Troubleshoot will say "Token: unavailable (no poll yet)"** even though polls are running.
  Technically true about the usage poll, reads ambiguously. Accepted.
- **`StatusCadence` loses problem-floor acceleration.** Its floor is computed as
  `max(floor, usageInterval)`, and the heartbeat no longer accelerates for an incident in this mode.
  Open debt: in usage-off mode the status page is the only source, so its own floor would make sense
  here.
- **Defaults are unchanged.** Everything stays enabled, including on a clean install. The
  requirement "everything off on first launch" was dropped from this PR: the
  `PersistedConfig.monitoredServices` getter structurally **cannot distinguish** a first launch from
  an existing user with no key, and `MigrationPlan` classifies a "very old user" as `.firstRun` too.
  That's separate work, about onboarding.

## Alternatives considered

- **`usageApiEnabled` as a field of `MonitoredServices`** — mechanically cheaper (signatures and the
  callback chain stay untouched), but makes the struct's doc comment false and recreates the
  original conflation one level down.
- **A stored `claudeApiEnabled` with normalization** — needs normalization at every entry point and
  leaves room for the drift that the computed variant rules out by construction.
- **An enum case instead of a field on `UsageHealth`** — would give compiler checking, but is
  source-breaking for the memberwise `init` and `Equatable`; the scope and risk outweigh the payoff
  when there are eight consumers and all are known.
- **A single provider toggle** (as the ticket body proposed) — it would have to mean one of the two
  things, and whichever it meant, the other would become a surprise. That ambiguity is exactly what
  this ticket removes.
