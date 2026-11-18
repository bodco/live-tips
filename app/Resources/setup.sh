#!/bin/bash
# Live Tips setup steps, run by the app's Setup window (one step at a time).
#   setup.sh check <step>     prints one line: "OK <detail>" or "MISSING <detail>"
#   setup.sh install <step>   prints progress lines; exit 0 = done
#   setup.sh size <step>      prints "SIZE <bytes>" (0.16.0, Settings > Components)
#   setup.sh remove <step>    removes an optional add-on (linkdl, agent); a required step exits 3
# 0.24.1 (F1): long steps print "PROGRESS <done> <total> <B|pkg>" lines (the app's one loader: MB, percent, ETA).
# Python is Pacenote's own (python-build-standalone 3.13, pinned URL and SHA-256, in APPROOT/python); a Python
# already on the Mac (3.10-3.14) is only the fallback when that download fails. Packages come from the lock files
# in BUNDLE/python (exact versions and hashes, --require-hashes): a new app version with a new lock updates them.
# Env: APPROOT (the app folder), BUNDLE (the app's Resources folder).
# Nothing here needs admin rights; everything goes into APPROOT (and the Hugging Face cache for Whisper).
set -u
STEP="${2:-}"; MODE="${1:-check}"
APPROOT="${APPROOT:?}"; BUNDLE="${BUNDLE:?}"
VENV="$APPROOT/.venv"; VPY="$VENV/bin/python"
WHISPER_MODEL="mlx-community/whisper-large-v3-turbo"
export PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1
mkdir -p "$APPROOT/logs" "$APPROOT/models"

# 0.24.1 (F1): Pacenote's own Python. Updating it = a new tag, URL, SHA-256 and size here (app/buildtools/lock.sh).
PY_VERSION="3.13.18"; PY_TAG="20261110"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/cpython-$PY_VERSION%2B$PY_TAG-aarch64-apple-darwin-install_only_stripped.tar.gz"
PY_SHA="7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540"; PY_SIZE=25479437
OWNPY="$APPROOT/python/bin/python3"
LOCKS="$BUNDLE/python"
# Packages that may fail without failing their step (a simpler speech detector is used without webrtcvad).
SOFT_PKGS=" webrtcvad-wheels "

py_supported() { "$1" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 14) else 1)' 2>/dev/null; }
# The Python the venv is made with: Pacenote's own, else the fallback a failed download chose (3.10-3.14 only;
# 0.24.1: 3.15 from the Python website has no wheels for onnxruntime and broke the first outside user's install).
find_python() {
  if [ -x "$OWNPY" ] && py_supported "$OWNPY"; then echo "$OWNPY"; return 0; fi
  if [ -s "$APPROOT/python.fallback" ]; then c="$(cat "$APPROOT/python.fallback")"; [ -x "$c" ] && py_supported "$c" && { echo "$c"; return 0; }; fi
  return 1
}
system_python() {
  for c in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
           /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$c" ] && py_supported "$c" && { echo "$c"; return 0; }
  done
  return 1
}
# A download with PROGRESS lines every second (curl in the background, the file size polled); size from the server
# when not given. dl <url> <out> [total bytes]
dl() {
  local url="$1" out="$2" total="${3:-}"
  [ -n "$total" ] || total=$(curl -sIL --connect-timeout 20 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
  curl -fsL --retry 3 --connect-timeout 20 -o "$out" "$url" & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do echo "PROGRESS $(stat -f%z "$out" 2>/dev/null || echo 0) ${total:-0} B"; sleep 1; done
  wait "$pid"
}
# Every package of a lock file, exact versions with hashes. All at once first; when that fails, one by one, so the
# log says which package failed and why, and the others still install (0.24.1: one bad wheel broke all five).
pip_lock() {
  local lock="$LOCKS/$1.lock"; [ -f "$lock" ] || { echo "ERROR lock file $1.lock is missing from the app"; return 1; }
  local reqs n=0 total; reqs=$(grep -oE '^[A-Za-z0-9._-]+==[^ ]+' "$lock"); total=$(echo "$reqs" | wc -l | tr -d ' ')
  "$VPY" -m pip install --progress-bar off --require-hashes --no-deps --only-binary :all: -r "$lock" 2>&1 | while IFS= read -r l; do
    case "$l" in Collecting*|"Requirement already satisfied"*) n=$((n + 1)); echo "PROGRESS $n $total pkg"; echo "$l" ;; Installing*|Successfully*|ERROR*) echo "$l" ;; esac
  done
  [ "${PIPESTATUS[0]}" = 0 ] && return 0
  echo "Installing the packages one by one to find what failed..."
  local failed="" r t
  for r in $reqs; do
    n=$((n + 1)); echo "PROGRESS $n $total pkg"
    t="$(mktemp)"; awk -v r="$r" '/^[A-Za-z0-9]/{p=(index($0, r " ")==1)} p' "$lock" > "$t"
    if ! "$VPY" -m pip install -q --progress-bar off --require-hashes --no-deps --only-binary :all: -r "$t" > "$t.out" 2>&1; then
      echo "FAILED $r: $(grep -m1 -E 'ERROR' "$t.out" | cut -c1-240)"
      case "$SOFT_PKGS" in *" ${r%%==*} "*) ;; *) failed="$failed ${r%%==*}" ;; esac
    fi
    rm -f "$t" "$t.out"
  done
  [ -z "$failed" ] && return 0
  echo "ERROR not installed:$failed"; return 1
}
# Installed versions against a lock file: prints nothing when they match, else what differs (missing or other version).
lock_diff() {
  [ -x "$VPY" ] && [ -f "$LOCKS/$1.lock" ] || { echo "not installed"; return; }
  "$VPY" - "$LOCKS/$1.lock" "$SOFT_PKGS" <<'PY' 2>/dev/null || echo "not checked"
import re, sys, importlib.metadata as m
soft = sys.argv[2].split(); bad = []
for name, ver in re.findall(r"^([A-Za-z0-9._-]+)==([^ \\]+)", open(sys.argv[1]).read(), re.M):
    if name in soft: continue
    try: have = m.version(name)
    except Exception: have = None
    if have != ver: bad.append(name + (" missing" if have is None else " " + have + " -> " + ver))
print(", ".join(bad[:6]) + (" and %d more" % (len(bad) - 6) if len(bad) > 6 else ""))
PY
}
vimport() { [ -x "$VPY" ] && "$VPY" -c "$1" >/dev/null 2>&1; }
# Security (audit 2026-10-27): packages are capped at the versions Live Tips was tested with (a new, possibly
# hijacked release is never picked up), and every downloaded model file is checked against its SHA-256.
sha_ok() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]; }
pip_in() { "$VPY" -m pip install --progress-bar off "$@" 2>&1 | grep -E "^(Collecting|Installing|Successfully|ERROR)" ; return "${PIPESTATUS[0]}"; }   # optional add-ons only
# 0.16.0 (D3): the size of files and folders in bytes, measured (du), "SIZE <bytes>"; a missing path counts 0.
sz() { local t=0 k; for p in "$@"; do [ -e "$p" ] || continue; k=$(du -sk "$p" 2>/dev/null | cut -f1); t=$((t + ${k:-0})); done; echo "SIZE $((t * 1024))"; }
SITE="$(ls -d "$VENV"/lib/python3*/site-packages 2>/dev/null | head -1)"; SITE="${SITE:-$VENV/none}"

case "$MODE:$STEP" in
  check:python)
    if [ -x "$OWNPY" ] && py_supported "$OWNPY"; then echo "OK $("$OWNPY" --version 2>&1) (Pacenote's own)"
    elif p=$(find_python); then echo "OK $("$p" --version 2>&1) ($p, fallback)"
    else echo "MISSING Python $PY_VERSION, about $((PY_SIZE / 1000000)) MB"; fi ;;
  install:python)
    # Pacenote's own Python: no browser, no Terminal, no admin rights (0.24.1, Bohdan 18.11).
    echo "Downloading Python $PY_VERSION (about $((PY_SIZE / 1000000)) MB)..."
    t="$APPROOT/.python.tar.gz"; rm -f "$t"
    if dl "$PY_URL" "$t" "$PY_SIZE" && [ -s "$t" ] && sha_ok "$t" "$PY_SHA"; then
      rm -rf "$APPROOT/.python.new" && mkdir -p "$APPROOT/.python.new" && tar -xzf "$t" -C "$APPROOT/.python.new" || { echo "ERROR could not unpack Python"; exit 1; }
      rm -rf "$APPROOT/python" && mv "$APPROOT/.python.new/python" "$APPROOT/python" && rm -rf "$APPROOT/.python.new" "$t"
      xattr -dr com.apple.quarantine "$APPROOT/python" 2>/dev/null
      rm -f "$APPROOT/python.fallback"
      py_supported "$OWNPY" || { echo "ERROR the downloaded Python does not start"; exit 1; }
      echo "Python $PY_VERSION ready"
    else
      [ -s "$t" ] && ! sha_ok "$t" "$PY_SHA" && echo "ERROR checksum mismatch for Python: refused (the file on the server changed)"
      rm -f "$t"
      if p=$(system_python); then echo "$p" > "$APPROOT/python.fallback"; echo "Download failed: using the Python already on this Mac ($("$p" --version 2>&1))"
      else echo "ERROR could not download Python. Check the internet connection and press Install again."; exit 1; fi
    fi ;;

  check:core)
    if [ -f "$APPROOT/src/transcriber.py" ] && cmp -s "$BUNDLE/core/VERSION" "$APPROOT/core.version" 2>/dev/null; then
      echo "OK $(cat "$APPROOT/core.version")"
    elif [ -f "$APPROOT/src/transcriber.py" ]; then echo "MISSING an older version is installed: will be updated"
    else echo "MISSING not installed yet"; fi ;;
  install:core)
    mkdir -p "$APPROOT/src" "$APPROOT/bin" "$APPROOT/control" "$APPROOT/state" "$APPROOT/voices" "$APPROOT/runs"
    cp -f "$BUNDLE/core/src/"* "$APPROOT/src/" || exit 1
    # Binaries are replaced by a new file (copy, then rename), never overwritten in place: macOS keeps the
    # code signature of a running or recently run binary per file, and an in-place copy gets it killed at
    # launch (SIGKILL, "exited with -9"; 2026-10-23: a whole call recorded nothing).
    for f in "$BUNDLE/core/bin/"*; do
      n="$(basename "$f")"; cp -f "$f" "$APPROOT/bin/.$n.new" && mv -f "$APPROOT/bin/.$n.new" "$APPROOT/bin/$n" || exit 1
    done
    [ -f "$APPROOT/config.json" ] || cp "$BUNDLE/core/config.json" "$APPROOT/config.json"
    xattr -dr com.apple.quarantine "$APPROOT/bin" "$APPROOT/src" 2>/dev/null
    chmod +x "$APPROOT/bin/"*
    cp "$BUNDLE/core/VERSION" "$APPROOT/core.version"
    echo "Recorder core copied to $APPROOT" ;;

  check:venv)
    # 0.24.1: a venv made with an unsupported Python (3.15) or with another Python than the one chosen is rebuilt.
    if [ -x "$VPY" ] && "$VPY" -c 'import sys' 2>/dev/null && py_supported "$VPY" && p=$(find_python) \
       && [ "$("$VPY" -c 'import sys;print(sys.version_info[:2])')" = "$("$p" -c 'import sys;print(sys.version_info[:2])')" ]; then
      echo "OK $("$VPY" --version 2>&1)"
    elif [ -x "$VPY" ]; then echo "MISSING made with another Python: will be rebuilt"; else echo "MISSING"; fi ;;
  install:venv)
    p=$(find_python) || { echo "ERROR Python is needed first"; exit 1; }
    echo "Creating $VENV with $("$p" --version 2>&1)"; "$p" -m venv --clear "$VENV" && echo "Done" ;;

  check:recorder)
    d=$(lock_diff recorder)
    if [ -z "$d" ] && vimport "import mlx_whisper, numpy"; then echo "OK mlx-whisper $("$VPY" -c 'import importlib.metadata as m;print(m.version("mlx-whisper"))' 2>/dev/null)"
    else echo "MISSING ${d:-not installed}"; fi ;;
  install:recorder) pip_lock recorder ;;

  check:tips)
    d=$(lock_diff tips)
    if [ -z "$d" ] && vimport "import anthropic, yaml, jsonschema, onnxruntime, tokenizers"; then echo "OK"; else echo "MISSING ${d:-not installed}"; fi ;;
  install:tips) pip_lock tips ;;

  check:whisper)
    d="$HOME/.cache/huggingface/hub/models--${WHISPER_MODEL//\//--}"
    if [ -d "$d" ] && [ -n "$(find "$d" -name '*.safetensors' -o -name '*.npz' 2>/dev/null | head -1)" ]; then echo "OK $WHISPER_MODEL"; else echo "MISSING about 1.6 GB"; fi ;;
  install:whisper)
    echo "Downloading $WHISPER_MODEL (about 1.6 GB) and loading it once..."
    d="$HOME/.cache/huggingface/hub/models--${WHISPER_MODEL//\//--}"
    ( while sleep 2; do echo "PROGRESS $(( $(du -sk "$d" 2>/dev/null | cut -f1 || echo 0) * 1024 )) 1620000000 B"; done ) & tick=$!
    "$VPY" - "$WHISPER_MODEL" <<'PY'
import sys, numpy as np, mlx_whisper
mlx_whisper.transcribe(np.zeros(16000 * 3, dtype=np.float32), path_or_hf_repo=sys.argv[1], language="en", verbose=None)
print("Whisper is ready")
PY
    rc=$?; kill "$tick" 2>/dev/null; exit $rc ;;

  check:localai)
    m="$APPROOT/models/bge-m3-int8"
    if [ -s "$m/model_quantized.onnx" ] && [ -s "$m/tokenizer.json" ]; then echo "OK bge-m3 int8"; else echo "MISSING about 590 MB"; fi ;;
  install:localai)
    m="$APPROOT/models/bge-m3-int8"; mkdir -p "$m"; base="https://huggingface.co/Xenova/bge-m3/resolve/main"
    for fh in tokenizer.json:6710678b12670bc442b99edc952c4d996ae309a7020c1fa0096dd245c2faf790 \
              config.json:734a79bf12d388c1467a4e3ab625f45de7f6906cffcfb93a1eca1787504bed95 \
              onnx/model_quantized.onnx:0826f8c1ab9edf1801db86c61919d4d108e8bfc0b809ec823ad366882ff0b77d; do
      f="${fh%%:*}"; h="${fh##*:}"
      out="$m/$(basename "$f")"; [ -s "$out" ] && sha_ok "$out" "$h" && { echo "have $(basename "$f")"; continue; }
      echo "Downloading $(basename "$f")..."
      dl "$base/$f" "$out.part"
      [ -s "$out.part" ] || { echo "download failed: $f"; exit 1; }
      sha_ok "$out.part" "$h" || { rm -f "$out.part"; echo "checksum mismatch for $f: refused (the file on the server changed)"; exit 1; }
      mv "$out.part" "$out"
    done
    echo "Local AI model ready" ;;

  check:voices)
    d=$(lock_diff voices)
    if [ -z "$d" ] && vimport "import sherpa_onnx" && [ -s "$APPROOT/models/wespeaker_en_voxceleb_resnet34_LM.onnx" ]; then echo "OK"; else echo "MISSING ${d:-not installed}"; fi ;;
  install:voices)
    pip_lock voices || exit 1
    n=wespeaker_en_voxceleb_resnet34_LM.onnx; out="$APPROOT/models/$n"; h=ce2c5db3fb2c438f1d58de35577c951bc27ea0d41ef74968de4a480a1a59e39b
    # 0.24.1: sherpa-onnx re-uploaded this file without its feature_normalize_type metadata (other embeddings, saved
    # voices stop matching), so Pacenote's own copy of the pinned file comes first; the original is the fallback.
    if ! { [ -s "$out" ] && sha_ok "$out" "$h"; }; then
      for u in "https://github.com/bodco/live-tips/releases/download/models-wespeaker-1/$n" \
               "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/$n"; do
        rm -f "$out.part"
        dl "$u" "$out.part" 26530589 && sha_ok "$out.part" "$h" && { mv "$out.part" "$out"; break; }
        echo "$n from $u: download failed or checksum mismatch, refused"
      done
      rm -f "$out.part"
      [ -s "$out" ] && sha_ok "$out" "$h" || { echo "ERROR checksum mismatch for $n: refused"; exit 1; }
    fi
    echo "Speaker identification ready" ;;

  # 0.24.1 (F1, Bohdan 18.11): not a component any more. Claude Code is installed only when the PM connects a Claude
  # account (Settings > AI, onboarding); with an API key the app talks to the API itself. The official native
  # installer puts it into ~/.local/bin without admin rights (https://code.claude.com/docs/en/setup).
  check:claude)
    for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
      if [ -x "$c" ]; then v=$("$c" --version 2>/dev/null | head -1); echo "OK ${v:-installed} ($c)"; exit 0; fi
    done
    echo "MISSING needed for preparing calls" ;;
  install:claude)
    echo "Installing Claude Code with the official installer (claude.ai/install.sh)..."
    curl -fsSL --retry 3 --connect-timeout 20 https://claude.ai/install.sh | bash 2>&1 | tail -5
    [ -x "$HOME/.local/bin/claude" ] || { echo "Claude Code was not installed. See https://code.claude.com/docs/en/troubleshoot-install"; exit 1; }
    echo "Claude Code ready" ;;

  # 0.24.1 (F1): the Codex CLI for a ChatGPT account, installed when the PM connects that account: OpenAI's own
  # release binary for macOS arm64, pinned version and SHA-256 (GitHub's digest), into ~/.local/bin. No npm, no Terminal.
  check:codex)
    for c in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
      if [ -x "$c" ]; then v=$("$c" --version 2>/dev/null | head -1); echo "OK ${v:-installed} ($c)"; exit 0; fi
    done
    echo "MISSING needed for a ChatGPT account" ;;
  install:codex)
    CX_VER="0.170.0"; CX_SHA="7c9f21d5cbae4860d14b379fdcf709ff399ce874fd714b58783e1b4199c2b9a9"; CX_SIZE=114545562
    echo "Downloading Codex $CX_VER (about $((CX_SIZE / 1000000)) MB)..."
    t="$APPROOT/.codex.tar.gz"; rm -f "$t"; mkdir -p "$HOME/.local/bin"
    dl "https://github.com/openai/codex/releases/download/rust-v$CX_VER/codex-aarch64-apple-darwin.tar.gz" "$t" "$CX_SIZE" || { rm -f "$t"; echo "ERROR could not download Codex"; exit 1; }
    sha_ok "$t" "$CX_SHA" || { rm -f "$t"; echo "ERROR checksum mismatch for Codex: refused"; exit 1; }
    rm -rf "$APPROOT/.codex.new" && mkdir -p "$APPROOT/.codex.new" && tar -xzf "$t" -C "$APPROOT/.codex.new" && rm -f "$t"
    b="$(find "$APPROOT/.codex.new" -type f -name 'codex*' | head -1)"; [ -n "$b" ] || { echo "ERROR the Codex archive has no program"; exit 1; }
    xattr -d com.apple.quarantine "$b" 2>/dev/null; chmod +x "$b"; mv -f "$b" "$HOME/.local/bin/.codex.new" && mv -f "$HOME/.local/bin/.codex.new" "$HOME/.local/bin/codex"
    rm -rf "$APPROOT/.codex.new"; echo "Codex ready" ;;

  # 0.8.6 (rules/components.yaml): the optional Link downloader for Transcribe a recording (Google Drive, YouTube, Vimeo).
  check:linkdl)
    if vimport "import yt_dlp"; then echo "OK $("$VPY" -c 'import yt_dlp.version as v;print(v.__version__)' 2>/dev/null)"; else echo "MISSING optional"; fi ;;
  install:linkdl)
    pip_in --upgrade "yt-dlp>=2025.1.1" && echo "Link downloader ready" ;;

  # 0.9.6 (owner): the optional call agent (Settings > AI > Call agent): the Claude Agent SDK, which brings its own
  # Claude Code (about 320 MB in the app's Python). Needs Python 3.10+; only the API key is used, never a login.
  check:agent)
    if vimport "import sys, claude_agent_sdk; sys.exit(0 if sys.version_info >= (3, 10) else 1)"; then echo "OK $("$VPY" -c 'import importlib.metadata as m;print(m.version("claude-agent-sdk"))' 2>/dev/null)"; else echo "MISSING optional"; fi ;;
  install:agent)
    "$VPY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || { echo "The call agent needs Python 3.10 or newer"; exit 1; }
    pip_in "claude-agent-sdk>=0.2.170,<=0.2.178" && echo "Call agent ready" ;;


  # 0.16.0 (D3, Settings > Components): sizes on disk ("SIZE <bytes>") and removing the optional Python add-ons.
  # The model in Ollama is measured and removed by the app (LocalLLM), never here. Required parts are never removed.
  size:core) sz "$APPROOT/src" "$APPROOT/bin" ;;
  size:venv) sz "$VENV" ;;
  size:python) sz "$APPROOT/python" ;;
  size:recorder|size:tips) echo "SIZE 0" ;;
  size:whisper) sz "$HOME/.cache/huggingface/hub/models--${WHISPER_MODEL//\//--}" ;;
  size:localai) sz "$APPROOT/models/bge-m3-int8" ;;
  size:voices) sz "$APPROOT/models/wespeaker_en_voxceleb_resnet34_LM.onnx" ;;
  size:linkdl) sz "$SITE/yt_dlp" "$SITE"/yt_dlp-*.dist-info ;;
  size:agent) sz "$SITE/claude_agent_sdk" "$SITE"/claude_agent_sdk-*.dist-info ;;
  remove:linkdl)
    "$VPY" -m pip uninstall -y yt-dlp 2>&1 | grep -E "^(Found|Uninstalling|Successfully|WARNING)"; vimport "import yt_dlp" && exit 1
    echo "Link downloader removed" ;;
  remove:agent)
    "$VPY" -m pip uninstall -y claude-agent-sdk 2>&1 | grep -E "^(Found|Uninstalling|Successfully|WARNING)"; vimport "import claude_agent_sdk" && exit 1
    echo "Call agent removed" ;;
  remove:*) echo "$STEP is required and cannot be removed"; exit 3 ;;
  *) echo "usage: setup.sh check|install|size python|core|venv|recorder|tips|whisper|localai|voices|claude|codex|linkdl|agent; setup.sh remove linkdl|agent"; exit 2 ;;
esac
