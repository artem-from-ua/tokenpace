# Building from source

For contributors. End users don't need to build anything — there's a ready notarized `.app`
in the [releases](https://github.com/artem-from-ua/tokenpace/releases) (see the README).

## Prerequisite

Swift 6.1+ and Command Line Tools. A full Xcode install is **not required** in Phase 1 — but on macOS 27 the plain commands below need one extra flag, see [SwiftUI macros on macOS 27](#swiftui-macros-on-macos-27).

## Development

```sh
swift build        # build
swift test         # unit tests
swift run          # run the agent (no window; stop with Ctrl-C)
```

### SwiftUI macros on macOS 27

On macOS 27 a bare `swift build` fails on every SwiftUI `@State` in the package:

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
       for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

From the macOS 27 SDK on, `@State` is an **attached macro** rather than a property wrapper (its `SwiftUICore.swiftinterface` declares `public macro State()`), and the plugin that expands it — `libSwiftUIMacros.dylib` — ships only inside `Xcode.app`. Command Line Tools do not carry it; `/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/` holds only the `Observation`, `Swift` and `Testing` plugins. Nothing was removed from CLT: on macOS 15 `@State` needed no plugin at all, which is why the same setup built fine there.

Build against the newest SDK that still declares `@State` as a plain property wrapper — CLT keeps the previous one alongside the current:

```sh
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift run   --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

`swift test` needs the testing plugin passed explicitly on top of that — under the older SDK it is no longer found by default:

```sh
swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

**The SDK does not change what the app runs on.** The deployment target comes from `Package.swift` (`platforms: [.macOS(.v15)]`), so the binary keeps `minos 15.0` whichever SDK compiles it — check with `otool -l .build/debug/TokenPace | grep -A3 LC_BUILD_VERSION`.

To confirm which SDK your machine needs, ask the SDK itself rather than guessing from the macOS version:

```sh
grep -rl "macro State()" "$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/SwiftUICore.framework/"
```

A hit means that SDK requires the Xcode-only plugin. `scripts/build-app.sh` runs this check itself and picks the fallback SDK automatically, so the `.app` build needs no flags on any macOS version.

### Open: the release build is broken on macOS 27

The SDK fallback fixes `swift build` and `swift test` (debug). **`-c release` still fails**, with the macro error gone but a driver failure in its place:

```
error: unable to open dependencies file (….build/out/Intermediates.noindex/TokenPace.build/
       Release/TokenPace-p.build/Objects-normal/arm64/TokenPace-primary.d)
error: SwiftDriver\ Compilation\ Requirements TokenPace normal arm64 … failed
```

What is established: it is **not** caused by any source change — an unmodified checkout fails identically; it is not the `--triple` flag (it fails without it); it is not a stale cache (it fails after deleting `.build/out/Intermediates.noindex/TokenPace.build/Release`); and no macro error appears in the log, so the SDK fallback is doing its job. The failing compiler invocation carries `-save-temps` and a `-working-directory` one level **above** the package, which is the next thing to look at — it was not chased further.

Consequence: `scripts/build-app.sh` cannot produce an `.app` on macOS 27, so the notarized release path needs either a machine on an older macOS or an Xcode install. `swift build` / `swift run` / `swift test` are unaffected, so ordinary development and UI verification work.

## Building the `.app` bundle

```sh
./scripts/build-app.sh    # → ./build/TokenPace.app
open ./build/TokenPace.app # launch (no Dock icon — LSUIElement)
```

> **On macOS 27 this currently fails** — the script picks the right SDK, but `-c release` itself is broken there. See [Open: the release build is broken on macOS 27](#open-the-release-build-is-broken-on-macos-27).

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
