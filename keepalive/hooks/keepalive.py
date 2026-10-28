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
import re
import sys
import time

MARKER = os.path.join(os.path.expanduser("~"), ".live-tips", "keepalive.json")


def read_input(text):
    try:
        return json.loads(text or "{}")   # hook input: session_id, stop_hook_active
    except Exception:  # noqa: BLE001
        return {}


def load_marker(path):
    """(marker, until) or (None, None) when there is no readable marker."""
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
        return m, float(m.get("until", 0))
    except Exception:  # noqa: BLE001
        return None, None


def hold(m, until, sid, now):
    """The marker to save when this stop is blocked; None lets the turn end."""
    if m is None or now > until or not bind_session(m, sid):
        return None
    blocks = int(m.get("blocks", 0)) + 1
    if blocks > int(m.get("max_blocks", 400)):
        return None
    m["blocks"] = blocks
    return m


def bind_session(m, sid):
    """Security (audit 2026-10-27): the marker belongs to one session. The first session that is held binds it
    (the skill may also write session_id itself); every other session in the same HOME stops normally."""
    owner = str(m.get("session_id") or "")
    if owner and sid and owner != sid:
        return False
    if not owner and sid:
        m["session_id"] = sid
    return True


def save(m, path):
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(m, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        pass


def clean(v, n):
    """Only plain characters reach Claude: the reason is hook feedback, so no quotes, brackets or newlines."""
    return re.sub(r"[^\w .,:/~()-]", "", str(v or ""), flags=re.UNICODE)[:n].strip()


def reason(m, marker):
    title = clean(m.get("title"), 80) or "the call"
    state = clean(m.get("state_file"), 200)
    if not state.endswith(".state.json"):
        state = "the .state.json next to the transcript"
    return (
        f"live-tips: the call \"{title}\" is still being recorded. Do NOT end the turn. "
        f"Send anything for the PM with SendUserMessage, then make the next read_delta poll "
        f"(offset from {state}) and keep the live loop running. The turn may end only after "
        f"the PM said stop, the recording status is stopped, Step 4 and Step 5 are done and "
        f"the marker {marker} is removed."
    )


def main(stdin_text, marker=MARKER, now=None):
    sid = str(read_input(stdin_text).get("session_id") or "")
    m, until = load_marker(marker)
    m = hold(m, until, sid, time.time() if now is None else now)
    if m is None:
        return 0
    save(m, marker)
    print(json.dumps({"decision": "block", "reason": reason(m, marker)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.stdin.read()))
