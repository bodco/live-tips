"""Live mode of the spike: runs next to the skill on a real call (comparison mode).

Tails the transcript that live-transcriber writes (<stem>.md and <stem>.md.timing.jsonl) and
feeds each new line to the engine as soon as it appears. Writes only <stem>.app.* files into
--out (a private folder by default, never the skill's files). Stops when the recorder reports
`stopped`, the file is idle for --idle-min minutes, or on Ctrl+C.

  python -m livetips_m0.live --config cfg.json --md <project>/live/<stem>.md --out runs/live-<stem> \
      [--status <tool_root>/state/status.json]
"""
import argparse
import datetime as dt
import json
import time
from pathlib import Path

from .replay import build_engine
from .transcript import hms_to_s, parse_line


def now_sod() -> float:
    n = dt.datetime.now()
    return n.hour * 3600 + n.minute * 60 + n.second + n.microsecond / 1e6


class Tail:
    """Reads complete new lines from a growing file."""

    def __init__(self, path: Path):
        self.path = path
        self.pos = 0
        self.buf = ""

    def read(self):
        if not self.path.exists():
            return []
        size = self.path.stat().st_size
        if size < self.pos:              # truncated or replaced
            self.pos = 0
            self.buf = ""
        if size == self.pos:
            return []
        with self.path.open("r", encoding="utf-8", errors="replace") as f:
            f.seek(self.pos)
            data = f.read()
            self.pos = f.tell()
        self.buf += data
        *lines, self.buf = self.buf.split("\n")
        return lines


ACK_KEYS = {"call_type", "hiring_role", "audience", "comment_rate_seconds", "proactive", "ui_lang", "tips_paused"}


def handle_inbox(eng, raw: str) -> None:
    """Questions, HELP NOW and settings from the tips window (the skill gets the same via read_delta)."""
    try:
        d = json.loads(raw)
    except ValueError:
        return
    if d.get("kind") == "setting":
        key, value = d.get("key"), d.get("value")
        if key == "tips_paused":
            eng.paused = str(value).lower() in ("on", "true", "1")
        if key in ACK_KEYS:
            eng.out_tips.write({"kind": "ack", "key": key, "value": value, "t": time.strftime("%H:%M:%S")})
        return
    text = (d.get("text") or "").strip()
    if not text:
        return
    low = text.lower()
    if low == "sos":
        eng.on_request("sos")
    elif low in ("off topic", "refresh context"):
        return
    else:
        eng.on_request("ask", text)


def run(cfg, md: Path, out: Path, status: Path = None, idle_min: float = 6.0, poll_s: float = 0.15,
        from_start: bool = False, provider=None, max_s: float = None, inbox: Path = None, state_dir: Path = None):
    out.mkdir(parents=True, exist_ok=True)
    eng, stem = build_engine(cfg, md, out, now_sod, provider)
    (out / (stem + ".app.run.json")).write_text(json.dumps({
        "md": md.name, "mode": "live", "variant": cfg.get("variant"), "models": cfg["models"],
        "cache_ttl": cfg.get("cache_ttl"), "started": time.strftime("%Y-%m-%d %H:%M:%S")}, ensure_ascii=False, indent=1))
    t_md, t_tm = Tail(md), Tail(Path(str(md) + ".timing.jsonl"))
    t_in = Tail(inbox) if inbox else None
    if t_in and t_in.path.exists():
        t_in.pos = t_in.path.stat().st_size      # only requests made after the engine attached
    last_touch = 0.0
    if not from_start:                   # join a running call: skip what is already there
        for t in (t_md, t_tm):
            if t.path.exists():
                t.pos = t.path.stat().st_size
    timing = {}
    pending = []
    n = 0
    last_new = time.monotonic()
    t0 = time.monotonic()
    first_written = last_written = None
    while True:
        for raw in t_tm.read():
            try:
                r = json.loads(raw)
                timing.setdefault((r.get("t"), r.get("ch")), []).append(r)
            except ValueError:
                pass
        for raw in t_md.read():
            ln = parse_line(raw, n, cfg["me_label"])
            if ln:
                n += 1
                pending.append((ln, time.monotonic()))
                last_new = time.monotonic()
        keep = []
        for ln, seen in pending:
            recs = timing.get((ln.t, ln.speaker))
            if recs or time.monotonic() - seen > 1.0:    # timing usually follows within ms; never wait > 1 s
                if recs:
                    rec = recs.pop(0)
                    ln.seg_end = hms_to_s(rec["seg_end"]) if rec.get("seg_end") else None
                    ln.written = hms_to_s(rec["written"]) if rec.get("written") else now_sod()
                else:
                    ln.written = now_sod()
                eng.on_line(ln)
                first_written = first_written or ln.written
                last_written = ln.written
            else:
                keep.append((ln, seen))
        pending = keep
        if t_in:
            for raw in t_in.read():
                handle_inbox(eng, raw)
        if state_dir and time.monotonic() - last_touch > 5:
            last_touch = time.monotonic()
            try:
                (state_dir / "listener").touch()      # the window shows "not listening" without it
                (state_dir / "llm.json").write_text(json.dumps({
                    "spent_usd": round(eng.budget.call_spent, 4) if eng.budget else 0, "tips": len(eng.tips),
                    "budget": eng.budget.state() if eng.budget else "ok", "updated": time.strftime("%H:%M:%S")}))
            except OSError:
                pass
        if status and status.exists():
            try:   # the meeting concept changed in the window's menu: the engine follows it
                st = json.loads(status.read_text())
                ch = {k: st.get(k) for k in ("call_type", "audience", "hiring_role") if st.get(k)}
                if ch and eng.set_meeting(ch):
                    print("meeting:", ch, flush=True)
            except (OSError, ValueError):
                pass
            try:
                if json.loads(status.read_text()).get("state") == "stopped" and time.monotonic() - last_new > 5:
                    break
            except ValueError:
                pass
        if idle_min and time.monotonic() - last_new > idle_min * 60:     # 0 = never (app mode)
            break
        if max_s and time.monotonic() - t0 > max_s:
            break
        time.sleep(poll_s)
    eng.drain(60)
    span = (last_written - first_written) if first_written and last_written else 0
    (out / (stem + ".app.summary.json")).write_text(json.dumps(
        {"lines": n, "call_span_s": round(span, 1), "tips": len(eng.tips),
         "spent_usd": round(eng.budget.call_spent, 4) if eng.budget else None}, indent=1))
    return eng


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--status", type=Path)
    ap.add_argument("--idle-min", type=float, default=6.0)
    ap.add_argument("--from-start", action="store_true")
    ap.add_argument("--tips-out", type=Path, help="write tips into this file (the recorder's tips file in app mode)")
    ap.add_argument("--inbox", type=Path)
    ap.add_argument("--state-dir", type=Path)
    a = ap.parse_args(argv)
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    if a.tips_out:
        cfg["tips_out"] = str(a.tips_out)
    run(cfg, a.md, a.out, a.status, a.idle_min, from_start=a.from_start, inbox=a.inbox, state_dir=a.state_dir)


if __name__ == "__main__":
    main()
