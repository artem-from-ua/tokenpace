---
status: accepted
date: 2026-06-23
---

# ADR-0015: Remove the compact idle mode — always show the strips

> **See also [ADR-0027](0027-session-idle-no-phantom-reset.md).** That ADR introduces an
> API-driven "no active 5h session" state (recoloring the 5h bar; the bars do **not** disappear) —
> this is not a return of the display collapse-past-a-utilization-threshold removed here; the
> operational decision "strips are always visible" still stands.

## Context

[ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) introduced a "compact idle mode":
when **both** windows had `utilization < 5%`, the menu bar collapsed from two pacing strips down to
one small icon — a bold `*`. The reference point was SPEC §135 ("Compact mode on idle … when Claude
Code isn't actively in use").

In practice the implementation turned out **not to match the intent**, and it surfaced as a live
bug:

- SPEC's intent: collapse **when Claude isn't actively in use**.
- The implementation: collapse **when both limits are < 5%** — purely by spend percentage, with no
  connection to whether the `claude` process is active.

Result: right after a window reset (`five_hour` 3%, `seven_day` 0% — both < 5%), the menu bar showed
the asterisk **while the user was actively working in Claude Code**. In other words, the state meant
to signal "nothing is happening" appeared exactly when the most was happening.

The irony is that a real activity detector already **exists** in the project —
`ProcessClaudeActivityProbe` (`sysctl(KERN_PROC_ALL)`, looking for the `claude` process), used by
`PollingEngine` for cadence. But `MenuBarLayout` never asked it: the idle/expanded decision looked
only at `utilization`.

Two options came up: (a) fix idle by tying it to real Claude activity
(`ProcessClaudeActivityProbe`), or (b) remove idle mode entirely.

## Decision

**Remove idle mode entirely.** As long as there's valid data (the healthy path), the menu bar
**always** shows two pacing strips plus time to reset — regardless of `utilization` level. The
strips are absent **only** in the error state / on cold start (a stale token, the API unavailable,
no successful poll yet) — then a ⚠️ is shown ([ADR-0010](0010-usage-health-and-error-states.md)).

Specifically:

1. **`MenuBarMode.idle` removed.** What remains is `expanded` (the healthy path, always) and
   `error` (#12).
2. **`MenuBarLayout.idleUtilizationThreshold` (5%) and the `bothLow` branch removed** from
   `make(from:now:)` — `make` now always returns `.expanded`.
3. **The cold-start fallback** (`snapshot == nil` on the healthy path, before the first poll) now
   returns `.error(nil, nil, nil, nil)` (a bare ⚠️ — no data), instead of `.idle`.
4. **`StatusItemView.drawIdleGlyph` (`*`) and its switch branch removed.**

Why **not** option (a) — tying idle to Claude activity:

- Its value is questionable. The point of a menu-bar widget is to see the limit **at a glance**.
  Collapsing to an asterisk hides exactly the information the widget exists for — and even when
  Claude really is inactive, the strips don't get in the way (they're already compact).
- Less hidden state means fewer ways to confuse the user. One predictable appearance ("always
  strips, except on error") is simpler and more honest than two modes with a non-trivial threshold.
- `ProcessClaudeActivityProbe` remains useful exactly where it already is — in *cadence* (how often
  to poll), not in *display*.

## Consequences

- **Predictable appearance.** The menu bar always shows what it exists for — the limits. No more
  "vanishing into an asterisk" mid-session.
- **Simpler code and model.** `MenuBarMode` — two branches instead of three; the threshold and its
  boundary semantics (strict `<`, the 5.0 cutoff) are gone.
- **Tests updated:** the former `bothWindowsLowIsIdle`/`zeroUtilizationIsIdle`/boundary tests became
  tests asserting that low `utilization` still yields `.expanded`; the cold-start test expects a
  bare `.error`.
- **This ADR supersedes part of [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)** —
  specifically the decisions in §2 (the 5% idle threshold) and §4 (the idle glyph `*`). The rest of
  ADR-0009 (the pure/shell split, `MenuBarMode` as an open enum, drawing the strips) still stands.
- SPEC §135 was rewritten from "compact mode on idle" to "no idle mode."
