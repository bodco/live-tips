#!/usr/bin/env python3
"""Long-poll reader for the live-tips skill: one call per loop iteration.

usage: read_delta.py FILE OFFSET [--wait 20] [--settle 2] [--status STATUS_JSON]
                     [--tips TIPS_JSONL] [--emit-stdin]
                     [--inbox INBOX_JSONL --inbox-offset N]

1. --emit-stdin: every non-empty stdin line (one JSON object = one tip) is appended to
   --tips first, so the tips window shows it at once. Invalid JSON lines are reported, not
   written.
2. Then waits up to --wait seconds until the transcript grows past OFFSET or the inbox
   (questions typed in the tips window) grows past --inbox-offset, plus --settle seconds so
   a burst arrives together.
3. Prints the new complete transcript lines, then:
     @@ASK [HH:MM:SS] <text>         one per new question from the tips window
     @@SET <key>=<value>             a setting changed with a button in the tips window
     @@OFFSET <new transcript offset>
     @@INBOX_OFFSET <new inbox offset>  (only with --inbox)
     @@EMITTED <n>                   (only with --emit-stdin)
     @@STATUS <state> lines=<n> queue=<n> mic=<..> system=<..> errors=<n>
Exit code 0 always; an empty delta is just the @@ lines.
"""
import argparse, json, os, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("offset", type=int)
ap.add_argument("--wait", type=float, default=20)
ap.add_argument("--settle", type=float, default=2)
ap.add_argument("--status")
ap.add_argument("--tips")
ap.add_argument("--emit-stdin", action="store_true")
ap.add_argument("--inbox")
ap.add_argument("--inbox-offset", type=int, default=0)
a = ap.parse_args()

emitted = 0
if a.emit_stdin:
    good = []
    for raw in sys.stdin.read().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
            if not isinstance(obj, dict):
                raise ValueError("not an object")
            good.append(json.dumps(obj, ensure_ascii=False))
        except Exception as e:  # noqa: BLE001
            print(f"@@EMIT_ERROR {e}: {raw[:120]}")
    if good and a.tips:
        with open(a.tips, "a", encoding="utf-8") as f:
            f.write("\n".join(good) + "\n")
        emitted = len(good)


def size(path):
    try:
        return os.path.getsize(path) if path else 0
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


def has_news():
    return size(a.file) > a.offset or (a.inbox and size(a.inbox) > a.inbox_offset)


deadline = time.time() + a.wait
while not has_news() and time.time() < deadline and not is_stopped():
    time.sleep(0.5)
if has_news():
    time.sleep(a.settle)


def read_complete(path, offset):
    """New complete lines after offset and the offset after the last newline."""
    if size(path) <= offset:
        return "", offset
    with open(path, "rb") as f:
        f.seek(offset)
        chunk = f.read()
    cut = chunk.rfind(b"\n")
    if cut < 0:
        return "", offset
    return chunk[:cut + 1].decode("utf-8", errors="replace"), offset + cut + 1


text, new = read_complete(a.file, a.offset)
print(text, end="")

if a.inbox:
    itext, inew = read_complete(a.inbox, a.inbox_offset)
    for line in itext.splitlines():
        try:
            q = json.loads(line)
            if q.get("kind") == "setting":
                # A control in the tips window changed a setting for this call.
                print(f"@@SET {q.get('key')}={q.get('value')}")
            else:
                print(f"@@ASK [{q.get('t', '')}] {q.get('text', '').strip()}")
        except Exception:  # noqa: BLE001
            if line.strip():
                print(f"@@ASK [] {line.strip()}")
print(f"@@OFFSET {new}")
if a.inbox:
    print(f"@@INBOX_OFFSET {inew}")
if a.emit_stdin:
    print(f"@@EMITTED {emitted}")
print(status_line())
