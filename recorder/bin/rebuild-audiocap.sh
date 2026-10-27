#!/bin/bash
# Rebuilds audiocap and tests the microphone in both modes (8 s each). Run in Terminal.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
umask 077
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
xcrun swiftc -O -o bin/audiocap.new src/audiocap.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/src/Info.plist"
codesign -s - -f --identifier com.pm-control-tower.live-transcriber.audiocap bin/audiocap.new
for mode in builtin default; do
  echo "=== mic test: $mode (говори 8 секунд)"
  perl -e 'alarm 25; exec @ARGV' bin/audiocap.new --source mic --device $mode --seconds 8 2>"$TMPD/audiocap-test-$mode.log" >"$TMPD/audiocap-test-$mode.pcm" || true
  bytes=$(wc -c < "$TMPD/audiocap-test-$mode.pcm" | tr -d ' ')
  restarts=$(grep -c "mic restart" "$TMPD/audiocap-test-$mode.log" || true)
  echo "bytes=$bytes restarts=$restarts"
  grep -E "mic:|mic input|retap|storm|denied|failed|hung|permission" "$TMPD/audiocap-test-$mode.log" | head -5
done
echo "Якщо bytes > 0 в обох режимах і restarts невеликий: mv bin/audiocap.new bin/audiocap"
