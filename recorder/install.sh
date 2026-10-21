#!/bin/bash
# live-transcriber installer. Run once in Terminal:  bash ~/work/Tools/live-transcriber/install.sh
# Safe to re-run. Full log: logs/install.log
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/logs" "$ROOT/control" "$ROOT/state" "$ROOT/bin"
LOG="$ROOT/logs/install.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== install $(date '+%F %T') ==="
fail() { echo "FAIL: $*"; echo "=== install FAILED ==="; exit 1; }

# 1. System
os=$(sw_vers -productVersion); arch=$(uname -m)
echo "macOS $os, $arch"
[ "$arch" = "arm64" ] || fail "потрібен Apple Silicon (mlx)"
major=${os%%.*}; rest=${os#*.}; minor=${rest%%.*}
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 2 ]; }; then
  fail "потрібен macOS 14.2+ для захоплення системного звуку"
fi

# 2. Swift toolchain
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Встановлюю Xcode Command Line Tools (з'явиться вікно). Після встановлення запусти install.sh ще раз."
  xcode-select --install
  fail "немає swiftc"
fi

# 3. Build audiocap
echo "--- build audiocap"
xcrun swiftc -O -o "$ROOT/bin/audiocap" "$ROOT/src/audiocap.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/src/Info.plist" \
  || fail "swiftc"
codesign -s - -f --identifier com.pm-control-tower.live-transcriber.audiocap "$ROOT/bin/audiocap" || echo "WARN: codesign"

# 3b. Build the tips window (optional: without it tips stay in the chat)
echo "--- build prompter (tips window)"
if xcrun swiftc -O -o "$ROOT/bin/prompter" "$ROOT/src/prompter.swift" -framework AppKit -framework WebKit; then
  codesign -s - -f --identifier com.pm-control-tower.live-transcriber.prompter "$ROOT/bin/prompter" || echo "WARN: codesign prompter"
  echo "prompter OK. Try it: $ROOT/bin/prompter --demo"
else
  echo "WARN: prompter not built, tips will stay in the chat (see the swiftc errors above)"
fi

# 4. Python
echo "--- python"
PY=""
for c in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
         /opt/homebrew/bin/python3.10 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -x "$c" ] || continue
  v=$("$c" -c 'import sys;print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null) || continue
  if [ "$v" -ge 310 ]; then PY="$c"; break; fi
done
[ -n "$PY" ] || fail "потрібен Python 3.10+: brew install python@3.12"
echo "python: $PY ($("$PY" --version))"
[ -x "$ROOT/.venv/bin/python" ] || "$PY" -m venv "$ROOT/.venv" || fail "venv"
"$ROOT/.venv/bin/python" -m pip install -q --upgrade pip
"$ROOT/.venv/bin/python" -m pip install -q mlx-whisper numpy || fail "pip mlx-whisper"
"$ROOT/.venv/bin/python" -m pip install -q webrtcvad-wheels || echo "WARN: webrtcvad-wheels не встав, буде енергетичний VAD"

# 5. Model download + warm-up (~1.6 GB on first run)
echo "--- model"
MODEL=$("$ROOT/.venv/bin/python" -c "import json;print(json.load(open('$ROOT/config.json'))['model'])")
"$ROOT/.venv/bin/python" - <<PYEOF || fail "model"
import numpy as np, time, mlx_whisper
t=time.time()
mlx_whisper.transcribe(np.zeros(16000*5, dtype=np.float32), path_or_hf_repo="$MODEL", language="uk", verbose=None)
print("model ready, 5 s of audio in %.2f s" % (time.time()-t))
try:
    import mlx.core as mx
    from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim
    from mlx_whisper.decoding import detect_language
    from mlx_whisper.transcribe import ModelHolder
    m = ModelHolder.get_model("$MODEL", mx.float16)
    mel = pad_or_trim(log_mel_spectrogram(np.zeros(16000, dtype=np.float32), n_mels=m.dims.n_mels, padding=N_SAMPLES), N_FRAMES, axis=-2).astype(mx.float16)
    _, p = detect_language(m, mel)
    print("restricted language detection: OK")
except Exception as e:
    print("restricted language detection: UNAVAILABLE", repr(e))
PYEOF

# 5b. Speaker identification (optional: sherpa-onnx + a 26 MB voice model). Never fatal.
#     Skip with LT_SKIP_VOICES=1; install later with: bash "$ROOT/bin/install-voices.sh"
if [ "${LT_SKIP_VOICES:-0}" != "1" ]; then
  echo "--- voices (speaker identification, optional)"
  bash "$ROOT/bin/install-voices.sh" || echo "WARN: speaker identification not installed; calls work as before. Later: bash $ROOT/bin/install-voices.sh"
fi

# 6. LaunchAgent
echo "--- launchd"
PLIST="$HOME/Library/LaunchAgents/com.pm-control-tower.live-transcriber.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__ROOT__#$ROOT#g" "$ROOT/launchd/com.pm-control-tower.live-transcriber.plist.template" > "$PLIST"
chmod +x "$ROOT/bin/"*.sh "$ROOT/bin/"*.command "$ROOT/bin/read_delta.py"
launchctl bootout "gui/$(id -u)/com.pm-control-tower.live-transcriber" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST" || fail "launchctl bootstrap"
echo "LaunchAgent loaded"

# 7. Permissions test (prompts appear for Terminal)
echo "--- permissions test: 5 c мікрофона і 5 c системного звуку"
echo "Якщо macOS спитає дозвіл на мікрофон або запис системного звуку для Terminal, дозволь."
"$ROOT/bin/audiocap" --source mic --seconds 5 > /tmp/lt-mic.raw 2>>"$ROOT/logs/audiocap-mic.log"
echo "mic bytes: $(stat -f %z /tmp/lt-mic.raw)"
echo "Увімкни будь-який звук (YouTube) на 5 с..."
"$ROOT/bin/audiocap" --source system --seconds 6 > /tmp/lt-sys.raw 2>>"$ROOT/logs/audiocap-system.log"
echo "system bytes: $(stat -f %z /tmp/lt-sys.raw)"
"$ROOT/.venv/bin/python" - <<'PYEOF'
import numpy as np
for name in ("mic", "sys"):
    a = np.fromfile(f"/tmp/lt-{name}.raw", dtype=np.float32)
    print(f"{name}: {len(a)/16000:.1f} s, peak {float(np.abs(a).max()) if len(a) else 0:.4f}")
PYEOF
tail -n 3 "$ROOT/logs/audiocap-mic.log" "$ROOT/logs/audiocap-system.log"
echo "=== install OK $(date '+%F %T') ==="
