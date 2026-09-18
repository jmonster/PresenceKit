#!/bin/bash
set -euo pipefail
LABEL=io.github.jmonster.PresenceAgent
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo 'Login agent removed. The application remains in ~/Applications/PresenceAgent.app.'
