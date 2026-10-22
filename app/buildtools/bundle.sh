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
# Shared tips window (same file as the skill's live-transcriber; parity).
PROMPTER_HTML="${LIVETIPS_PROMPTER_HTML:-$HERE/Resources/prompter.html}"
cp "$PROMPTER_HTML" "$APP/Contents/Resources/prompter.html"
# App icon, drawn at build time (no binary assets in the repo)
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
xcrun swift "$HERE/buildtools/make_icon.swift" "$ICONSET" >/dev/null && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "icon: skipped"
# Self-contained beta (2026-10-22): the recorder core and the tips engine travel inside the app;
# the Setup window copies the core into the app folder and installs Python modules and models.
LT="$HERE/../../live-transcriber"
CORE="$APP/Contents/Resources/core"; mkdir -p "$CORE/src" "$CORE/bin"
cp "$LT/src/transcriber.py" "$LT/src/semantic.py" "$CORE/src/"
cp "$LT/bin/lt" "$LT/bin/read_delta.py" "$CORE/bin/"
cp "$LT/config.json" "$CORE/config.json"
xcrun swiftc -O -o "$CORE/bin/audiocap" "$LT/src/audiocap.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$LT/src/Info.plist"
codesign --force --sign "$IDENT" --identifier "$BUNDLE_ID.recorder-audiocap" "$CORE/bin/audiocap"
echo "$VER-$BUILD" > "$CORE/VERSION"
ENG="$APP/Contents/Resources/engine"; mkdir -p "$ENG/spikes/m0"
rsync -a --exclude __pycache__ --exclude generated "$HERE/../rules/" "$ENG/rules/"
rsync -a --exclude __pycache__ "$HERE/../spikes/m0/livetips_m0" "$ENG/spikes/m0/"
cp "$HERE/Resources/setup.sh" "$APP/Contents/Resources/setup.sh"
mkdir -p "$APP/Contents/Helpers"
xcrun swiftc -O -o "$APP/Contents/Helpers/audiocap" "$HERE/Helpers/audiocap.swift"
codesign --force --sign "$IDENT" --identifier "$BUNDLE_ID.audiocap" "$APP/Contents/Helpers/audiocap"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Live Tips</string>
<key>CFBundleDisplayName</key><string>Live Tips</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>LiveTips</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSMicrophoneUsageDescription</key><string>LiveTips transcribes your side of the call locally on this Mac.</string>
<key>NSAudioCaptureUsageDescription</key><string>LiveTips transcribes the other side of the call locally on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENT" --identifier "$BUNDLE_ID" "$APP"
codesign -dr - "$APP" 2>&1 | tail -1
echo "built $APP ($VER/$BUILD, identity $IDENT)"
