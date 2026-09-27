# TokenPace

> 👀 *The most refined form of procrastination is watching your own limit.*

Your Claude Code subscription limits, concisely, in the macOS menu bar.

TokenPace shows right in the menu bar whether you are **ahead of or behind** the even spending rate
(*pacing*) in the **5-hour** and **7-day** limit windows — as two bars, without switching to the
terminal. When work can no longer run (the limit is exhausted) or runs only for money, the bars give
way to a **countdown to the reset** with a glyph that names the cause. Numbers and bars never appear
together: [how to read the menu bar](docs/reference/menu-bar-signals.md).

This is for people who work in Claude Code on a Mac and don't want to hit "limit exhausted" out of
nowhere: you can see what is left in each window, so you can plan work around the next reset, notice
in time that you are going too fast, and avoid breaking off a session mid-task. The bar's color tells
you the pace at once: **red** when you are spending faster than the even rate (risking exhausting the
window early), **green** when you are within the limits or procrastinating too much.

Separately, TokenPace watches the **status of Claude's services** (Claude Code and Claude API) from
the status.claude.com page: the popup shows each one's state as a colored dot, and when there is a
problem the dot also appears in the menu bar, so it is clear that the slowdown or the errors are on
Anthropic's side, not yours.

The data source is Anthropic's official `GET /api/oauth/usage` endpoint; authorization uses the Claude
Code OAuth token from the macOS Keychain. **The token never leaves the Mac.**

> 🚧 Early development. Phase 1 is the menu bar app for macOS; iPhone widgets and an Apple Watch
> complication come later.

<img src="docs/assets/dropdown-without-option.png" alt="The TokenPace menu bar and dropdown at rest: the awaiting-input hand and its count, the 5-hour and 7-day limits with colored pacing bars, the Fable and Mythos weekly limits, paid extra usage, a red GitHub Actions row, and the hint to hold Option for more" width="300"> <img src="docs/assets/dropdown-with-option.png" alt="The same dropdown with ⌥ Option held: the plan label and data age beside the brand title, the awaiting sessions listed per project, each limit naming its bar style and spelling out “resets in” with exact amounts, the incident behind the red Actions row, and the Settings, Troubleshoot and Development tools items" width="300">

At rest, and with **⌥ Option** held.

## Legend

Every mark the app draws, explained in the app itself — **Settings → Legend**. The same page, in full:

<img src="docs/assets/legend-colors-and-styles.png" alt="Legend, part one: what a bar's color says — far behind pace, on pace, ahead, well ahead, limit reached, no color — then the two menu-bar layouts, and the Balance and Pressure bar styles with their zero points" width="380"> <img src="docs/assets/legend-progress-and-icons.png" alt="Legend, part two: the Progress bar style with its now-marker, tokens spent and hour ticks, then every icon — awaiting input, paused, extra usage, usage API error, no data, tracking off, reset countdown, and the service-status dot colors" width="380">

## Installation

1. Download `TokenPace-X.Y.Z.zip` from the [latest release](https://github.com/artem-from-ua/tokenpace/releases/latest)
   and unpack it (double-click).
2. Drag **TokenPace.app** into the **Applications** folder.
3. Launch it from **Launchpad** or Finder. There will be no Dock icon — the app lives in the menu bar.

Runs on Apple Silicon and Intel (universal binary). **Launch-at-login** is enabled in `Settings…` and
works for a copy launched from `/Applications`.

## Documentation

- [docs/README.md](docs/README.md) — **the map of all documentation** (start here).
- [SPEC.md](SPEC.md) — the product spec (problem, architecture, UI, phases, monetization).
- [docs/architecture.md](docs/architecture.md) — architecture and data flow.
- [docs/building.md](docs/guides/building.md) — building from source (for contributors).
- [docs/conventions.md](docs/reference/conventions.md) — development conventions.
- [docs/adr/](docs/adr/) — architecture decision records.

## License

**Closed for now.** The open-source question (and a possible license) is open; we'll settle it later.
One of the arguments for opening the code is trust in how the token is handled.
