"""Pacenote 0.12.3: one rule for the Decisions, Tasks and Risks of a call, read the same way the app reads them
(LiveTipsCore/CallLists.swift, research/pacenote-call-lists-audit-2026-11-15.md). The automatic Notion adds
(decision_notion, risk_notion --from-call) and the shared tools (pn_tools.call_facts) read here, so the engine never
sees a different list than the call page, the Summary and the server.

Each list comes from the first of:
 1. the PM's edit on the call page: the last situation with `source: call_page` that edited this list
    (`lists: ["decisions"]`; a line without `lists` edited them all); an edit that left the list empty counts;
 2. the Meeting notes of <stem>.notes.md (### Decisions, ### Action items, ### Risks);
 3. the live call picture: the last situation not written by the call page;
 4. the older notes sections (## Decisions, ## Action items).
Levels 2-4 count only with a real item: "nothing" lines are dropped everywhere. Tasks have no PM level here: the
PM edits tasks in the commitments register (L4).
"""
import json
import re
from pathlib import Path
from typing import Dict, List, Optional

NOTHING_EXACT = {"немає", "нема", "нічого", "відсутні", "відсутнє", "-", "n/a", "na", "none", "nothing", "no", "нет"}
NOTHING_PREFIX = ("жодних ", "жодного ", "жодної ", "рішень не ", "задач не ", "завдань не ", "немає рішень", "немає задач",
                  "немає завдань", "no decisions", "no action items", "no tasks", "none were ", "nothing was ")
OWNER_RX = (re.compile(r"^\*\*([^*]{1,60})\*\*\s*:\s*"), re.compile(r"^\*\*([^*]{1,60}):\*\*\s*"))
DUE_RX = re.compile(r"\s*\((due|до|термін|deadline)\s*:?\s*([^)]*)\)\s*\.?$", re.I)


def is_nothing(s: str) -> bool:
    """MeetingNotes.isNothing: an empty or "None" line."""
    l = (s or "").replace("*", "").strip().lower()
    while l and l[-1] in ".!:;-–":
        l = l[:-1]
    l = l.strip()
    if not l:
        return True
    if len(l) > 80:
        return False
    return l in NOTHING_EXACT or l.startswith(NOTHING_PREFIX)


def plain(s) -> str:
    return str(s or "").replace("**", "").replace(chr(0x2014), "-").strip()


def clean(a) -> List[str]:
    seen, out = set(), []
    for s in a:
        p = plain(s)
        if not p or is_nothing(p) or p.lower() in seen:
            continue
        seen.add(p.lower())
        out.append(p)
    return out


def clean_items(a: List[dict]) -> List[dict]:
    seen, out = set(), []
    for i in a:
        p = plain(i.get("text"))
        if not p or is_nothing(p) or p.lower() in seen:
            continue
        seen.add(p.lower())
        out.append({"t": i.get("t", ""), "text": p})
    return out


def _strings(v) -> List[str]:
    return [x for x in (v or []) if isinstance(x, str)] if isinstance(v, list) else []


def _whats(v) -> List[str]:
    out = []
    for x in (v if isinstance(v, list) else []):
        w = x.get("what") if isinstance(x, dict) else x
        if isinstance(w, str):
            out.append(w)
    return out


def task(raw: str, t: str = "") -> Optional[dict]:
    """A notes task line, "**Owner**: what (due: when)", "Owner: what" or just "what"."""
    s = (raw or "").replace(chr(0x2014), "-").strip()
    if not s or is_nothing(s):
        return None
    owner = ""
    for rx in OWNER_RX:
        m = rx.match(s)
        if m:
            owner = m.group(1).replace(":", "").strip()
            s = s[m.end():]
            break
    due = ""
    m = DUE_RX.search(s)
    if m:
        due = m.group(2).strip()
        s = s[:m.start()]
    text = plain(s)
    if not text or is_nothing(text):
        return None
    return {"owner": owner, "text": text, "due": due, "mine": None, "t": t}


def dedup(a: List[dict]) -> List[dict]:
    seen, out = set(), []
    for x in a:
        k = (x["owner"] + "|" + x["text"]).lower()
        if k not in seen:
            seen.add(k)
            out.append(x)
    return out


def live_tasks(o: dict) -> List[dict]:
    out = []
    for d in o.get("actions") or []:
        p = plain(d.get("what")) if isinstance(d, dict) and isinstance(d.get("what"), str) else ""
        if p and not is_nothing(p):
            out.append({"owner": "", "text": p, "due": d.get("due") or "", "mine": True, "t": d.get("t") or ""})
    for d in o.get("theirs") or []:
        p = plain(d.get("what")) if isinstance(d, dict) and isinstance(d.get("what"), str) else ""
        if p and not is_nothing(p):
            out.append({"owner": d.get("who") or "", "text": p, "due": d.get("due") or "", "mine": False, "t": d.get("t") or ""})
    return dedup(out)


def legacy(notes: str, names) -> List[str]:
    """Lines of the first older "## " section whose heading contains one of names (CallLists.legacy)."""
    cur, found, out = None, False, []
    for raw in notes.split("\n"):
        l = raw.strip()
        if l.startswith("## "):
            if found:
                break
            h = l[3:].lower()
            cur = h if any(n in h for n in names) else None
            found = cur is not None
            continue
        if cur is None or not l or l.startswith("#"):
            continue
        out.append(re.sub(r"^[-*•]\s+", "", l))
    return out


def task_line(t: dict) -> str:
    """"Mike: send the deck (due: Friday)", the same line as CallLists.Task.line."""
    return (t["owner"] + ": " if t["owner"] else "") + t["text"] + (" (due: " + t["due"] + ")" if t["due"] else "")


def resolve(situations: List[dict], notes: Optional[str]) -> Dict:
    """CallLists.resolve: `situations` every situation line of the call in file order, `notes` the notes text."""
    out = {"decisions": [], "decision_items": [], "tasks": [], "risks": [], "risk_items": [],
           "decisions_from": "none", "tasks_from": "none", "risks_from": "none"}
    edits = [s for s in situations if s.get("source") == "call_page"]
    live = next((s for s in reversed(situations) if s.get("source") != "call_page"), None)
    mn = None
    if notes is not None:
        from .callnotes import parse_meeting
        mn = parse_meeting(notes)

    def pm_edit(name):
        for e in reversed(edits):
            l = e.get("lists")
            if not isinstance(l, list) or name in l:
                return e
        return None

    e = pm_edit("decisions")
    if e is not None:
        out["decision_items"], out["decisions_from"] = [{"t": "", "text": x} for x in clean(_strings(e.get("decisions")))], "pm"
    elif mn and clean_items(mn["decisions"]):
        out["decision_items"], out["decisions_from"] = clean_items(mn["decisions"]), "notes"
    elif live is not None and clean(_strings(live.get("decisions"))):
        out["decision_items"], out["decisions_from"] = [{"t": "", "text": x} for x in clean(_strings(live.get("decisions")))], "live"
    elif notes is not None and clean(legacy(notes, ["decisions", "рішення"])):
        out["decision_items"], out["decisions_from"] = [{"t": "", "text": x} for x in clean(legacy(notes, ["decisions", "рішення"]))], "legacy"
    out["decisions"] = [i["text"] for i in out["decision_items"]]

    e = pm_edit("risks")
    if e is not None:
        out["risk_items"], out["risks_from"] = [{"t": "", "text": x} for x in clean(_whats(e.get("risks")))], "pm"
    elif mn and clean_items(mn.get("risks") or []):
        out["risk_items"], out["risks_from"] = clean_items(mn["risks"]), "notes"
    elif live is not None and clean(_whats(live.get("risks"))):
        out["risk_items"], out["risks_from"] = [{"t": "", "text": x} for x in clean(_whats(live.get("risks")))], "live"
    out["risks"] = [i["text"] for i in out["risk_items"]]

    nt = dedup([x for x in (task(i["text"], i.get("t", "")) for i in (mn["actions"] if mn else [])) if x])
    lt = live_tasks(live) if live is not None else []
    gt = dedup([x for x in (task(l) for l in legacy(notes, ["action items", "задачі", "завдання"])) if x]) if notes is not None else []
    for name, ts in (("notes", nt), ("live", lt), ("legacy", gt)):
        if ts:
            out["tasks"], out["tasks_from"] = ts, name
            break
    return out


# ---------------------------------------------------------------- files
def _stem(md: Path) -> str:
    s = str(md)
    return s[:-3] if s.endswith(".md") else s


def tips_paths(md: Path) -> List[Path]:
    return [Path(str(md) + ".tips.jsonl"), Path(_stem(md) + ".tips.jsonl")]


def notes_path(md: Path) -> Path:
    return Path(_stem(md) + ".notes.md")


def situations(md: Path) -> List[dict]:
    """Every situation line of the first tips file that has one, in file order (CallLists.situations)."""
    for p in tips_paths(md):
        if not p.exists():
            continue
        found = []
        for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if "situation" not in ln:
                continue
            try:
                o = json.loads(ln)
            except ValueError:
                continue
            if isinstance(o, dict) and o.get("kind") == "situation":
                found.append(o)
        if found:
            return found
    return []


def read(md: Path, notes_file: Optional[Path] = None) -> Dict:
    """The call's lists. `notes_file` overrides <stem>.notes.md (pn_tools finds the notes of the app's .app.md copy)."""
    md = Path(md)
    nf = notes_file if notes_file is not None else notes_path(md)
    notes = nf.read_text(encoding="utf-8", errors="replace") if nf and nf.exists() else None
    return resolve(situations(md), notes)
