"""0.10.0 (Meeting Sheet, fix 2026-11-12, owner): the Tracker as a source of every preparation.

The Tracker is the commitments register (commitments.jsonl in a project's live folder, rules/commitments.yaml). A
preparation reads the open items of the call's project; for a workspace call, of every project of the workspace
(the app sends them as tracker_folders) and of every folder added to the call. Items are split into "on me" (owner
empty or "me") and "waiting on others", with the due state (overdue, today, a date) as Home shows it
(LiveTipsCore/Commitments.swift: dueDate, sorted). Nothing leaves the Mac except the text given to the model.
"""
import datetime as _dt
import os
import re
from typing import Dict, List, Optional

from .. import commitments as CM

ON_ME_MAX = 25
WAITING_MAX = 25
_DAYS = [(0, ("monday", "понеділ")), (1, ("tuesday", "вівтор")), (2, ("wednesday", "серед")), (3, ("thursday", "четвер")),
         (4, ("friday", "п'ятниц", "пʼятниц", "пятниц")), (5, ("saturday", "субот")), (6, ("sunday", "неділ"))]


def due_date(text: str, base: _dt.date) -> Optional[_dt.date]:
    """CommitmentRegister.dueDate: 2026-11-14, 14.11, 11/14, today, tomorrow, a weekday (the next one from base)."""
    t = (text or "").strip().lower()
    if not t:
        return None
    m = re.search(r"\d{4}-\d\d-\d\d", t)
    if m:
        try:
            return _dt.date.fromisoformat(m.group(0))
        except ValueError:
            return None
    m = re.search(r"\b(\d{1,2})([./])(\d{1,2})(?:[./](\d{2,4}))?\b", t)
    if m:
        a, sep, b, y = int(m.group(1)), m.group(2), int(m.group(3)), m.group(4)
        day, month = (b, a) if sep == "/" else (a, b)
        year = (2000 + int(y) if int(y) < 100 else int(y)) if y else base.year
        try:
            d = _dt.date(year, month, day)
        except ValueError:
            return None
        if not y and d < base - _dt.timedelta(days=183):
            d = d.replace(year=d.year + 1)
        return d
    if "today" in t or "сьогодні" in t:
        return base
    if "tomorrow" in t or "завтра" in t:
        return base + _dt.timedelta(days=1)
    for wd, names in _DAYS:
        if any(n in t for n in names):
            return base + _dt.timedelta(days=(wd - base.weekday()) % 7)
    return None


def _day(s: str) -> Optional[_dt.date]:
    try:
        return _dt.date.fromisoformat(str(s)[:10]) if s else None
    except ValueError:
        return None


def _live_of(path: str) -> str:
    p = os.path.expanduser(path or "")
    return p if os.path.basename(p.rstrip("/")) == "live" else os.path.join(p, "live")


def folders(req: dict) -> List[str]:
    """The live folders whose register counts: the app's tracker_folders (project, or workspace and its projects),
    the call's own live folder and project root, and the live folder of every folder added to the call."""
    project = req.get("project") or {}
    cands = list(req.get("tracker_folders") or [])
    if req.get("live"):
        cands.append(req["live"])
    if project.get("root") or req.get("root"):
        cands.append(_live_of(project.get("root") or req.get("root")))
    for s in req.get("sources") or []:
        p = os.path.expanduser(s.get("path") or "")
        if p and os.path.isdir(p) and s.get("type") in ("folder", "folder_file", "file", None):
            cands.append(_live_of(p))
    for f in req.get("folders") or []:
        if os.path.isdir(os.path.expanduser(f)):
            cands.append(_live_of(f))
    out, seen = [], set()
    for c in cands:
        c = _live_of(c)
        rp = os.path.realpath(c)
        if rp in seen or not os.path.exists(os.path.join(c, CM.FILE)):
            continue
        seen.add(rp)
        out.append(c)
    return out


def collect(req: dict, today: Optional[_dt.date] = None) -> dict:
    """{on_me: [...], waiting: [...], folders: n}; each item {text, owner, project, due, due_date, state, created,
    series}; state overdue | today | dated | none. Sorted as Home: overdue, today, by date, the rest newest first."""
    today = today or (_dt.date.fromisoformat(req["today"]) if req.get("today") else _dt.date.today())
    fs = folders(req)
    seen, items = set(), []
    for f in fs:
        try:
            got = CM.load(f)
        except Exception:  # noqa: BLE001
            continue
        proj = os.path.basename(os.path.dirname(os.path.realpath(f))) or ""
        for i in got:
            if i.get("status") != "open" or not str(i.get("text") or "").strip():
                continue
            twin = (CM.norm_text(i.get("text", "")), (i.get("owner") or "me").lower())
            if i.get("id") in seen or twin in seen:
                continue                   # the same item in two registers (a folder added twice) once
            seen.update({i.get("id"), twin})
            created = _day(i.get("created")) or today
            d = due_date(str(i.get("due") or ""), created)
            state = "none" if not d else ("overdue" if d < today else "today" if d == today else "dated")
            items.append({"text": str(i["text"]).strip(), "owner": (i.get("owner") or "me").strip() or "me",
                          "project": proj, "due": str(i.get("due") or ""), "due_date": d.isoformat() if d else "",
                          "state": state, "created": str(i.get("created") or "")[:10], "series": i.get("series", "")})
    order = {"overdue": 0, "today": 1, "dated": 2, "none": 3}

    def key(x):
        return (order[x["state"]], x["due_date"] or "9999", "".join(chr(0x10FFFF - ord(c)) for c in x["created"]))
    mine = sorted([x for x in items if x["owner"].lower() == "me"], key=key)[:ON_ME_MAX]
    theirs = sorted([x for x in items if x["owner"].lower() != "me"], key=key)[:WAITING_MAX]
    return {"on_me": mine, "waiting": theirs, "folders": len(fs)}


def _due_note(x: dict) -> str:
    if x["state"] == "overdue":
        return f"OVERDUE since {x['due_date']}"
    if x["state"] == "today":
        return "due TODAY"
    if x["state"] == "dated":
        return f"due {x['due_date']}"
    return "no due date"


def text(tr: dict) -> str:
    """The source text the model reads (plain lines; the item texts as the PM's register holds them)."""
    lines = ["Pacenote Tracker: the PM's open commitments (on me) and what others owe the PM (waiting on others).",
             "", f"## On me ({len(tr['on_me'])} open)"]
    for x in tr["on_me"]:
        lines.append(f"- [{_due_note(x)}] {x['text']} (project {x['project']}; since {x['created'] or 'unknown'})")
    if not tr["on_me"]:
        lines.append("- (none)")
    lines += ["", f"## Waiting on others ({len(tr['waiting'])} open)"]
    for x in tr["waiting"]:
        lines.append(f"- {x['owner']}: {x['text']} [{_due_note(x)}] (project {x['project']}; since {x['created'] or 'unknown'})")
    if not tr["waiting"]:
        lines.append("- (none)")
    return "\n".join(lines)


def title(tr: dict) -> str:
    return f"Tracker: {len(tr['on_me'])} on me, {len(tr['waiting'])} waiting on others"


def for_sheet(tr: dict) -> dict:
    """The part the live window needs when the sheet's stand-up blocks are empty (recorder: sheet_standup)."""
    return {"on_me": [{"text": x["text"], "state": x["state"], "due": x["due_date"]} for x in tr["on_me"][:10]],
            "waiting": [{"who": x["owner"], "what": x["text"]} for x in tr["waiting"][:10]]}
