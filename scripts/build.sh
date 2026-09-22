#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Onward.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Onward "$APP/Contents/MacOS/Onward"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/OnwardWarning*.wav Resources/OnwardTime-*.wav "$APP/Contents/Resources/"
swift scripts/icon.swift .build/Onward.iconset
iconutil -c icns .build/Onward.iconset -o "$APP/Contents/Resources/Onward.icns"
ditto BrowserExtension "$APP/Contents/Resources/BrowserExtension"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp references/CODEX-LICENSE "$APP/Contents/Resources/CODEX-LICENSE"
cp references/CODEX-NOTICE "$APP/Contents/Resources/CODEX-NOTICE"
IDENTITY="${ONWARD_SIGNING_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  DETECTED=$(security find-identity -v -p codesigning | sed -n 's/.*) \([A-F0-9]\{40\}\) "Apple Development:.*/\1/p' | awk 'NR == 1 { print }')
  if [ -n "$DETECTED" ]; then IDENTITY="$DETECTED"; fi
fi
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Onward.entitlements "$APP"
codesign --verify --strict "$APP"
printf 'Built and signed: %s\n' "$APP"
