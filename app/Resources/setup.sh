#!/bin/bash
# Live Tips setup steps, run by the app's Setup window (one step at a time).
#   setup.sh check <step>     prints one line: "OK <detail>" or "MISSING <detail>"
#   setup.sh install <step>   prints progress lines; exit 0 = done
# Env: APPROOT (the app folder), BUNDLE (the app's Resources folder).
# Nothing here needs admin rights; everything goes into APPROOT (and the Hugging Face cache for Whisper).
set -u
STEP="${2:-}"; MODE="${1:-check}"
APPROOT="${APPROOT:?}"; BUNDLE="${BUNDLE:?}"
VENV="$APPROOT/.venv"; VPY="$VENV/bin/python"
WHISPER_MODEL="mlx-community/whisper-large-v3-turbo"
export PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1
mkdir -p "$APPROOT/logs" "$APPROOT/models"

find_python() {
  for c in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
           /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then echo "$c"; return 0; fi
  done
  return 1
}
vimport() { [ -x "$VPY" ] && "$VPY" -c "$1" >/dev/null 2>&1; }
pip_in() { "$VPY" -m pip install --progress-bar off "$@" 2>&1 | grep -E "^(Collecting|Installing|Successfully|ERROR)" ; return "${PIPESTATUS[0]}"; }

case "$MODE:$STEP" in
  check:python)
    if p=$(find_python); then echo "OK $("$p" --version 2>&1) ($p)"; else echo "MISSING Python 3.10 or newer"; fi ;;
  install:python)
    if command -v brew >/dev/null 2>&1; then echo "Installing Python 3.12 with Homebrew..."; brew install python@3.12
    elif ! xcode-select -p >/dev/null 2>&1; then
      echo "Opening the Command Line Tools installer (a macOS window). It brings Python 3.9 only:"
      echo "for Live Tips install Python 3.12 from python.org (the browser opens), then press Check again."
      xcode-select --install 2>/dev/null; open "https://www.python.org/downloads/macos/"; exit 1
    else echo "Install Python 3.12 from python.org (the browser opens), then press Check again."; open "https://www.python.org/downloads/macos/"; exit 1; fi ;;

  check:core)
    if [ -f "$APPROOT/src/transcriber.py" ] && cmp -s "$BUNDLE/core/VERSION" "$APPROOT/core.version" 2>/dev/null; then
      echo "OK $(cat "$APPROOT/core.version")"
    elif [ -f "$APPROOT/src/transcriber.py" ]; then echo "MISSING an older version is installed: will be updated"
    else echo "MISSING not installed yet"; fi ;;
  install:core)
    mkdir -p "$APPROOT/src" "$APPROOT/bin" "$APPROOT/control" "$APPROOT/state" "$APPROOT/voices" "$APPROOT/runs"
    cp -f "$BUNDLE/core/src/"* "$APPROOT/src/" && cp -f "$BUNDLE/core/bin/"* "$APPROOT/bin/" || exit 1
    [ -f "$APPROOT/config.json" ] || cp "$BUNDLE/core/config.json" "$APPROOT/config.json"
    xattr -dr com.apple.quarantine "$APPROOT/bin" "$APPROOT/src" 2>/dev/null
    chmod +x "$APPROOT/bin/"*
    cp "$BUNDLE/core/VERSION" "$APPROOT/core.version"
    echo "Recorder core copied to $APPROOT" ;;

  check:venv)
    if [ -x "$VPY" ] && "$VPY" -c 'import sys' 2>/dev/null; then echo "OK $("$VPY" --version 2>&1)"; else echo "MISSING"; fi ;;
  install:venv)
    p=$(find_python) || { echo "Python 3.10+ is needed first"; exit 1; }
    echo "Creating $VENV with $p"; "$p" -m venv "$VENV" && "$VPY" -m pip install -q --upgrade pip && echo "Done" ;;

  check:recorder)
    if vimport "import mlx_whisper, numpy"; then echo "OK mlx-whisper $("$VPY" -c 'import importlib.metadata as m;print(m.version("mlx-whisper"))' 2>/dev/null)"; else echo "MISSING"; fi ;;
  install:recorder)
    pip_in mlx-whisper numpy && { pip_in webrtcvad-wheels || echo "webrtcvad not available: a simpler speech detector is used"; } ;;

  check:tips)
    if vimport "import anthropic, yaml, jsonschema, onnxruntime, tokenizers"; then echo "OK"; else echo "MISSING"; fi ;;
  install:tips)
    pip_in "anthropic>=0.70" "pyyaml>=6" "jsonschema>=4.20" onnxruntime tokenizers ;;

  check:whisper)
    d="$HOME/.cache/huggingface/hub/models--${WHISPER_MODEL//\//--}"
    if [ -d "$d" ] && [ -n "$(find "$d" -name '*.safetensors' -o -name '*.npz' 2>/dev/null | head -1)" ]; then echo "OK $WHISPER_MODEL"; else echo "MISSING about 1.6 GB"; fi ;;
  install:whisper)
    echo "Downloading $WHISPER_MODEL (about 1.6 GB) and loading it once..."
    "$VPY" - "$WHISPER_MODEL" <<'PY'
import sys, numpy as np, mlx_whisper
mlx_whisper.transcribe(np.zeros(16000 * 3, dtype=np.float32), path_or_hf_repo=sys.argv[1], language="en", verbose=None)
print("Whisper is ready")
PY
    ;;

  check:localai)
    m="$APPROOT/models/bge-m3-int8"
    if [ -s "$m/model_quantized.onnx" ] && [ -s "$m/tokenizer.json" ]; then echo "OK bge-m3 int8"; else echo "MISSING about 590 MB"; fi ;;
  install:localai)
    m="$APPROOT/models/bge-m3-int8"; mkdir -p "$m"; base="https://huggingface.co/Xenova/bge-m3/resolve/main"
    for f in tokenizer.json config.json onnx/model_quantized.onnx; do
      out="$m/$(basename "$f")"; [ -s "$out" ] && { echo "have $(basename "$f")"; continue; }
      echo "Downloading $(basename "$f")..."
      curl -fL --retry 3 --connect-timeout 20 -o "$out.part" "$base/$f" 2>&1 | tr '\r' '\n' | grep -E "[0-9]+ +[0-9.]+[MG]" | tail -1
      [ -s "$out.part" ] && mv "$out.part" "$out" || { echo "download failed: $f"; exit 1; }
    done
    echo "Local AI model ready" ;;

  check:voices)
    if vimport "import sherpa_onnx" && [ -s "$APPROOT/models/wespeaker_en_voxceleb_resnet34_LM.onnx" ]; then echo "OK"; else echo "MISSING optional"; fi ;;
  install:voices)
    pip_in sherpa-onnx || exit 1
    n=wespeaker_en_voxceleb_resnet34_LM.onnx; out="$APPROOT/models/$n"
    [ -s "$out" ] || curl -fsSL --retry 3 -o "$out" "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$n" || exit 1
    echo "Speaker identification ready" ;;

  *) echo "usage: setup.sh check|install python|core|venv|recorder|tips|whisper|localai|voices"; exit 2 ;;
esac
