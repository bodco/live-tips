#!/bin/bash
# Opened in Terminal by the LaunchAgent (or double-click) when control/start.json appears.
# Running inside Terminal keeps microphone / system-audio permissions attached to Terminal.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
printf '\033]0;Live transcriber\007'
echo "Live transcriber. Зупинка: Ctrl+C або команда скіла."
"$ROOT/.venv/bin/python" -u "$ROOT/src/transcriber.py" --from-control
code=$?
rm -f "$ROOT/state/launching"
echo
echo "Завершено (код $code). Вікно можна закрити."
exit $code
