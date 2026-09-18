#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -ne 0 ]] || { echo 'Run as your logged-in user, not root.' >&2; exit 1; }
bash scripts/build-app.sh
DEST="$HOME/Applications/PresenceAgent.app"
LABEL=io.github.jmonster.PresenceAgent
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
/usr/bin/ditto build/PresenceAgent.app "$DEST"
swift scripts/write-agent.swift "$PLIST" "$DEST/Contents/MacOS/PresenceAgent" "$@"
# Do not use KeepAlive: permission denial must not cause a restart/prompt loop.
launchctl bootstrap "gui/$(id -u)" "$PLIST"
printf 'Installed %s. Grant camera permission to PresenceAgent.\n' "$DEST"
