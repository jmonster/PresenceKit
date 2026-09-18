#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -ne 0 ]] || { echo 'Run as your logged-in user, not root.' >&2; exit 1; }
bash scripts/build-app.sh
build/PresenceAgent.app/Contents/MacOS/PresenceAgent --check-config "$@"
DEST="$HOME/Applications/PresenceAgent.app"
LABEL=io.github.jmonster.PresenceAgent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
/usr/bin/ditto build/PresenceAgent.app "$DEST"
swift scripts/write-agent.swift "$PLIST" "$DEST/Contents/MacOS/PresenceAgent" "$@"
# Crash-only KeepAlive is throttled. Terminal sensing faults stay visible in the app.
launchctl bootstrap "gui/$(id -u)" "$PLIST"
printf 'Installed %s. Grant camera permission to PresenceAgent.\n' "$DEST"
