#!/usr/bin/env python3
"""Stop hook for live-tips.

While a live call is recorded, the live-tips skill keeps a marker file
$HOME/.live-tips/keepalive.json in the session's own environment:
  {"until": <unix time>, "title": "...", "state_file": "...", "max_blocks": 400}
If Claude tries to end its turn while the marker is valid, this hook blocks the
stop and tells Claude to go back to the read_delta loop. No marker, an expired
marker, a broken marker or too many blocks = the stop is allowed (fail open).
The skill removes the marker after the wrap-up and the Meetings DB page.
"""
import json
import os
import sys
import time

MARKER = os.path.join(os.path.expanduser("~"), ".live-tips", "keepalive.json")


def allow():
    sys.exit(0)


try:
    sys.stdin.read()            # hook input (session id, stop_hook_active); not needed
except Exception:  # noqa: BLE001
    pass

try:
    with open(MARKER, encoding="utf-8") as f:
        m = json.load(f)
    until = float(m.get("until", 0))
except Exception:  # noqa: BLE001
    allow()

if time.time() > until:
    allow()

blocks = int(m.get("blocks", 0)) + 1
if blocks > int(m.get("max_blocks", 400)):
    allow()
m["blocks"] = blocks
try:
    tmp = MARKER + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False)
    os.replace(tmp, MARKER)
except OSError:
    pass

title = m.get("title") or "the call"
state = m.get("state_file") or "the .state.json next to the transcript"
reason = (
    f"live-tips: the call \"{title}\" is still being recorded. Do NOT end the turn. "
    f"Send anything for the PM with SendUserMessage, then make the next read_delta poll "
    f"(offset from {state}) and keep the live loop running. The turn may end only after "
    f"the PM said stop, the recording status is stopped, Step 4 and Step 5 are done and "
    f"the marker {MARKER} is removed."
)
print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
