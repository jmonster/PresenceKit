#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/PresenceAgent.app/Contents/MacOS/PresenceAgent
"$APP" --check-config
"$APP" --check-config --media '/a path/movie.mp4' --manage-display --keep-awake --loop --input-grace-seconds 30
"$APP" --check-config --human --fallback pause
"$APP" --check-config --face --fallback motion --fallback-grace-seconds 0 --absence-seconds 240 --no-loop
for bad in '--garbage' '--media' '--absence-seconds NaN' '--absence-seconds 1e300' '--absence-seconds inf' '--absence-seconds -1' '--human --face' '--human --absence-seconds 10' '--fallback guess' '--fallback-grace-seconds 3601' '--input-grace-seconds NaN' '--input-grace-seconds 3601' '--fallback pause'; do
  # Test strings are fixed literals, never user-supplied shell commands.
  read -r -a args <<< "$bad"
  if "$APP" --check-config "${args[@]}"; then
    echo "Invalid arguments unexpectedly accepted: $bad" >&2; exit 1
  fi
done
echo 'All 17 agent argument checks passed without camera or display side effects.'
