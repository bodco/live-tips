#!/bin/bash
# Wrap the SwiftPM binary into LiveTips.app and sign it.
#   bundle.sh <version> <build> [identity]   identity: a code signing identity name; "-" = ad-hoc (default)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-0.0.1}"; BUILD="${2:-1}"; IDENT="${3:--}"
BUNDLE_ID="${LIVETIPS_BUNDLE_ID:-io.github.example.livetips}"
SCRATCH="${LIVETIPS_SCRATCH:-$HOME/Library/Caches/livetips-build}"
cd "$HERE" && swift build -c release --scratch-path "$SCRATCH"
APP="${LIVETIPS_APP_OUT:-$SCRATCH}/LiveTips.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/LiveTips" "$APP/Contents/MacOS/LiveTips"
mkdir -p "$APP/Contents/Helpers"
xcrun swiftc -O -o "$APP/Contents/Helpers/audiocap" "$HERE/Helpers/audiocap.swift"
codesign --force --sign "$IDENT" --identifier "$BUNDLE_ID.audiocap" "$APP/Contents/Helpers/audiocap"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>LiveTips</string>
<key>CFBundleExecutable</key><string>LiveTips</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>LiveTips transcribes your side of the call locally on this Mac.</string>
<key>NSAudioCaptureUsageDescription</key><string>LiveTips transcribes the other side of the call locally on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENT" --identifier "$BUNDLE_ID" "$APP"
codesign -dr - "$APP" 2>&1 | tail -1
echo "built $APP ($VER/$BUILD, identity $IDENT)"
