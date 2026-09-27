#!/bin/bash
# Prints the `--sdk <path>` flags `swift build`/`swift test` need on this machine, or nothing when the
# default SDK works. Meant to be read with `$(…)` and splatted into a swift invocation.
#
# From the macOS 27 SDK on, SwiftUI's `@State` is an attached macro (`SwiftUICore.swiftinterface`
# declares `public macro State()`) whose plugin — libSwiftUIMacros.dylib — ships only inside
# Xcode.app. Command Line Tools do not carry it, so a default build fails with
# `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. Older SDKs
# declare `@State` as a plain property wrapper and need no plugin.
#
# Silent on macOS 15/26 and on any machine with Xcode, where the default SDK is already fine — so
# callers can splat it unconditionally. Diagnostics go to stderr, never stdout, or they would end up
# inside the caller's argument list.
#
# The deployment target is unaffected: it comes from `Package.swift` (`platforms: [.macOS(.v15)]`),
# so the binary keeps `minos 15.0` whichever SDK compiles it.

sdk_state_is_macro() {
    grep -qr "macro State()" "$1/System/Library/Frameworks/SwiftUICore.framework/" 2>/dev/null
}

default_sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -n "${default_sdk}" ] || exit 0

host_plugins="$(dirname "$(xcrun --find swift 2>/dev/null || echo /usr/bin/swift)")/../lib/swift/host/plugins"
# Xcode present, or an SDK that needs no plugin: nothing to override.
if [ -f "${host_plugins}/libSwiftUIMacros.dylib" ] || ! sdk_state_is_macro "${default_sdk}"; then
    exit 0
fi

# Real directories only — the SDKs dir also holds `MacOSX.sdk`/`MacOSX26.sdk` symlinks, and naming one
# would report a version that is not what was chosen. `sort -V` orders by version (a plain glob puts
# 26.5 before 26), and the last match wins, so this lands on the newest usable SDK.
fallback=""
while IFS= read -r candidate; do
    [ -d "${candidate}" ] || continue
    sdk_state_is_macro "${candidate}" || fallback="${candidate}"
done < <(find "$(dirname "${default_sdk}")" -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -V)

if [ -n "${fallback}" ]; then
    echo "note: ${default_sdk##*/} needs libSwiftUIMacros.dylib (Xcode-only); using ${fallback##*/}" >&2
    printf '%s\n%s\n' --sdk "${fallback}"
else
    echo "warning: no SDK without the SwiftUI @State macro found — the build will likely fail." >&2
    echo "         Install Xcode, or keep an older Command Line Tools SDK." >&2
fi
