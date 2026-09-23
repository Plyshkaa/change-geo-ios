#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/iOS Location Controller.app"

if [[ "$(xcode-select -p 2>/dev/null || true)" != */Xcode.app/Contents/Developer ]]; then
    print -u2 "Full Xcode is required to build the native window. Install Xcode, then run this script again."
    exit 2
fi

SWIFTC="$(xcrun --sdk macosx --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$ROOT/build/module-cache"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

rm -rf "$MODULE_CACHE"
mkdir -p "$MODULE_CACHE"

"$SWIFTC" -sdk "$SDK" -target arm64-apple-macos13.0 -module-cache-path "$MODULE_CACHE" "$ROOT/LocationControllerApp.swift" \
    -o "$APP/Contents/MacOS/LocationController" \
    -framework AppKit

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/locationctl.py" "$APP/Contents/Resources/locationctl.py"

echo "$APP"
