#!/bin/bash
# Called by launchd (WatchPaths on control/). Starts a recording when control/start.json appears.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTRL="$ROOT/control"; STATE="$ROOT/state"
mkdir -p "$STATE"
[ -f "$CTRL/start.json" ] || exit 0
if [ -f "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; then
  echo "$(date '+%F %T') already recording, start.json ignored" >> "$ROOT/logs/launcher.log"
  exit 0
fi
if [ -f "$STATE/launching" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$STATE/launching") ))
  [ "$age" -lt 60 ] && exit 0
fi
touch "$STATE/launching"
echo "$(date '+%F %T') launching run.command" >> "$ROOT/logs/launcher.log"
open -a Terminal "$ROOT/bin/run.command"
