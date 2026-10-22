#!/bin/bash
# Speaker identification for live-transcriber (optional add-on, v37). Run once in Terminal:
#   bash ~/work/Tools/live-transcriber/bin/install-voices.sh
# Installs sherpa-onnx into <root>/.venv, downloads the voice model (~26 MB) into <root>/models/,
# and runs a self-test. Safe to re-run. Without it everything works as before: the other side
# of the call has one label instead of S1, S2, ... Log: logs/install-voices.log
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/.venv/bin/python"
NAME="wespeaker_en_voxceleb_resnet34_LM.onnx"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$NAME"
MODEL="$ROOT/models/$NAME"
mkdir -p "$ROOT/models" "$ROOT/voices" "$ROOT/logs"
LOG="$ROOT/logs/install-voices.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== install-voices $(date '+%F %T') ==="

fail() {
  echo "FAIL: $*"
  echo "Speaker identification stays off; calls are recorded as before. Details: $LOG"
  echo "=== install-voices FAILED ==="
  exit 1
}

# 1. Python environment of the recorder
[ -x "$PY" ] || fail "no $ROOT/.venv: run install.sh first"
echo "python: $("$PY" --version 2>&1)"

# 2. sherpa-onnx (prebuilt wheel, no compiler needed)
echo "--- pip install sherpa-onnx"
"$PY" -m pip install -q --upgrade sherpa-onnx || fail "pip install sherpa-onnx (no network, or no wheel for this Python)"
"$PY" -c "import sherpa_onnx; print('sherpa-onnx', getattr(sherpa_onnx, '__version__', '?'))" \
  || fail "sherpa-onnx is installed but does not import"

# 3. Voice model (a partial or broken download is replaced)
size_of() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
if [ -f "$MODEL" ] && [ "$(size_of "$MODEL")" -lt 20000000 ]; then
  echo "model file too small ($(size_of "$MODEL") bytes), downloading again"
  rm -f "$MODEL"
fi
if [ ! -f "$MODEL" ]; then
  echo "--- download $NAME (~26 MB)"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$MODEL.part" "$URL" || { rm -f "$MODEL.part"; fail "download $URL"; }
  [ "$(size_of "$MODEL.part")" -ge 20000000 ] || { rm -f "$MODEL.part"; fail "downloaded file is too small"; }
  mv "$MODEL.part" "$MODEL"
else
  echo "model already present: $MODEL"
fi

# 4. Self-test: loads the model the way the recorder does (and adds the mean-normalisation key once)
echo "--- self-test"
"$PY" "$ROOT/src/transcriber.py" --voices-check || fail "self-test"

echo "OK: speaker identification is ready. Next call: the other side is split into S1, S2, ...;"
echo "    name them in the tips window. Voice library: $ROOT/voices/voices.json (stays on this Mac)."
echo "=== install-voices OK $(date '+%F %T') ==="
