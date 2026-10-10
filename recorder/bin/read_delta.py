#!/usr/bin/env python3
"""Long-poll reader for the Cowork skill. Prints only NEW complete lines of the transcript.

usage: read_delta.py FILE OFFSET [--wait 20] [--settle 2] [--status STATUS_JSON]
Waits up to --wait seconds for the file to grow past OFFSET, then waits --settle seconds
so a burst of lines arrives together, prints the new complete lines, and ends with:
  @@OFFSET <new offset>
  @@STATUS <state> lines=<n> queue=<n> mic=<..> system=<..> errors=<n>
Exit code 0 always; an empty delta is just the two @@ lines.
"""
import argparse, json, os, time

ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("offset", type=int)
ap.add_argument("--wait", type=float, default=20)
ap.add_argument("--settle", type=float, default=2)
ap.add_argument("--status")
a = ap.parse_args()

def size():
    try:
        return os.path.getsize(a.file)
    except OSError:
        return 0

def status_line():
    if not a.status:
        return "@@STATUS unknown"
    try:
        s = json.load(open(a.status, encoding="utf-8"))
    except Exception:
        return "@@STATUS unreadable"
    return (f"@@STATUS {s.get('state')} lines={s.get('lines')} queue={s.get('queue')} "
            f"mic={s.get('mic')} system={s.get('system_audio')} errors={len(s.get('errors') or [])}")

def is_stopped():
    return status_line().startswith(("@@STATUS stopped", "@@STATUS error"))

deadline = time.time() + a.wait
while size() <= a.offset and time.time() < deadline and not is_stopped():
    time.sleep(0.5)
if size() > a.offset:
    time.sleep(a.settle)

new = a.offset
if size() > a.offset:
    with open(a.file, "rb") as f:
        f.seek(a.offset)
        chunk = f.read()
    cut = chunk.rfind(b"\n")
    if cut >= 0:
        text = chunk[:cut + 1].decode("utf-8", errors="replace")
        new = a.offset + cut + 1
        print(text, end="")
print(f"@@OFFSET {new}")
print(status_line())
