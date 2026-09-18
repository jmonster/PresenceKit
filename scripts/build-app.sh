#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Building the app requires macOS.' >&2; exit 1; }
swift build -c release --product PresenceAgent
BIN="$(swift build -c release --show-bin-path)/PresenceAgent"
APP="$PWD/build/PresenceAgent.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PresenceAgent"
cp packaging/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements packaging/Entitlements.plist \
  --sign "${SIGNING_IDENTITY:--}" "$APP"
printf 'Built %s\n' "$APP"
