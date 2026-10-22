#!/bin/bash
# Runs the Notion mirror. Usage: run.sh [--full|--status|--discover]
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
cd "$(dirname "$0")" || exit 1
exec python3 mirror.py "$@"
