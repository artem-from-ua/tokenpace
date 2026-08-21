---
status: accepted
date: 2026-06-21
---

# ADR-0003: The Mac agent stays closed for now; the license is an open question

## Context

The earlier assumption was that the Mac agent would be open source under Apache-2.0 (the motive
being trust in how it handles the OAuth token). That decision is premature: the distribution model,
monetization and legal aspects are not settled yet.

## Decision

The Mac agent is **closed for now**. Open sourcing it, and the specific license, is an **open
question** — we will return to it later (probably closer to a public release / Phase 3).

## Consequences

- The repository is private.
- The "trust through open code" argument stays a valid motive for the future, but it is not a
  commitment today.
- When the decision is made, this ADR will be extended by a new one (with a link), not rewritten.
