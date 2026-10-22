#!/usr/bin/env python3
"""Long-poll reader for the live-tips skill: one call per loop iteration.

usage: read_delta.py FILE OFFSET|auto [--wait 20] [--settle 2] [--status STATUS_JSON]
                     [--tips TIPS_JSONL] [--emit-stdin]
                     [--inbox INBOX_JSONL [--inbox-offset N|auto]]

OFFSET `auto` takes `offset` (and `inbox_offset`, unless --inbox-offset is given) from
<stem>.state.json, which this script keeps up to date on every poll.

1. --emit-stdin: every non-empty stdin line (one JSON object = one tip) is appended to
   --tips first, so the tips window shows it at once. Invalid JSON lines are reported, not
   written. A line {"kind": "state", ...} is NOT a tip: its other keys are merged into
   <stem>.state.json (under a lock; offsets never go back) and `skill_state_at` is stamped.
   A line {"kind": "ack", "key": K} acknowledges a setting change (see @@DUE ack).
2. Then waits up to --wait seconds until the transcript grows past OFFSET or the inbox
   (questions typed in the tips window) grows past the inbox offset, plus a settle time so
   a burst arrives together: 0 when a new line of the other side looks like a question (or
   only the inbox changed), otherwise --settle.
3. Prints the new complete transcript lines, then:
     @@ASK [HH:MM:SS] <text>         one per new question from the tips window
     @@SOS [HH:MM:SS]                the red HELP NOW button (ask text "sos")
     @@OFFTOPIC [HH:MM:SS]           the "Not this topic" button (ask text "off topic")
     @@SET <key>=<value>             a setting changed with a button in the tips window
                                     (tip_feedback is also logged to <stem>.feedback.jsonl)
     @@OFFSET <new transcript offset>
     @@INBOX_OFFSET <new inbox offset>  (only with --inbox)
     @@EMITTED <n>                   (only with --emit-stdin)
     @@STATE_MERGED <keys>           (only when a {"kind":"state"} line arrived)
     @@CARD [HH:MM:SS] <id>: <line>  an instant card the recorder showed (cards.json trigger)
     @@LATE <n>s: <gist>             a tip shown as late: the PM had already started answering
                                     (marked late:true in the window, logged to <stem>.late.jsonl)
     @@NOW HH:MM:SS
     @@STATUS <state> lines=<n> queue=<n> mic=<..> system=<..> errors=<n> ... semantic=<on|off|loading>
     @@STATUS stale state=recording no_update_s=<n> ...   the recorder stopped updating
                                     status.json (seq unchanged > 6 s, or mtime > 15 s without seq)
     @@MODE <presenting|discussion> talk_me=<pct>   (auto call type, only when the mode changes)
     @@SPEAKERS S1=<name> S2=? ...   the speaker mapping (a name with spaces or quotes is JSON-quoted:
                                     S1="Ірина Петрівна"), printed when <stem>.speakers.json `rev`
                                     (= status speakers_rev) changed since the last poll
     @@DUE prep <what>               recording and cards.json or facts.json missing or invalid
     @@DUE state <why>               recording and skill_state_at older than 300 s
                                     (or missing after 120 s of recording)
     @@DUE ack <key>                 a call_type|hiring_role|audience|comment_rate_seconds|proactive
                                     setting not acknowledged by a {"kind":"ack","key":..} line
                                     within 2 polls
     @@DUE wrapup                    the recording is stopped and the tips file has no kind wrapup
Transcript lines of the other side tagged by the recorder as `{them_label} [S2]` are printed with the
speaker's name instead (`Ірина`, or `Speaker 2` while unnamed), merges and per-line fixes from
<stem>.speakers.json applied. The md file itself keeps the tags; offsets are byte offsets of the file.
Exit code 0 always; an empty delta is just the @@ lines.
"""
import argparse, json, os, re, sys, time
from contextlib import contextmanager

try:
    import fcntl
except ImportError:  # pragma: no cover (not on macOS / Linux)
    fcntl = None

QUESTION_CUE = re.compile(
    r"\?|скільки|коли|як довго|термін|естімейт|оцінк|дедлайн|статус|ціна|вартіст|сколько|когда|"
    r"how long|how much|how many|when|estimate|\beta\b|deadline|status|price|cost", re.I)
LINE_RX = re.compile(r"^\[(\d\d:\d\d:\d\d)\] (.+?) \((\w+)\): (.*)$")
TAGGED_RX = re.compile(r"^\[(\d\d:\d\d:\d\d)\] (.+?) \[(S\d+)\] \((\w+)\): ")
PLAIN_RX = re.compile(r"^\[(\d\d:\d\d:\d\d)\] (.+?) \((\w+)\): ")
SID_RX = re.compile(r"^S(\d+)$")
ACK_KEYS = ("call_type", "hiring_role", "audience", "comment_rate_seconds", "proactive")
OFFSET_KEYS = ("offset", "inbox_offset", "cards_offset")
AUTO_CALL_TYPES = ("", "auto", "status", "topic", "client", None)


# ---------------------------------------------------------------- pure helpers (unit-tested)
def _sec(hms):
    try:
        h, m, x = str(hms).split(":")
        return int(h) * 3600 + int(m) * 60 + int(float(x))
    except Exception:  # noqa: BLE001
        return None


def parse_lines(text):
    """[(hh:mm:ss, who, lang, text)] for the transcript lines in text."""
    out = []
    for ln in text.splitlines():
        m = LINE_RX.match(ln)
        if m:
            out.append(m.groups())
    return out


def load_speakers(path):
    """<stem>.speakers.json as a dict, or None (missing, half-written or not a dict)."""
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:  # noqa: BLE001
        return None


def speaker_labeler(sp):
    """label(line_time, sid) -> display name, with merges and per-line overrides applied.
    Keep in sync with SpeakerTracker.label in transcriber.py and lt."""
    clusters = sp.get("clusters") if isinstance(sp.get("clusters"), dict) else {}
    merged = sp.get("merged") if isinstance(sp.get("merged"), dict) else {}
    overrides = sp.get("overrides") if isinstance(sp.get("overrides"), dict) else {}

    def resolve(s):
        seen = set()
        while s in merged and s not in seen:
            seen.add(s)
            s = merged[s]
        return s

    def label(t, sid):
        s = resolve(overrides.get(t) or sid)
        if not s:
            return None
        c = clusters.get(s)
        name = c.get("name") if isinstance(c, dict) else None
        if name:
            return str(name)
        m = SID_RX.match(str(s))
        return f"Speaker {m.group(1)}" if m else None
    return label


def name_lines(text, sp, me_label):
    """Replace `{them_label} [S2]` by the speaker's name in transcript lines (see the module doc).
    An untagged line of the other side is renamed only when the PM fixed that line."""
    if not sp or not text:
        return text
    label = speaker_labeler(sp)
    overrides = sp.get("overrides") if isinstance(sp.get("overrides"), dict) else {}
    out = []
    for ln in text.splitlines(keepends=True):
        m = TAGGED_RX.match(ln)
        if m:
            lab = label(m.group(1), m.group(3))
            if lab:
                ln = f"[{m.group(1)}] {lab} ({m.group(4)}): " + ln[m.end():]
        else:
            m = PLAIN_RX.match(ln)
            if m and m.group(2) != me_label and m.group(1) in overrides:
                lab = label(m.group(1), None)
                if lab:
                    ln = f"[{m.group(1)}] {lab} ({m.group(3)}): " + ln[m.end():]
        out.append(ln)
    return "".join(out)


def speakers_line(sp):
    """@@SPEAKERS S1=Ірина S2=? (clusters by number; merged-away clusters are not listed)."""
    cl = sp.get("clusters") if isinstance(sp.get("clusters"), dict) else {}
    keys = sorted(cl, key=lambda s: int(SID_RX.match(s).group(1)) if SID_RX.match(str(s)) else 10 ** 6)
    parts = []
    for k in keys:
        c = cl.get(k)
        name = c.get("name") if isinstance(c, dict) else None
        if not name:
            parts.append(f"{k}=?")
        elif re.search(r"[\s\"'=]", str(name)):
            parts.append(f"{k}={json.dumps(str(name), ensure_ascii=False)}")   # S2="Ірина Петрівна"
        else:
            parts.append(f"{k}={name}")
    return "@@SPEAKERS " + (" ".join(parts) if parts else "none")


def settle_for(new_text, me_label, settle):
    """Adaptive settle: 0 when any new line of the other side contains '?' or a question cue
    (answer fast), otherwise the normal settle."""
    for _t, who, _l, txt in parse_lines(new_text):
        if who != me_label and QUESTION_CUE.search(txt):
            return 0.0
    return settle


def unwrap_seconds(times):
    """Seconds of day -> monotonic seconds (a call that crosses midnight keeps growing)."""
    out, add, prev = [], 0, None
    for t in times:
        if prev is not None and t + add < prev - 43200:
            add += 86400
        out.append(t + add)
        prev = t + add
    return out


def detect_mode(lines, me_label, prev_mode, window_s=120, enter_pct=65, leave_pct=55):
    """Presenting when the PM's share of the talk (by characters) over the last `window_s`
    is above enter_pct; a call already presenting goes back to discussion only below leave_pct
    (hysteresis, so the mode does not flicker around the threshold). Needs `window_s` of
    transcript. Returns (mode or None, pct or None)."""
    pts = [(s, who, txt) for (t, who, _l, txt) in lines for s in [_sec(t)] if s is not None]
    if not pts:
        return None, None
    mono = unwrap_seconds([p[0] for p in pts])
    last = mono[-1]
    if last - mono[0] < window_s:
        return None, None
    me = them = 0
    for s, (_s0, who, txt) in zip(mono, pts):
        if s >= last - window_s:
            if who == me_label:
                me += len(txt)
            else:
                them += len(txt)
    if me + them == 0:
        return None, None
    pct = round(100 * me / (me + them))
    if prev_mode == "presenting":
        mode = "presenting" if pct >= leave_pct else "discussion"
    else:
        mode = "presenting" if pct > enter_pct else "discussion"
    return mode, pct


def prep_file_state(path, key):
    """'ok' | 'MISSING' | 'INVALID': a JSON list, or {key: [...]}, with at least one object."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return "MISSING"
    except Exception:  # noqa: BLE001
        return "INVALID"
    if isinstance(data, dict):
        data = data.get(key, data.get("items"))
    if not isinstance(data, list) or not any(isinstance(x, dict) for x in data):
        return "INVALID"
    return "ok"


def compute_due(now_t, recording, started_ts, st, prep, stopped_here, has_wrapup, poll_no):
    """The @@DUE reminders for the skill (see the module doc)."""
    out = []
    if recording:
        bad = [f"{k}={v}" for k, v in prep.items() if v != "ok"]
        if bad:
            out.append("@@DUE prep " + " ".join(bad))
        ssa = st.get("skill_state_at")
        if isinstance(ssa, (int, float)):
            if now_t - ssa > 300:
                out.append(f"@@DUE state age={int(now_t - ssa)}s")
        elif started_ts is not None and now_t - started_ts > 120:
            out.append("@@DUE state missing")
    for k, v in sorted((st.get("pending_acks") or {}).items()):
        try:
            if poll_no - int(v.get("poll")) >= 2:
                out.append(f"@@DUE ack {k}")
        except Exception:  # noqa: BLE001
            pass
    if stopped_here and not has_wrapup:
        out.append("@@DUE wrapup")
    return out


def merge_state(st, upd):
    """Merge keys into the state; offsets never move back (two writers may race)."""
    for k, v in upd.items():
        if k in OFFSET_KEYS and isinstance(v, (int, float)) and isinstance(st.get(k), (int, float)):
            st[k] = max(st[k], v)
        else:
            st[k] = v
    return st


@contextmanager
def state_lock(base):
    """flock on <stem>.state.lock: read_delta and `lt state` both read-modify-write the state."""
    fd = None
    try:
        fd = os.open(base + ".state.lock", os.O_CREAT | os.O_RDWR, 0o644)
        if fcntl:
            fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError:
        pass   # a file system without locks: go on unlocked rather than lose the poll
    try:
        yield
    finally:
        if fd is not None:
            try:
                if fcntl:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
            except OSError:
                pass


def read_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        return st if isinstance(st, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def write_state(path, st):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def update_state(base, fn):
    """Locked read-modify-write of <base>.state.json; fn(st) mutates st. Returns st."""
    path = base + ".state.json"
    with state_lock(base):
        st = read_state(path)
        fn(st)
        try:
            write_state(path, st)
        except OSError:
            pass
    return st


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("offset", help="byte offset, or auto (from <stem>.state.json)")
    ap.add_argument("--wait", type=float, default=20)
    ap.add_argument("--settle", type=float, default=2)
    ap.add_argument("--status")
    ap.add_argument("--tips")
    ap.add_argument("--emit-stdin", action="store_true")
    ap.add_argument("--inbox")
    ap.add_argument("--inbox-offset", default=None, help="byte offset, or auto")
    ap.add_argument("--me-label", default="Я")
    ap.add_argument("--late-after", type=float, default=6,
                    help="mark a tip/answer late when the PM already spoke 4+ words after its src and it is this many s old")
    a = ap.parse_args()
    T0 = time.time()
    base = a.file[:-3] if a.file.endswith(".md") else a.file
    tips_path = a.tips or base + ".tips.jsonl"

    st0 = read_state(base + ".state.json")
    if str(a.offset).lower() == "auto":
        offset = int(st0.get("offset") or 0)
        inbox_auto = a.inbox_offset is None
    else:
        try:
            offset = int(a.offset)
        except ValueError:
            ap.error("OFFSET must be a number or auto")
        inbox_auto = False
    if a.inbox_offset is not None and str(a.inbox_offset).lower() == "auto":
        inbox_auto = True
    if inbox_auto:
        inbox_offset = int(st0.get("inbox_offset") or 0)
    else:
        try:
            inbox_offset = int(a.inbox_offset or 0)
        except ValueError:
            ap.error("--inbox-offset must be a number or auto")

    def load_status():
        if not a.status:
            return None
        try:
            with open(a.status, encoding="utf-8") as f:
                s = json.load(f)
            return s if isinstance(s, dict) else None
        except Exception:  # noqa: BLE001
            return None

    def mac_tz():
        from datetime import datetime, timezone
        try:
            started = (load_status() or {}).get("started_at")
            return datetime.fromisoformat(started).tzinfo or timezone.utc
        except Exception:  # noqa: BLE001
            return None

    def mac_now_at(ts=None):
        """HH:MM:SS on the Mac clock. This script may run in a VM on UTC, so take the Mac's UTC
        offset from status.json `started_at` (e.g. 2026-10-14T12:28:27+03:00)."""
        from datetime import datetime
        return datetime.fromtimestamp(time.time() if ts is None else ts, mac_tz()).strftime("%H:%M:%S")

    def pm_spoke_after(src_s):
        """The first PM line (4+ words) after `src` as (time, text), or None: the PM had
        already started answering when the tip landed."""
        try:
            with open(a.file, encoding="utf-8") as f:
                for line in f:
                    m = re.match(r"\[(\d\d:\d\d:\d\d)\] (.+?) \(\w+\): (.*)", line)
                    if not m or m.group(2) != a.me_label:
                        continue
                    t = _sec(m.group(1))
                    if t is not None and t > src_s and len(m.group(3).split()) >= 4:
                        return (m.group(1), m.group(3).strip()[:160])
        except OSError:
            pass
        return None

    # ---- 1. emit the skill's lines
    emitted = 0
    state_upd, acks = {}, set()
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
                if obj.get("kind") == "state":       # the skill's own state, not a tip
                    state_upd.update({k: v for k, v in obj.items() if k != "kind"})
                    continue
                if obj.get("kind") == "ack" and obj.get("key"):
                    acks.add(str(obj.get("key")))
                obj.setdefault("at", mac_now_at())   # when the tip landed (latency stats)
                src_s, at_s = _sec(obj.get("src")), _sec(obj.get("at"))
                if (obj.get("kind") in ("tip", "answer") and obj.get("level") != "info"
                        and src_s is not None and at_s is not None and (at_s - src_s) % 86400 >= a.late_after
                        and not str(obj.get("q", ""))):
                    pm = pm_spoke_after(src_s)
                    if pm:
                        late_by = int((at_s - _sec(pm[0])) % 86400)
                        obj["late"] = True
                        obj["late_by_s"] = late_by
                        print(f"@@LATE {late_by}s: {str(obj.get('gist', ''))[:80]}")
                        try:   # raw material for the late-tip pattern analysis after the call
                            with open(base + ".late.jsonl", "a", encoding="utf-8") as lf:
                                lf.write(json.dumps({"gist": obj.get("gist"), "kind": obj.get("kind"),
                                                     "src": obj.get("src"), "at": obj.get("at"),
                                                     "pm_started": pm[0], "pm_line": pm[1],
                                                     "late_by_s": late_by, "id": obj.get("id")},
                                                    ensure_ascii=False) + "\n")
                        except OSError:
                            pass
                good.append(json.dumps(obj, ensure_ascii=False))
            except Exception as e:  # noqa: BLE001
                print(f"@@EMIT_ERROR {e}: {raw[:120]}")
        if good and a.tips:
            with open(a.tips, "a", encoding="utf-8") as f:
                f.write("\n".join(good) + "\n")
            emitted = len(good)
    if state_upd or acks:
        def _merge(st):
            merge_state(st, state_upd)
            if state_upd:
                st["skill_state_at"] = round(time.time())
            pend = st.get("pending_acks") if isinstance(st.get("pending_acks"), dict) else {}
            for k in acks:
                pend.pop(k, None)
            st["pending_acks"] = pend
        update_state(base, _merge)
        if state_upd:
            print("@@STATE_MERGED " + ",".join(sorted(state_upd)))

    # ---- 2. wait for news
    def size(path):
        try:
            return os.path.getsize(path) if path else 0
        except OSError:
            return 0

    seq_obs = {"seq": st0.get("status_seq"), "since": st0.get("status_seq_since") or time.time()}

    def observe(s):
        if s is None or "seq" not in s:
            return
        if s.get("seq") != seq_obs["seq"]:
            seq_obs["seq"], seq_obs["since"] = s.get("seq"), time.time()

    def is_stopped(s):
        return bool(s) and s.get("state") in ("stopped", "error")

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

    def read_complete(path, off):
        """New complete lines after off and the offset after the last newline."""
        if size(path) <= off:
            return "", off
        with open(path, "rb") as f:
            f.seek(off)
            chunk = f.read()
        cut = chunk.rfind(b"\n")
        if cut < 0:
            return "", off
        return chunk[:cut + 1].decode("utf-8", errors="replace"), off + cut + 1

    def file_news():
        return size(a.file) > offset

    def inbox_news():
        return bool(a.inbox) and size(a.inbox) > inbox_offset

    heartbeat()
    deadline = time.time() + a.wait
    s = load_status()
    observe(s)
    while not (file_news() or inbox_news()) and time.time() < deadline and not is_stopped(s):
        time.sleep(0.5)
        heartbeat()
        s = load_status()
        observe(s)
    if file_news():
        peek, _ = read_complete(a.file, offset)
        time.sleep(settle_for(peek, a.me_label, a.settle))
    # inbox only (a typed question, SOS): no settle, answer fast

    # ---- 3. print the delta
    text, new = read_complete(a.file, offset)
    speakers = load_speakers(base + ".speakers.json")
    print(name_lines(text, speakers, a.me_label), end="")
    inew = inbox_offset
    settings = []
    if a.inbox:
        itext, inew = read_complete(a.inbox, inbox_offset)
        for line in itext.splitlines():
            try:
                q = json.loads(line)
                if not isinstance(q, dict):
                    raise ValueError("not an object")
                if q.get("kind") == "setting":
                    # A control in the tips window changed a setting for this call.
                    if q.get("key") == "hiring_role" and str(q.get("value") or "").strip().lower() == "candidate":
                        q["value"] = "coach"          # legacy role name (the PM is the one being asked)
                    print(f"@@SET {q.get('key')}={q.get('value')}")
                    settings.append((str(q.get("key")), q.get("value")))
                    if q.get("key") == "tip_feedback":   # kept for the after-call analysis
                        try:
                            with open(base + ".feedback.jsonl", "a", encoding="utf-8") as ff:
                                ff.write(json.dumps({"t": q.get("t"), "value": q.get("value")}, ensure_ascii=False) + "\n")
                        except OSError:
                            pass
                else:
                    txt = str(q.get("text", "")).strip()
                    low = re.sub(r"[\s_-]+", " ", txt.lower()).strip()
                    if low == "sos":
                        print(f"@@SOS [{q.get('t', '')}]")
                    elif low in ("off topic", "offtopic"):
                        print(f"@@OFFTOPIC [{q.get('t', '')}]")
                    else:
                        print(f"@@ASK [{q.get('t', '')}] {txt}")
            except Exception:  # noqa: BLE001
                if line.strip():
                    print(f"@@ASK [] {line.strip()}")
    print(f"@@OFFSET {new}")
    if a.inbox:
        print(f"@@INBOX_OFFSET {inew}")
    if a.emit_stdin:
        print(f"@@EMITTED {emitted}")

    # ---- 4. state, cards, mode, reminders
    status = load_status()
    observe(status)
    after = []

    def transcript_tail(nbytes=65536):
        try:
            with open(a.file, "rb") as f:
                f.seek(max(0, size(a.file) - nbytes))
                raw = f.read().decode("utf-8", errors="replace")
            return raw if size(a.file) <= nbytes else raw.split("\n", 1)[-1]
        except OSError:
            return ""

    def save_state(st):
        """Keep the mechanical part of <transcript>.state.json up to date on every poll, so the
        state survives even when the skill forgets to write it: offsets, poll count and the
        longest gap between two polls (loop stalls). The skill's own keys are kept as they are."""
        now = time.time()
        prev = st.get("last_poll_epoch")
        if isinstance(prev, (int, float)):
            gap = round(T0 - prev)   # time between the previous poll's end and this poll's start
            st["max_gap_s"] = max(int(st.get("max_gap_s") or 0), gap)
            if gap > 60:
                st["stalls_over_60s"] = int(st.get("stalls_over_60s") or 0) + 1
        # Per-poll timing log: `think_gap_s` = Claude's thinking + tool overhead for the previous batch.
        try:
            with open(base + ".polls.jsonl", "a", encoding="utf-8") as pf:
                pf.write(json.dumps({
                    "start": mac_now_at(T0), "end": mac_now_at(now),
                    "think_gap_s": round(T0 - prev, 1) if isinstance(prev, (int, float)) else None,
                    "waited_s": round(now - T0, 1), "new_bytes": new - offset,
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
        polls = int(st.get("polls") or 0) + 1
        merge_state(st, {"offset": new, "last_poll_epoch": now, "last_poll_at": mac_now_at(), "polls": polls})
        if a.inbox:
            merge_state(st, {"inbox_offset": inew})
        # Settings that need an ack tip from the skill.
        pend = st.get("pending_acks") if isinstance(st.get("pending_acks"), dict) else {}
        for k, v in settings:
            if k in ACK_KEYS:
                pend[k] = {"value": v, "poll": polls}
        st["pending_acks"] = pend
        # Recorder liveness by seq (status.json mtime is not trusted across machines).
        st["status_seq"], st["status_seq_since"] = seq_obs["seq"], seq_obs["since"]
        # Speaker mapping (v37): print it again whenever the recorder changed it.
        if speakers and isinstance(speakers.get("rev"), int) and speakers.get("rev") != st.get("speakers_rev_seen"):
            st["speakers_rev_seen"] = speakers["rev"]
            after.append(speakers_line(speakers))
        # Live mode (auto call type only).
        if status and status.get("state") == "recording" and status.get("call_type") in AUTO_CALL_TYPES:
            mode, pct = detect_mode(parse_lines(transcript_tail()), a.me_label, st.get("mode"))
            if mode and mode != st.get("mode"):
                st["mode"] = mode
                after.append(f"@@MODE {mode} talk_me={pct}")
        return st

    st = update_state(base, save_state)

    # ---- 5. status line and reminders
    def status_line(s):
        if not a.status:
            return "@@STATUS unknown"
        if s is None:
            return "@@STATUS unreadable"
        rest = (f"lines={s.get('lines')} queue={s.get('queue')} "
                f"mic={s.get('mic')} system={s.get('system_audio')} errors={len(s.get('errors') or [])}"
                + (f" err={str(s['errors'][0])[:80]}" if s.get("errors") else "")
                + (f" talk_me={s['talk_me_pct']}%" if s.get("talk_me_pct") is not None else "")
                + (f" mono={s['monologue_s']}s" if s.get("monologue_s") else "")
                + (f" asr_lag={s['asr_lag_s']}s" if s.get("asr_lag_s") is not None else "")
                + (" mic_auto_switched" if s.get("mic_auto_switched") else "")
                + (f" semantic={s['semantic']}" if s.get("semantic") else ""))
        if s.get("state") == "recording":
            if "seq" in s:
                age = time.time() - float(seq_obs["since"] or time.time())
                stale = age > 6
            else:
                try:
                    age = time.time() - os.path.getmtime(a.status)
                except OSError:
                    age = 0
                stale = age > 15
            if stale:
                return f"@@STATUS stale state=recording no_update_s={int(age)} " + rest
        return f"@@STATUS {s.get('state')} " + rest

    print(f"@@NOW {mac_now_at()}")
    print(status_line(status))
    for x in after:
        print(x)
    if status:
        recording = status.get("state") == "recording"
        started_ts = None
        try:
            from datetime import datetime
            started_ts = datetime.fromisoformat(status.get("started_at")).timestamp()
        except Exception:  # noqa: BLE001
            pass
        same_file = os.path.basename(str(status.get("file") or "")) == os.path.basename(a.file)
        prep = {"cards": prep_file_state(base + ".cards.json", "cards"),
                "facts": prep_file_state(base + ".facts.json", "facts")} if recording else {}
        has_wrapup = False
        if same_file and status.get("state") == "stopped":
            try:
                with open(tips_path, encoding="utf-8") as f:
                    for ln in f:
                        if '"wrapup"' in ln:
                            try:
                                if json.loads(ln).get("kind") == "wrapup":
                                    has_wrapup = True
                                    break
                            except Exception:  # noqa: BLE001
                                pass
            except OSError:
                pass
        for x in compute_due(time.time(), recording and same_file, started_ts, st, prep,
                             same_file and status.get("state") == "stopped", has_wrapup, int(st.get("polls") or 0)):
            print(x)


if __name__ == "__main__":
    main()
