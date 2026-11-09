"""Pacenote's shared tools (0.9.6 Б2): the same read-only data for the call agent, the background searches and the
preparation (pn_mcp.py serves them to `claude -p --mcp-config`).

Each tool returns short, dated, de-duplicated text: one line per fact with its date and its source, newest first,
and a newer fact wins over an older one that says the same (the code decides, not the model). A missing source
gives "(no data)". Nothing here writes a file or talks to the network; `lt search` runs on the Mac.

Where the data lives (read, never guessed):
- earlier calls: <project>/live/<YYYY-MM-DD-HHMM-title>.md (the app's copy .app.md), their notes <stem>.notes.md
  (## Meeting notes, rules/notes.yaml schema 2, callnotes.parse_meeting) or, without notes, the last call picture
  (kind "situation" in <stem>.tips.jsonl, callinfo.last_item);
- promises: <project>/live/commitments.jsonl (commitments.load, events folded by id);
- active decisions: <project>/pacenote/decisions.md (the Notion register's snapshot, decision_notion.parse_snapshot);
- the project's state: <project>/_notion/current-state.md (the local Notion copy, front matter last_edited/mirrored).
"""
import re
from pathlib import Path
from typing import Iterable, List, Optional

from . import callinfo
from . import commitments as register

NO_DATA = "(no data)"
CALL_MD = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d{2})(\d{2})-.+\.md$")
NOT_TRANSCRIPT = (".notes.md", ".named.md", ".speakers.md")
DROPPED = re.compile(r"\b(superseded|cancell?ed|revoked|reversed)\b|скасова|замінен", re.I)
PER_KIND = 6


# ---------------------------------------------------------------- earlier calls
def call_files(root: Path) -> List[Path]:
    """The project's call transcripts, newest first, the app's and the skill's copy once."""
    live = Path(root) / "live"
    if not live.is_dir():
        return []
    files = [p for p in live.iterdir() if CALL_MD.match(p.name) and not p.name.endswith(NOT_TRANSCRIPT)]
    seen, out = set(), []
    for p in sorted(files, key=lambda x: x.name, reverse=True):
        key = p.name.replace(".app.md", ".md")
        if key not in seen:
            seen.add(key)
            out.append(p)
    return out


def call_when(md: Path) -> str:
    m = CALL_MD.match(md.name)
    return "{} {}:{}".format(m.group(1), m.group(2), m.group(3)) if m else ""


def notes_file(md: Path) -> Optional[Path]:
    """<stem>.notes.md as callnotes writes it, for the app's copy as well."""
    base = md.name[:-3]
    for name in (base + ".notes.md", base.replace(".app", "") + ".notes.md", base + ".app.notes.md"):
        p = md.with_name(name)
        if p.exists():
            return p
    return None


def _at(date: str, t: str) -> str:
    return (date + " " + t[:5]).strip() if t else date


def call_facts(md: Path) -> tuple:
    """(source, [(kind, time, text)]) of one call: the meeting notes, else the call picture, else transcript lines."""
    nf = notes_file(md)
    if nf is not None:
        from .callnotes import parse_meeting
        m = parse_meeting(nf.read_text(encoding="utf-8", errors="replace"))
        rows = [("decision", i["t"], i["text"]) for i in m["decisions"][:PER_KIND]]
        rows += [("promise", i["t"], i["text"].replace("**", "")) for i in m["actions"][:PER_KIND]]
        rows += [("open", i["t"], i["text"]) for i in m["open"][:PER_KIND]]
        if not rows and m["tldr"]:
            rows = [("summary", "", m["tldr"])]
        if rows:
            return "notes " + nf.name, rows
    sit = callinfo.last_item(md, "situation") or {}
    rows = [("decision", "", str(d)) for d in (sit.get("decisions") or [])[:PER_KIND]]
    rows += [("promise", "", "PM: " + a.get("what", "") + _due(a)) for a in (sit.get("actions") or [])[:PER_KIND]]
    rows += [("promise", "", a.get("who", "") + ": " + a.get("what", "") + _due(a)) for a in (sit.get("theirs") or [])[:PER_KIND]]
    rows += [("open", "", a.get("what", "")) for a in (sit.get("asks") or [])[:PER_KIND] if a.get("type") != "update"]
    if rows:
        return "call picture " + md.name, rows
    ls = callinfo.lines(md, 60000)
    pick = ls[:2] + ls[-4:] if len(ls) > 6 else ls
    return "transcript " + md.name, [("line", l["t"], "{}: {}".format(l["who"], l["text"][:240])) for l in pick]


def _due(a: dict) -> str:
    return " (due: {})".format(a["due"]) if a.get("due") else ""


def _seen(kind: str, text: str, kept: List[tuple]) -> bool:
    return any(k == kind and register.similar(text, t, 0.7) for k, t in kept)


def past_calls(root, n: int = 3, query: str = "", lt=None) -> str:
    """The last n calls of the project: date, decisions, open questions, who promised what. Newest first; an item an
    earlier call repeats is shown once, at its newest date. With a query, the matching transcript passages follow
    (the project index, then plain word matches: memory.gather)."""
    root = Path(root) if root else None
    if root is None or not root.is_dir():
        return NO_DATA
    out, kept = [], []
    for md in call_files(root)[:max(1, min(int(n or 3), 8))]:
        src, rows = call_facts(md)
        date = md.name[:10]
        head = "CALL {} \"{}\" (source: {})".format(call_when(md), callinfo.header(md)["title"], src)
        lines = []
        for kind, t, text in rows:
            text = re.sub(r"\s+", " ", str(text or "")).strip()
            if not text or (kind != "line" and _seen(kind, text, kept)):
                continue
            kept.append((kind, text))
            lines.append("- {} | {} | {}".format(_at(date, t), kind, text[:300]))
        out.append("\n".join([head] + (lines or ["- (nothing new)"])))
    if query.strip():
        from . import memory
        ps = memory.gather(root, query, lt if isinstance(lt, list) else None)
        if ps:
            out.append("PASSAGES MATCHING \"{}\":\n".format(query.strip()[:80]) + "\n\n".join(
                "CALL {} ({}), {}:\n{}".format(p["file"].name[:10], p["file"].name[11:-3], p.get("t", ""), p["text"])
                for p in ps))
    return "\n\n".join(out) if out else NO_DATA


# ---------------------------------------------------------------- promises
def commitments(root, open_only: bool = True, limit: int = 15) -> str:
    """The commitments register: date | status | owner | text | due | the call it came from. Newest first."""
    if not root:
        return NO_DATA
    p = register.path_for(Path(root) / "live")
    if not p.exists():
        return NO_DATA
    items = [i for i in register.load(p.parent) if i["status"] == "open" or not open_only]
    if not items:
        return "(no open promises)" if open_only else NO_DATA
    items.sort(key=lambda i: str(i.get("created") or ""), reverse=True)
    rows = []
    for i in items[:limit]:
        status = i["status"] + (" " + str(i.get("done_at") or "")[:10] if i["status"] == "done" else "")
        rows.append("- {} | {} | {} | {} | due {} | {}".format(
            str(i.get("created") or "")[:10], status.strip(), i.get("owner") or "me", i.get("text", ""),
            i.get("due") or "-", "call " + i["call"] if i.get("call") else "register"))
    more = len(items) - len(rows)
    head = "Promises ({}; source: live/commitments.jsonl; owner \"me\" = the PM)".format("open" if open_only else "all")
    return "\n".join([head] + rows + (["({} older not shown)".format(more)] if more > 0 else []))


# ---------------------------------------------------------------- decisions
def _snapshot_taken(text: str) -> str:
    m = re.search(r"taken\s+(\d{4}-\d{2}-\d{2}[T ]?[\d:]*)", text or "")
    return m.group(1).strip() if m else ""


def decisions(root, area: Optional[str] = None, calls: int = 3, limit: int = 15) -> str:
    """Active decisions: the Notion register's snapshot, plus the ones taken on the calls after it (newer wins: an
    older decision that says the same is dropped). Cancelled or superseded lines are left out."""
    if not root:
        return NO_DATA
    root = Path(root)
    from .decision_notion import parse_snapshot
    snap = root / "pacenote" / "decisions.md"
    text = snap.read_text(encoding="utf-8", errors="replace") if snap.exists() else ""
    taken = _snapshot_taken(text)
    rows = [dict(d, src="register") for d in parse_snapshot(text)]
    for md in call_files(root)[:calls]:
        if taken and md.name[:10] < taken[:10]:
            continue
        src, facts = call_facts(md)
        rows += [{"date": _at(md.name[:10], t), "title": x, "stated_by": "", "area": "", "src": src}
                 for k, t, x in facts if k == "decision"]
    a = (area or "").strip().lower()
    rows = [d for d in rows if d.get("title") and not DROPPED.search(d["title"])
            and (not a or a in (d.get("area") or "").lower() or a in d["title"].lower())]
    rows.sort(key=lambda d: str(d.get("date") or ""), reverse=True)
    out, kept = [], []
    for d in rows:
        if any(register.similar(d["title"], k, 0.7) for k in kept):
            continue
        kept.append(d["title"])
        out.append("- {} | {} | {} | {} | {}".format(d.get("date") or "-", d["title"], d.get("stated_by") or "-",
                                                     d.get("area") or "-", d["src"]))
    if not out:
        return NO_DATA
    head = "Active decisions (register snapshot {}; source: pacenote/decisions.md and the later calls)".format(
        "taken " + taken if taken else "with no date" if text else "missing")
    return "\n".join([head] + out[:limit])


# ---------------------------------------------------------------- the project's state
def front_matter(text: str) -> tuple:
    """({key: value} of the mirror's front matter, the body)."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    meta = {}
    for ln in text[3:end].splitlines():
        m = re.match(r"^([a-z_]+):\s*(.*)$", ln)
        if m:
            meta[m.group(1)] = m.group(2).strip().strip('"')
    return meta, text[end + 4:].lstrip("\n")


def project_state(root, limit: int = 4000) -> str:
    """The project's Current State page from the local Notion copy, with how fresh it is."""
    if not root:
        return NO_DATA
    p = Path(root) / "_notion" / "current-state.md"
    if not p.exists():
        return NO_DATA
    meta, body = front_matter(p.read_text(encoding="utf-8", errors="replace"))
    fresh = meta.get("last_edited") or ""
    if not fresh:
        import datetime as dt
        fresh = dt.datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M") + " (file time)"
    head = "Project current state (source: _notion/current-state.md, edited in Notion {}{})".format(
        fresh[:16].replace("T", " "), ", copied " + meta["mirrored"][:10] if meta.get("mirrored") else "")
    body = body.strip()
    return head + "\n" + (body[:limit] + ("\n[... cut]" if len(body) > limit else "") if body else NO_DATA)


# ---------------------------------------------------------------- the folders and the live call
def search(roots: Iterable[str], query: str, lt, k: int = 8, budget: int = 12000) -> str:
    """The project index (lt search) over the project folder and the added folders: passages with file and date."""
    roots = [r for r in roots if r]
    if not query.strip() or not roots:
        return ""
    if not lt:
        return "(the folder index is not available: use Grep and Read)"
    from .context import index_snippets
    from .engine import Engine, fit_snippets, merge_hits, passages
    hits = merge_hits([index_snippets(lt, Path(r), query, k=k, timeout=15.0) for r in roots[:4]])
    return passages(fit_snippets(hits, budget, Engine._hit_text))


def transcript(history, query: str = "", last: int = 40) -> str:
    """The call so far: the lines with the query's words, or the last lines."""
    hist = list(history or [])
    if query.strip():
        terms = [w.lower() for w in re.findall(r"[^\W_]{3,}", query, re.U)]
        hist = [h for h in hist if any(t in (h.text or "").lower() for t in terms)]
    return "\n".join("[{}] {}: {}".format(h.t, h.label or h.speaker, h.text) for h in hist[-max(1, min(last, 200)):])


# ---------------------------------------------------------------- the tool list (the agent and pn_mcp)
def _obj(**props) -> dict:
    return {"type": "object", "properties": props, "additionalProperties": False}


S = {"type": "string"}
TOOLS = [
    # name, live call only, description, JSON schema (every argument optional)
    ("search_folders", False, "Search the project folder and the added folders (notes, specs, the local Notion copy, "
     "exports, earlier call transcripts). Returns passages with file names and dates.", _obj(query=S)),
    ("call_transcript", True, "The call so far: lines matching the words in `query`, or the last `last` lines "
     "when query is empty.", _obj(query=S, last={"type": "integer"})),
    ("brief", True, "The PM's preparation for this call: the brief, the fact book and the cards.", _obj()),
    ("past_calls", False, "The last calls of this project (date, decisions, open questions, who promised what, "
     "newest first) and the passages of earlier calls that match `query`.", _obj(query=S)),
    ("commitments", False, "The project's promises register: open promises with owner, date, due date and the call "
     "they came from (all=true also lists done and dropped ones).", _obj(all={"type": "boolean"})),
    ("decisions", False, "The project's active decisions with date and who decided (the Notion register and the "
     "later calls; cancelled ones left out). `area` narrows them.", _obj(area=S)),
    ("project_state", False, "The project's current state from the local Notion copy, with the date it was "
     "last edited.", _obj()),
]
NAMES = [t[0] for t in TOOLS]


def tools(live: bool = True) -> List[tuple]:
    """The tools for a live call (all of them) or for a preparation (no call yet: no transcript, no brief)."""
    return [t for t in TOOLS if live or not t[1]]


def call(ctx, name: str, args: dict) -> str:
    """Runs one tool on a context (engine.AgentContext during a call, FolderContext otherwise)."""
    args = args or {}
    q = str(args.get("query") or "")
    if name == "search_folders":
        return ctx.search(q)
    if name == "call_transcript":
        return ctx.transcript(q, int(args.get("last") or 40))
    if name == "brief":
        return ctx.brief()
    if name == "past_calls":
        return ctx.past_calls(q)
    if name == "commitments":
        return ctx.commitments(not bool(args.get("all")))
    if name == "decisions":
        return ctx.decisions(str(args.get("area") or "") or None)
    if name == "project_state":
        return ctx.project_state()
    raise KeyError(name)


class FolderContext:
    """The tools without a live call (the preparation, pn_mcp): the project folder, the added folders, lt search."""

    def __init__(self, root: Optional[str], extra_dirs: Iterable[str] = (), lt=None):
        self.root = root or ""
        self.extra = [d for d in extra_dirs or [] if d]
        self.lt = lt

    def roots(self) -> List[str]:
        out = []
        for d in [self.root] + self.extra:
            if d and d not in out and Path(d).is_dir():
                out.append(d)
        return out

    def search(self, query: str) -> str:
        return search(self.roots(), query, self.lt)

    def transcript(self, query: str = "", last: int = 40) -> str:
        return "(no live call)"

    def brief(self) -> str:
        return "(no brief yet)"

    def past_calls(self, query: str = "") -> str:
        return past_calls(self.root, 3, query, self.lt)

    def commitments(self, open_only: bool = True) -> str:
        return commitments(self.root, open_only)

    def decisions(self, area: Optional[str] = None) -> str:
        return decisions(self.root, area)

    def project_state(self) -> str:
        return project_state(self.root)
