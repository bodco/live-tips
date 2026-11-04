"""Agenda as a contract (Pacenote 0.8, idea 02; rules/agenda.yaml): the items come from the brief's checklist."""
import json
import re
from pathlib import Path
from typing import List, Optional, Tuple

IDENTITY = re.compile(r"<!--\s*agenda:([a-zA-Z0-9_-]{1,80})\s*-->")

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
        t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", IDENTITY.sub("", m.group(2)))
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
    """todo / now / done / skip per item; the PM's state (manual, by index; skip only from the PM) wins, then done,
    then the model's now."""
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
    if st == "skip":
        return "пропущено" if uk else "skipped"
    if st == "now":
        return "піднято" if uk else "raised"
    return "не піднято" if uk else "not raised"


# Conservative legacy matching: no model call on the live path. Ambiguity stays open.
def identity_words(text: str) -> set:
    return set(re.findall(r"[\w-]+", text.casefold())) - {
        "the", "a", "an", "please", "discuss", "review", "confirm", "check",
        "and", "of", "for", "to", "is", "what", "status", "оновити", "перевірити"}


def scope_words(text: str) -> set:
    guards = {"not", "no", "before", "after", "today", "tomorrow", "yesterday",
              "не", "без", "до", "після", "сьогодні", "завтра", "вчора"}
    return {w for w in identity_words(text) if w in guards or any(c.isdigit() for c in w)}


def same_question(left: str, right: str) -> bool:
    a, b = identity_words(left), identity_words(right)
    # Legacy matching allows harmless wording/order changes, not a different owner or scope.
    return len(a & b) >= 3 and a == b and scope_words(left) == scope_words(right)


def reconcile(previous: list, texts: list) -> dict:
    """Unambiguous one-to-one legacy matches only; duplicate/split/merge candidates stay open."""
    candidates = [[i for i, old in enumerate(previous)
                   if old.get("full", old["text"]) == text or same_question(old.get("full", old["text"]), text)]
                  for text in texts]
    uses = [i for group in candidates for i in group]
    return {j: previous[group[0]] for j, group in enumerate(candidates)
            if len(group) == 1 and uses.count(group[0]) == 1}


def marked_ids(brief: str, texts: list) -> list:
    """IDs accompany checklist lines, never visible text. Duplicate IDs are not trusted."""
    pairs = []
    for line in brief.splitlines():
        parsed = full_items(line)
        marker = IDENTITY.search(line)
        if parsed:
            pairs.append((parsed[0][0], marker.group(1) if marker else ""))
    ids = [identity for _, identity in pairs]
    return [identity if identity and ids.count(identity) == 1 else "" for _, identity in pairs][:len(texts)]


def match_identities(previous: list, brief: str, full: list) -> dict:
    matches = reconcile(previous, [t for t, _ in full])
    by_id = {x["id"]: x for x in previous}
    for i, identity in enumerate(marked_ids(brief, full)):
        if identity in by_id and scope_words(by_id[identity].get("full", by_id[identity]["text"])) == scope_words(full[i][0]):
            matches[i] = by_id[identity]
    used = [x["id"] for x in matches.values()]
    return {i: x for i, x in matches.items() if used.count(x["id"]) == 1}


def assign_ids(matches: dict, count: int) -> list:
    import uuid
    return [matches[i]["id"] if i in matches else "q_" + uuid.uuid4().hex[:16] for i in range(count)]
