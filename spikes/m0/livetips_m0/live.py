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

from .commitments import norm_text
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


ACK_KEYS = {"call_type", "hiring_role", "audience", "comment_rate_seconds", "proactive", "ui_lang", "tips_paused", "tips_lang", "tips"}


def _on(value) -> bool:
    return str(value).lower() in ("on", "true", "1")


def _paused(eng, value) -> None:
    eng.paused = _on(value)


def _proactive(eng, value) -> None:
    eng.proactive = _on(value)        # 2026-10-27: the window switch now really changes the engine
    eng.cfg["proactive"] = eng.proactive


def _set_meeting(eng, change: dict) -> None:
    try:
        eng.prompt.set_meeting(change)
    except Exception:  # noqa: BLE001
        pass


def _title(eng, value) -> None:
    if str(value or "").strip():      # renamed during the call
        eng.cfg["title"] = str(value).strip()[:120]
        _set_meeting(eng, {"title": eng.cfg["title"]})


def _call_lang(eng, value) -> None:
    v = str(value or "")              # Pacenote 0.8: the call's languages changed in Call settings
    if v:
        _set_meeting(eng, {"langs": ["uk", "en"] if v == "mix" else [c for c in v.split("+") if c]})


def _onme(eng, value) -> None:
    text, _, st = str(value or "").rpartition("|")   # "<action text>|done" or "|open": a tick in the window's On me
    if text.strip():
        eng.onme_ticked[norm_text(text)] = st == "done"


def _onme_fix(eng, value) -> None:
    """0.8.5: "<line>|" = not on the PM; "<line>|<new text>" = reworded (the window's On me Edit / Not mine)."""
    text, _, new = str(value or "").partition("|")
    if text.strip():
        eng.onme_fixed[norm_text(text)] = new.strip()


def _onme_mine(eng, value) -> None:
    """0.8.6: "<raw text>|<id of the on-them item or empty>|<its text or empty>": "Mine" in the window."""
    raw, _, rest = str(value or "").partition("|")
    fid, _, ftext = rest.partition("|")
    eng.add_mine(raw, fid.strip(), ftext.strip())


def _deal_fix(eng, value) -> None:
    """0.8.7: "<criterion>|<unknown|partial|known>|<what>": the PM's click in the Deal tab."""
    k, _, rest = str(value or "").partition("|")
    st, _, what = rest.partition("|")
    if hasattr(eng, "sales_fix"):
        eng.sales_fix(k.strip(), st.strip(), what.strip())


def _tips_lang(eng, value) -> None:
    """0.8.5 (rules/meeting.yaml > tips_language): the window's language switch for tips and cards."""
    v = str(value or "").strip().lower()
    if v in ("uk", "en"):
        eng.cfg["tips_lang"] = v
        if getattr(eng, "prompt", None) is not None and hasattr(eng.prompt, "fmt"):
            eng.prompt.fmt["tips_lang"] = v


def _tips(eng, value) -> None:
    eng.tips_set = str(value).lower() not in ("off", "false", "0", "no")   # 0.8.5: the Tips switch in Call settings


def _call_type(eng, value) -> None:
    if (str(value or "").lower() == "transcript") != (eng.meta().get("call_type") == "transcript"):
        eng.tips_set = str(value or "").lower() != "transcript"          # the type switches tips, as in the recorder


SETTINGS = {
    "tips": _tips,
    "call_type": _call_type,
    "tips_paused": _paused,
    "proactive": _proactive,
    "title": _title,
    "call_lang": _call_lang,
    "agenda_state": lambda eng, v: eng.set_agenda_state(str(v or "")),        # an agenda item's state set in the window
    "onme_state": _onme,
    "onme_fix": _onme_fix,
    "onme_mine": _onme_mine,
    "deal_fix": _deal_fix,
    "tips_lang": _tips_lang,
    "commitment_closed": lambda eng, v: eng.commitment_closed(str(v or "")),  # the app wrote the register
}


def handle_setting(eng, key, value) -> None:
    if key in SETTINGS:
        SETTINGS[key](eng, value)
    if key in ACK_KEYS:
        eng.out_tips.write({"kind": "ack", "key": key, "value": value, "t": time.strftime("%H:%M:%S")})


def handle_request(eng, text: str) -> None:
    low = text.lower()
    if low == "sos":
        eng.on_request("sos")
    elif low.startswith("find:"):
        if text[5:].strip():
            eng.on_request("find", text[5:].strip())
    elif low == "refresh context":
        eng.reload_prep()             # the window's Refresh or the app after a late preparation
    elif low != "off topic":
        eng.on_request("ask", text)


def handle_inbox(eng, raw: str) -> None:
    """Questions, HELP NOW and settings from the tips window (the skill gets the same via read_delta)."""
    try:
        d = json.loads(raw)
    except ValueError:
        return
    if d.get("kind") == "setting":
        handle_setting(eng, d.get("key"), d.get("value"))
        return
    text = (d.get("text") or "").strip()
    if text:
        handle_request(eng, text)


def wait_for(path: Path, limit_s: float = 3 * 3600, step: float = 0.5) -> None:
    """The app starts the engine while the recorder waits for the call (standby): the transcript file
    appears with the first line. 2026-10-23: the engine crashed here and was restarted by the app."""
    waited = 0.0
    while not path.exists() and waited < limit_s:
        time.sleep(step)
        waited += step


def skip_existing(*tails) -> None:
    for t in tails:
        if t and t.path.exists():
            t.pos = t.path.stat().st_size


class LiveRun:
    """One live call: the tails it reads, the lines waiting for their timing, what it has seen."""

    def __init__(self, cfg, eng, md: Path, inbox: Path = None, from_start: bool = False):
        self.cfg, self.eng = cfg, eng
        self.t_md, self.t_tm = Tail(md), Tail(Path(str(md) + ".timing.jsonl"))
        self.t_in = Tail(inbox) if inbox else None
        skip_existing(self.t_in)                     # only requests made after the engine attached
        if not from_start:                           # join a running call: skip what is already there
            skip_existing(self.t_md, self.t_tm)
        self.timing, self.pending, self.n = {}, [], 0
        self.last_new = self.t0 = time.monotonic()
        self.last_touch = 0.0
        self.first_written = self.last_written = None

    def step(self) -> None:
        self.read_timing()
        self.read_lines()
        self.feed_ready()
        if self.t_in:
            for raw in self.t_in.read():
                handle_inbox(self.eng, raw)

    def read_timing(self) -> None:
        for raw in self.t_tm.read():
            try:
                r = json.loads(raw)
                self.timing.setdefault((r.get("t"), r.get("ch")), []).append(r)
            except ValueError:
                pass

    def read_lines(self) -> None:
        for raw in self.t_md.read():
            ln = parse_line(raw, self.n, self.cfg["me_label"])
            if ln:
                self.n += 1
                self.pending.append((ln, time.monotonic()))
                self.last_new = time.monotonic()

    def feed_ready(self) -> None:
        keep = []
        for ln, seen in self.pending:
            recs = self.timing.get((ln.t, ln.speaker))
            if recs or time.monotonic() - seen > 1.0:    # timing usually follows within ms; never wait > 1 s
                self.feed(ln, recs.pop(0) if recs else None)
            else:
                keep.append((ln, seen))
        self.pending = keep

    def feed(self, ln, rec) -> None:
        if rec:
            ln.seg_end = hms_to_s(rec["seg_end"]) if rec.get("seg_end") else None
            ln.written = hms_to_s(rec["written"]) if rec.get("written") else now_sod()
        else:
            ln.written = now_sod()
        self.eng.on_line(ln)
        self.first_written = self.first_written or ln.written
        self.last_written = ln.written

    def touch_state(self, state_dir: Path) -> None:
        if not state_dir or time.monotonic() - self.last_touch <= 5:
            return
        self.last_touch = time.monotonic()
        eng = self.eng
        try:
            (state_dir / "listener").touch()      # the window shows "not listening" without it
            (state_dir / "llm.json").write_text(json.dumps({
                "spent_usd": round(eng.budget.call_spent, 4) if eng.budget else 0, "tips": len(eng.tips),
                "budget": eng.budget.state() if eng.budget else "ok", "updated": time.strftime("%H:%M:%S")}))
        except OSError:
            pass

    def follow_status(self, status: Path) -> bool:
        """The meeting concept changed in the window's menu: the engine follows it. True: the recorder stopped."""
        if not (status and status.exists()):
            return False
        try:
            st = json.loads(status.read_text())
            ch = {k: st.get(k) for k in ("call_type", "audience", "hiring_role") if st.get(k)}
            if ch and self.eng.set_meeting(ch):
                print("meeting:", ch, flush=True)
        except (OSError, ValueError):
            pass
        try:
            return json.loads(status.read_text()).get("state") == "stopped" and time.monotonic() - self.last_new > 5
        except ValueError:
            return False

    def timed_out(self, idle_min: float, max_s: float) -> bool:
        if idle_min and time.monotonic() - self.last_new > idle_min * 60:     # 0 = never (app mode)
            return True
        return bool(max_s and time.monotonic() - self.t0 > max_s)

    def summary(self) -> dict:
        span = (self.last_written - self.first_written) if self.first_written and self.last_written else 0
        eng = self.eng
        return {"lines": self.n, "call_span_s": round(span, 1), "tips": len(eng.tips),
                "spent_usd": round(eng.budget.call_spent, 4) if eng.budget else None}


def run(cfg, md: Path, out: Path, status: Path = None, idle_min: float = 6.0, poll_s: float = 0.15,
        from_start: bool = False, provider=None, max_s: float = None, inbox: Path = None, state_dir: Path = None):
    out.mkdir(parents=True, exist_ok=True)
    wait_for(md)
    if cfg.get("variant") == "app":           # Pacenote 0.8: the register next to the transcript
        cfg.setdefault("register_dir", str(md.parent))
    cfg.setdefault("call_md", str(md))         # 0.8.7: the Sales summary goes next to the transcript
    eng, stem = build_engine(cfg, md, out, now_sod, provider)
    (out / (stem + ".app.run.json")).write_text(json.dumps({
        "md": md.name, "mode": "live", "variant": cfg.get("variant"), "models": cfg["models"],
        "cache_ttl": cfg.get("cache_ttl"), "started": time.strftime("%Y-%m-%d %H:%M:%S")}, ensure_ascii=False, indent=1))
    lr = LiveRun(cfg, eng, md, inbox, from_start)
    while True:
        lr.step()
        lr.touch_state(state_dir)
        if lr.follow_status(status) or lr.timed_out(idle_min, max_s):
            break
        time.sleep(poll_s)
    eng.drain(60)
    try:
        eng.final_wrapup()
    except Exception as e:  # noqa: BLE001
        print("wrapup:", repr(e), flush=True)
    (out / (stem + ".app.summary.json")).write_text(json.dumps(lr.summary(), indent=1))
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
