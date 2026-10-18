#!/bin/bash
set -euo pipefail
[[ $# == 0 ]] || { echo "Usage: $0 (no arguments)" >&2; exit 2; }
cd "$(dirname "$0")/.."
[[ ! -L build && ! -L build/WatchLock.app ]] || { echo "Refusing symlink build destination" >&2; exit 1; }
bundle="$PWD/build/WatchLock.app"
mkdir -p build .build/module-cache
# Only our reproducible output bundle is replaced; no preferences or installations.
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sources=(WatchLock/Core/*.swift WatchLock/*.swift)
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -sdk "$sdk" \
    -module-cache-path "$PWD/.build/module-cache" "${sources[@]}" -o "$bundle/Contents/MacOS/WatchLock"
cp WatchLock/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE NOTICE "$bundle/Contents/Resources/"
cp WatchLock/Resources/AppIcon.icns "$bundle/Contents/Resources/"
printf 'APPL????' > "$bundle/Contents/PkgInfo"
codesign --force --sign - --options runtime --entitlements WatchLock/WatchLock.entitlements "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
[[ -x "$bundle/Contents/MacOS/WatchLock" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == local.shatravkada.WatchLock ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$bundle/Contents/Info.plist")" == 14.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$bundle/Contents/Info.plist")" == AppIcon.icns ]]
cmp WatchLock/Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
file "$bundle/Contents/MacOS/WatchLock" | grep -q arm64
printf 'Built (ad-hoc, not notarized): %s\n' "$bundle"
