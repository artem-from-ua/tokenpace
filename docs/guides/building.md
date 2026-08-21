# Building from source

For contributors. End users don't need to build anything — there's a ready notarized `.app`
in the [releases](https://github.com/artem-from-ua/tokenpace/releases) (see the README).

## Prerequisite

Swift 6.1+ and Command Line Tools. A full Xcode install is **not required** in Phase 1.

## Development

```sh
swift build        # build
swift test         # unit tests
swift run          # run the agent (no window; stop with Ctrl-C)
```

## Building the `.app` bundle

```sh
./scripts/build-app.sh    # → ./build/TokenPace.app
open ./build/TokenPace.app # launch (no Dock icon — LSUIElement)
```

The script builds a **universal binary** (arm64 + x86_64), so the `.app` runs natively on both Apple
Silicon and Intel Macs (SwiftPM has no single `--arch`, so each architecture is built separately via
`--triple` and merged with `lipo`).

The app launches as an **accessory agent** with no Dock icon (`LSUIElement = true`): two pacing bars
in the menu bar, a click opens the popup with details, and at the bottom are `Settings…` (launch-at-login
toggle, version, GitHub link) and `Quit TokenPace`.

## Signing and notarization

`build-app.sh` automatically signs the bundle with a Developer ID identity (if one is available) using
`--options runtime` and, if the `tokenpace-notary` notarytool profile is configured, notarizes it and
staples the ticket. To verify: `spctl -a -t exec ./build/TokenPace.app` → `accepted (Notarized Developer ID)`.
Without a Developer ID identity the build stays unsigned — Gatekeeper may block it on first launch
(`right-click → Open`, or `xattr -dr com.apple.quarantine ./build/TokenPace.app`).

The full release procedure is in [releasing.md](releasing.md).

## Launch-at-login

`SMAppService` registers launch-at-login reliably only for a **signed** `.app` **launched from
`/Applications`** (via Finder/Launchpad). Under `swift run`, or when the binary is launched directly,
the status will be `.notFound` and the toggle in `Settings…` is disabled (with an explanation).

## Viewing logs

```sh
log stream --predicate 'subsystem == "com.artem-n.tokenpace"' --info
```

or Console.app filtered by `com.artem-n.tokenpace`.
