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
     @@CARD [HH:MM:SS] <id>: <line>  an instant card the recorder showed (cards.json trigger)
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
T0 = time.time()

def mac_now():
    """HH:MM:SS on the Mac clock. This script may run in a VM on UTC, so take the Mac's UTC
    offset from status.json `started_at` (e.g. 2026-10-14T12:28:27+03:00)."""
    from datetime import datetime, timezone
    try:
        started = json.load(open(a.status, encoding="utf-8")).get("started_at")
        tz = datetime.fromisoformat(started).tzinfo or timezone.utc
    except Exception:  # noqa: BLE001
        tz = None
    return datetime.now(tz).strftime("%H:%M:%S")


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
            obj.setdefault("at", mac_now())   # when the tip landed (latency stats)
            good.append(json.dumps(obj, ensure_ascii=False))
        except Exception as e:  # noqa: BLE001
            print(f"@@EMIT_ERROR {e}: {raw[:120]}")
    if good and a.tips:
        with open(a.tips, "a", encoding="utf-8") as f:
            f.write("\n".join(good) + "\n")
        emitted = len(good)


def mac_now_at(ts):
    from datetime import datetime, timezone
    try:
        started = json.load(open(a.status, encoding="utf-8")).get("started_at")
        tz = datetime.fromisoformat(started).tzinfo or timezone.utc
    except Exception:  # noqa: BLE001
        tz = None
    return datetime.fromtimestamp(ts, tz).strftime("%H:%M:%S")


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
            f"mic={s.get('mic')} system={s.get('system_audio')} errors={len(s.get('errors') or [])}"
            + (f" err={s['errors'][0][:80]}" if s.get("errors") else "")
            + (f" talk_me={s['talk_me_pct']}%" if s.get("talk_me_pct") is not None else "")
            + (f" mono={s['monologue_s']}s" if s.get("monologue_s") else "")
            + (f" asr_lag={s['asr_lag_s']}s" if s.get("asr_lag_s") is not None else ""))


def is_stopped():
    return status_line().startswith(("@@STATUS stopped", "@@STATUS error"))


def has_news():
    return size(a.file) > a.offset or (a.inbox and size(a.inbox) > a.inbox_offset)


def heartbeat():
    """Touch state/listener next to status.json: the tips window shows a warning when the
    skill has not polled for a while (its turn ended and nobody is listening)."""
    if not a.status:
        return
    try:
        p = os.path.join(os.path.dirname(os.path.abspath(a.status)), "listener")
        with open(p, "a"):
            os.utime(p, None)
    except OSError:
        pass


heartbeat()
deadline = time.time() + a.wait
while not has_news() and time.time() < deadline and not is_stopped():
    time.sleep(0.5)
    heartbeat()
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


def save_state():
    """Keep the mechanical part of <transcript>.state.json up to date on every poll, so the
    state survives even when the skill forgets to write it: offsets, poll count and the
    longest gap between two polls (loop stalls). The skill's own keys are kept as they are."""
    base = a.file[:-3] if a.file.endswith(".md") else a.file
    path = base + ".state.json"
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        if not isinstance(st, dict):
            st = {}
    except Exception:  # noqa: BLE001
        st = {}
    now = time.time()
    prev = st.get("last_poll_epoch")
    if isinstance(prev, (int, float)):
        gap = round(T0 - prev)   # time between the previous poll's end and this poll's start
        st["max_gap_s"] = max(int(st.get("max_gap_s") or 0), gap)
        if gap > 60:
            st["stalls_over_60s"] = int(st.get("stalls_over_60s") or 0) + 1
    # Per-poll timing log: `think_gap_s` = time between the previous poll's end and this poll's
    # start = Claude's thinking + tool overhead for the previous batch (where tip speed is lost).
    try:
        with open(base + ".polls.jsonl", "a", encoding="utf-8") as pf:
            pf.write(json.dumps({
                "start": mac_now_at(T0), "end": mac_now_at(now),
                "think_gap_s": round(T0 - prev, 1) if isinstance(prev, (int, float)) else None,
                "waited_s": round(now - T0, 1), "new_bytes": new - a.offset,
                "emitted": emitted}, ensure_ascii=False) + "\n")
    except OSError:
        pass
    # Instant cards fired by the recorder since the last poll (shown in the window already).
    fired = base + ".cards-fired.jsonl"
    coff = int(st.get("cards_offset") or 0)
    try:
        if os.path.getsize(fired) > coff:
            with open(fired, "rb") as f:
                f.seek(coff)
                chunk = f.read()
            cut = chunk.rfind(b"\n")
            if cut >= 0:
                for raw in chunk[:cut].decode("utf-8", "replace").splitlines():
                    try:
                        d = json.loads(raw)
                        print(f"@@CARD [{d.get('t', '')}] {d.get('id', '')}: {d.get('line', '')}")
                    except Exception:  # noqa: BLE001
                        pass
                st["cards_offset"] = coff + cut + 1
    except OSError:
        pass
    st.update(offset=new, last_poll_epoch=now, last_poll_at=mac_now(),
              polls=int(st.get("polls") or 0) + 1)
    if a.inbox:
        st["inbox_offset"] = inew
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(st, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except OSError:
        pass


save_state()
print(f"@@NOW {mac_now()}")
print(status_line())
