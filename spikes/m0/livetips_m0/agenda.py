"""Agenda as a contract (Pacenote 0.8, idea 02; rules/agenda.yaml): the items come from the brief's checklist."""
import json
import re
from pathlib import Path
from typing import List, Optional, Tuple

CHECK = re.compile(r"^\s*[-*]\s+\[( |x|X)\]\s+(.+?)\s*$")


# 2026-11-02 (owner, a client monthly review): "RAIL: walk the open items below" became an agenda item that pointed elsewhere.
POINTER = re.compile(r"\b(below|above)\b|\b(нижче|вище)\b", re.I | re.U)
OBTAIN = re.compile(r"(decisions? (and results )?to obtain|results? to get|рішення(?: і результати)?,? які треба отримати|треба отримати)\s*:?",
                    re.I | re.U)


def full_items(text: str, max_items: int = 20) -> List[Tuple[str, bool]]:
    """(full item text, already ticked) for each checklist line of the brief, in order; markdown and links
    removed; a line that only points to another part of the brief ("walk the open items below") is skipped."""
    out = []
    for ln in (text or "").splitlines():
        m = CHECK.match(ln)
        if not m:
            continue
        t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", m.group(2))
        t = re.sub(r"[*_`]+", "", t).strip()
        if not t or (POINTER.search(t) and len(t.split()) <= 8):
            continue
        out.append((t, m.group(1) != " "))
        if len(out) >= max_items:
            break
    return out


def shorten(t: str, max_chars: int = 60) -> str:
    return t if len(t) <= max_chars else t[: max_chars - 1].rstrip() + "…"


def from_brief(text: str, max_items: int = 20, max_chars: int = 60) -> List[Tuple[str, bool]]:
    """(item, already ticked) for each checklist line of the brief, in order; long items shortened for the strip
    (the full text is full_items, shown on a click and given to the model)."""
    return [(shorten(t, max_chars), d) for t, d in full_items(text, max_items)]


def to_obtain(text: str, max_chars: int = 700) -> str:
    """The brief's "Decisions to obtain" / "Рішення і результати, які треба отримати" text (one line or paragraph), or ""."""
    for ln in (text or "").splitlines():
        m = OBTAIN.search(ln)
        if m:
            rest = re.sub(r"[*_`]+", "", ln[m.end():]).strip(" :-")
            if rest:
                return rest[:max_chars]
    return ""


def states(items: List[Tuple[str, bool]], done: set, now: int, manual: dict) -> List[str]:
    """todo / now / done per item; the PM's state (manual, by index) wins, then done, then the model's now."""
    out = []
    for i, (_, ticked) in enumerate(items):
        s = "done" if (ticked or i in done) else ("now" if i == now else "todo")
        out.append(manual.get(i, s))
    if out.count("now") > 1:                      # at most one item is "now": the PM's choice, else the first
        keep = next((i for i, s in manual.items() if s == "now"), out.index("now"))
        out = [("todo" if (s == "now" and i != keep) else s) for i, s in enumerate(out)]
    return out


def last_from_tips(path: Path) -> Optional[List[dict]]:
    """The last agenda strip in a call's tips file: [{"text", "done", "cur", "state"?}]."""
    if not path or not Path(path).exists():
        return None
    last = None
    for ln in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if '"agenda"' not in ln:
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if o.get("kind") == "agenda" and isinstance(o.get("items"), list):
            last = o["items"]
    return last


def status_label(it: dict, uk: bool) -> str:
    st = it.get("state") or ("done" if it.get("done") else ("now" if it.get("cur") else "todo"))
    if st == "done":
        return "обговорено" if uk else "discussed"
    if st == "now":
        return "піднято" if uk else "raised"
    return "не піднято" if uk else "not raised"
