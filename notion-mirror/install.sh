#!/bin/bash
# Installs (or reinstalls) a launchd job that runs the mirror every 2 hours from 08:07 to 20:07.
# Not needed when the Live Tips app runs the mirror (Settings > General > Notion mirror > Set up sync).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="io.github.example.notion-mirror"
PL="$HOME/Library/LaunchAgents/$LABEL.plist"
[ -f "$DIR/mirror.config.json" ] || { echo "Copy mirror.config.example.json to mirror.config.json and fill it first"; exit 1; }
mkdir -p "$DIR/logs" "$HOME/Library/LaunchAgents"
chmod +x "$DIR/run.sh"
HOURS=""; for h in 8 10 12 14 16 18 20; do HOURS="$HOURS<dict><key>Hour</key><integer>$h</integer><key>Minute</key><integer>7</integer></dict>"; done
cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$DIR/run.sh</string></array>
<key>RunAtLoad</key><true/>
<key>StartCalendarInterval</key><array>$HOURS</array>
<key>StandardErrorPath</key><string>$DIR/logs/launchd.err.log</string>
<key>ProcessType</key><string>Background</string><key>Nice</key><integer>10</integer><key>LowPriorityIO</key><true/>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PL"
echo "Installed. The first (full) sync is running in the background. Progress: tail -f \"$DIR/logs/mirror.log\""
