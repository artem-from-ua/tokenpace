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
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift build
swift run
```

**Prefer exporting `SDKROOT` over passing `--sdk`.** Every `swift` command in that shell picks it up, including the `swift build` the pre-commit hook runs — and the hook takes no flags from you, so on macOS 27 without the export `git commit` is blocked on a Swift change.

`swift test` needs the testing plugin named explicitly on top of that, either way: under the older SDK it is no longer found by default.

```sh
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

**The SDK does not change what the app runs on.** The deployment target comes from `Package.swift` (`platforms: [.macOS(.v15)]`), so the binary keeps `minos 15.0` whichever SDK compiles it — check with `otool -l .build/debug/TokenPace | grep -A3 LC_BUILD_VERSION`.

To confirm which SDK your machine needs, ask the SDK itself rather than guessing from the macOS version:

```sh
grep -rl "macro State()" "$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/SwiftUICore.framework/"
```

A hit means that SDK requires the Xcode-only plugin. `scripts/build-app.sh` runs this check itself and picks the fallback SDK automatically, so the `.app` build needs no flags on any macOS version.

### The release build: Swift 6.4 crashes at `-O`, so the script falls back to `-Osize`

A `-c release` build on Swift 6.4 reports this, with the macro error gone:

```
error: unable to open dependencies file (….build/out/Intermediates.noindex/TokenPace.build/
       Release/TokenPace-p.build/Objects-normal/arm64/TokenPace-primary.d)
error: SwiftDriver\ Compilation\ Requirements TokenPace normal arm64 … failed
```

**That message names the symptom, not the cause.** `swift-frontend` *crashes*, and the driver then notices the side output it never got to write. The proof is in `~/Library/Logs/DiagnosticReports/swift-frontend-*.ips`, timestamped to the build:

```
exception:   EXC_BAD_ACCESS (SIGKILL), KERN_INVALID_ADDRESS
             … (possible pointer authentication failure)
termination: PAC_EXCEPTION
faulting:    swift::SILType::isTrivial(swift::SILFunction const&) const
             SimplifyCFG::tryJumpThreading(swift::BranchInst*)
             SimplifyCFG::run() → SILPassManager::runFunctionPasses
             swift::runSILOptimizationPasses(swift::SILModule&)
```

So it is a bug in the SIL optimizer, not in this package or its configuration. `SimplifyCFG` is an optimization pass, which is why debug (`-Onone`) is unaffected and only release dies. **Installing Xcode does not help** — it ships the same `swift-frontend`. This is unrelated to the `@State` plugin problem above, where Xcode genuinely was the missing piece: the failing release invocation loads no plugins at all.

Two workarounds were verified to build this package:

| flag | result |
|---|---|
| `-Xswiftc -Osize` | builds |
| `-Xswiftc -Xllvm -Xswiftc -sil-disable-pass=simplify-cfg` | builds |

`build-app.sh` uses the first, and **only after `-O` has actually failed** — so a toolchain without the bug keeps shipping the faster binary, and nothing is gated on which macOS is running. `-Osize` is a first-class production mode rather than a diagnostic fallback ([swift.org](https://www.swift.org/blog/osize/): "-Osize is meant for most production code"); it inlines less aggressively, which is what steers the optimizer off the crashing path. The pass-disabling flag is narrower but turns off a pass the pipeline runs many times over, so it is recorded here and not used.

No upstream report matching this signature was found on the Swift forums, the Apple developer forums or GitHub; the closest is [swiftlang/swift#92192](https://github.com/swiftlang/swift/issues/92192), the same `SimplifyCFG`/jump-threading area but a different platform and failure mode. No fixed version is known, so the fallback stays until one is.

## Building the `.app` bundle

```sh
./scripts/build-app.sh    # → ./build/TokenPace.app
open ./build/TokenPace.app # launch (no Dock icon — LSUIElement)
```

> **No flags needed on any macOS version.** The script picks the SDK itself, and falls back to `-Osize` if the compiler crashes at `-O` — see [The release build](#the-release-build-swift-64-crashes-at--o-so-the-script-falls-back-to--osize). Expect the log to show a failed `-O` attempt followed by a retry on macOS 27; that is the fallback working, not a broken build.

The script builds a **universal binary** (arm64 + x86_64), so the `.app` runs natively on both Apple
Silicon and Intel Macs (SwiftPM has no single `--arch`, so each architecture is built separately via
`--triple` and merged with `lipo`).

The app launches as an **accessory agent** with no Dock icon (`LSUIElement = true`): two pacing bars
in the menu bar, a click opens the popup with details, and at the bottom are `Settings…` (launch-at-login
toggle, version, GitHub link) and `Quit TokenPace`.

## The app icon

The bundle icon (Finder, Spotlight, notifications, About, the Dock while a window is open) is not
the menu-bar glyph — that one is drawn in code. `build-app.sh` copies two precompiled files into
`Contents/Resources/`:

| File | Read by | Contents |
|---|---|---|
| `Assets.car` | `CFBundleIconName` | the layered icon for macOS 26+ (light, dark, tinted, clear) plus flattened renditions, 16–1024 px, for macOS 15 |
| `AppIcon.icns` | `CFBundleIconFile` | a compatibility fallback; `actool` keeps only 16–256 px in it, because the `.car` carries the rest |

**Why both, and not just an `.icns`:** on macOS 26 an `.icns`-only icon renders smaller than native
icons, and on a grey squircle unless its artwork matches the system shape exactly
([Michael Tsai](https://mjtsai.com/blog/2025/08/08/separate-icons-for-macos-tahoe-vs-earlier/)).
The decision, the committed build and glass off are in
[ADR-0134](../adr/0134-app-icon-from-a-committed-icon-composer-build.md).

The source is `design/app-icon/AppIcon.icon`, an Icon Composer document: `icon.json` plus one
1024×1024 SVG per layer in `Assets/` (tracks, pacing gaps, time markers), drawn full-bleed with no
mask, because the system applies the squircle. The background is a solid fill set in `icon.json`,
not a layer. Liquid Glass is **off** on every layer, so the bars stay flat; the system still adds the
rim and the edge shadow.

To change the icon:

1. Edit a layer SVG in any vector editor, keeping the 1024 canvas and the position, or open
   `AppIcon.icon` in Icon Composer (bundled with Xcode 26+ under `Xcode.app/Contents/Applications/`)
   to change fills, layer order or glass and preview every appearance.
2. Recompile — this needs a **full Xcode 26+**, which is why the output is committed and the `.app`
   build doesn't need it:
   ```sh
   ./scripts/build-app-icon.sh   # → design/app-icon/compiled/{Assets.car,AppIcon.icns}
   ```
3. Commit `design/app-icon/` together. **Only when the icon actually changed:** `Assets.car` is not
   byte-reproducible (`actool` embeds per-run identifiers), so a re-run over an unchanged source still
   produces a diff.
4. Check it in a built `.app` — `swift run` has no bundle, so it never shows the icon.

To render an appearance without opening the GUI (the `--rendition` values include `Default`, `Dark`,
`TintedLight`, `ClearDark`). `xcode-select -p` resolves whichever Xcode is selected, so the path holds
for a renamed one (`Xcode-26.3.app`) too:

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  design/app-icon/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Default --width 512 --height 512 --scale 1
```

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
