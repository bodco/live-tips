"""0.10.0 (Meeting Sheet, phase 2): the sources of a sheet, checked before any model runs, the same on every route.

- Links: Google Docs / Sheets / Slides / Drive files (the patterns of the app's GoogleLink), Notion, LinkedIn, web.
  A link written in the free-text context is never moved silently: it comes back as a "Move to Sources" suggestion.
- Access per source: access ok | denied | unsupported | pending, access_reason, fix_action (and fix_actions for
  LinkedIn). Google is read by the app through OAuth: the request carries the copies the app already fetched
  (google.copies) or a status hint (google.status: ok | denied | not_found); a Drive file nobody can open is
  "denied" with confirm_google (drive.file + Picker). Notion without a connection: connect_notion. LinkedIn: pending
  with save_as_pdf, open_in_browser, paste_text, fill_by_hand. A web page: ok, read when the sheet is built (the
  robots.txt check lives in the web module of phase 6: web_allowed() is the hook).
- Candidates from the project folder with a "why" (same contact, fresh, title match, previous sheet, newer version),
  the earlier calls of the series, the tracker (open commitments), the project state and the digest. Nothing is
  ticked unless the series says so (suggested: true).
"""
import datetime as _dt
import json
import os
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlparse

from . import readers
from . import size as Z

URL = re.compile(r"https?://[^\s<>\"')\]]+")
GOOGLE_KIND = {"doc": "gdoc", "sheet": "gsheet", "slides": "gslides", "file": "drive_file"}
LINKEDIN_PROFILE = re.compile(r"linkedin\.com/(in|pub)/", re.I)
LABEL = {"gdoc": "Google Doc", "gsheet": "Google Sheet", "gslides": "Google Slides", "drive_file": "Google Drive file",
         "notion": "Notion page", "linkedin": "LinkedIn profile", "web": "web page"}
LINKEDIN_FIXES = ["save_as_pdf", "open_in_browser", "paste_text", "fill_by_hand"]
TEXT_TYPES = ("text", "linkedin_manual", "transcript", "crm", "web_search")
FRESH_DAYS = 14


# ---------------------------------------------------------------- links

def google_link(u: str) -> Optional[Tuple[str, str]]:
    """GoogleLink.parse of LiveTipsCore/GoogleCore.swift: (kind, id) for docs.google.com and drive.google.com."""
    if not re.match(r"https://(docs|drive)\.google\.com/", u):
        return None
    for marker, kind in (("/document/d/", "doc"), ("/spreadsheets/d/", "sheet"), ("/presentation/d/", "slides"),
                         ("/file/d/", "file"), ("open?id=", "file")):
        i = u.find(marker)
        if i >= 0:
            m = re.match(r"[A-Za-z0-9_-]+", u[i + len(marker):])
            if m and len(m.group(0)) >= 10:
                return kind, m.group(0)
    return None


def classify(u: str) -> dict:
    """{url, type, id?, host} for one link."""
    u = u.strip().rstrip(".,;:")
    host = (urlparse(u).hostname or "").lower()
    g = google_link(u)
    if g:
        return {"url": u, "type": GOOGLE_KIND[g[0]], "id": g[1], "host": host}
    if host.endswith("notion.so") or host.endswith("notion.site"):
        m = re.search(r"([0-9a-f]{32})", u.replace("-", ""))
        return {"url": u, "type": "notion", "id": m.group(1) if m else "", "host": host}
    if host.endswith("linkedin.com"):
        return {"url": u, "type": "linkedin", "host": host}
    return {"url": u, "type": "web", "host": host}


def find_links(text: str) -> List[dict]:
    out, seen = [], set()
    for m in URL.finditer(text or ""):
        c = classify(m.group(0))
        key = c.get("id") or c["url"]
        if key not in seen:
            seen.add(key)
            out.append(c)
    return out


def move_suggestions(context: str, sources: List[dict]) -> List[dict]:
    """Links in the free-text context that are not sources yet: "This looks like a Google Doc. Move it to Sources?"
    The app moves one only when the user says so."""
    have = set()
    for s in sources:
        for k in ("uri", "url"):
            if s.get(k):
                have.add(s[k].rstrip("/"))
                g = google_link(s[k])
                if g:
                    have.add(g[1])
    out = []
    for c in find_links(context):
        if c["url"].rstrip("/") in have or (c.get("id") and c["id"] in have):
            continue
        out.append({"url": c["url"], "type": c["type"], "label": LABEL.get(c["type"], "link"),
                    "text": f"This looks like a {LABEL.get(c['type'], 'link')}. Move it to Sources, so its access is "
                            f"checked and it is read in full?", "action": "move_to_sources"})
    return out


def web_allowed(url: str) -> Optional[bool]:
    """0.10.0 hook: the browser module (phase 6, sheet/web.py) checks robots.txt. None = not checked here."""
    try:
        from . import web  # type: ignore
    except ImportError:
        return None
    fn = getattr(web, "robots_allowed", None)
    try:
        return fn(url) if fn else None
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------- one source

def _lookup(d: dict, s: dict) -> Optional[str]:
    """A per-link value of the request (google.copies, google.status, notion.copies) by url or Google id."""
    if not d:
        return None
    for k in (s.get("uri"), s.get("url"), s.get("gid")):
        if k and k in d:
            return d[k]
    g = google_link(s.get("uri") or "")
    if g and g[1] in d:
        return d[g[1]]
    return None


def _mtime(path: str) -> Optional[str]:
    """The source's date: the date in its name (a dated note or status), else the file's time (prepcontext.file_date)."""
    if not os.path.exists(path):
        return None
    from ..prepcontext import file_date
    return file_date(path).isoformat()


def check(s: dict, req: dict, texts: Dict[str, str], route: str, windows: dict) -> dict:
    """Fills access, access_reason, fix_action, chars, size_tokens, modified_at of one source (in place) and keeps
    its text in texts[id] for the build. Never raises: a source that cannot be read says why."""
    t = s.get("type") or "file"
    s.setdefault("used", "not_used")
    for k in ("access_reason", "fix_action", "fix_actions"):
        s.pop(k, None)
    text = ""
    g = req.get("google") or {}
    nt = req.get("notion") or {}
    try:
        if t in ("file", "folder_file", "prev_call", "project_state", "tracker", "digest", "crm", "transcript") and s.get("path"):
            r = readers.read(s["path"])
            text = r.get("text", "")
            s["modified_at"] = s.get("modified_at") or _mtime(os.path.expanduser(s["path"]))
            if r.get("slides"):
                s["slides"] = len(r["slides"])
            if r.get("pages"):
                s["pages"] = r["pages"]
            if r.get("error") and s.get("deck_json") and os.path.exists(os.path.expanduser(s["deck_json"])):
                # 0.10.0: a deck the app already read (Keynote, or a PDF without a text layer): its deck.json texts
                from ..prepcontext import deck_text
                text = deck_text(os.path.expanduser(s["deck_json"]))
                r = {"text": text} if text.strip() else r
            if r.get("error"):
                s["access"] = "unsupported" if r.get("unsupported") else "denied"
                s["access_reason"] = r["error"]
                s["fix_action"] = "retry" if r["error"] == "file not found" else "paste_text"
            else:
                s["access"] = "ok"
        elif t in TEXT_TYPES or (s.get("text") and t not in ("gdoc", "gsheet", "gslides", "drive_file", "notion", "linkedin")):
            text = s.get("text") or ""
            s["access"] = "ok" if text.strip() else "pending"
            if not text.strip():
                s["access_reason"] = "empty"
                s["fix_action"] = "paste_text" if t != "linkedin_manual" else "fill_by_hand"
        elif t in ("gdoc", "gsheet", "gslides", "drive_file"):
            copy = _lookup(g.get("copies") or {}, s)
            status = _lookup(g.get("status") or {}, s)
            if copy and os.path.exists(os.path.expanduser(copy)):
                r = readers.read(copy)
                text = r.get("text", "")
                s["copy"] = copy
                s["access"] = "ok" if text.strip() else "unsupported"
                if not text.strip():
                    s["access_reason"] = r.get("error") or "the file has no text"
                s["modified_at"] = s.get("modified_at") or _mtime(os.path.expanduser(copy))
            elif not g.get("connected"):
                s["access"] = "pending"
                s["access_reason"] = "Google is not connected"
                s["fix_action"] = "connect_google"
            elif status in ("denied", "not_found", "forbidden") or (t == "drive_file" and status != "ok"):
                s["access"] = "denied"
                s["access_reason"] = ("No access through the connected Google accounts" if status != "not_found"
                                      else "Not found through the connected Google accounts")
                s["fix_action"] = "confirm_google"
            else:
                s["access"] = "pending"
                s["access_reason"] = "read through Google when the sheet is built"
                s["fix_action"] = "retry"
        elif t == "notion":
            copy = _lookup(nt.get("copies") or {}, s)
            if copy and os.path.exists(os.path.expanduser(copy)):
                text = readers.read(copy).get("text", "")
                s["copy"] = copy
                s["access"] = "ok" if text.strip() else "unsupported"
            elif not nt.get("connected"):
                s["access"] = "pending"
                s["access_reason"] = "Notion is not connected"
                s["fix_action"] = "connect_notion"
            else:
                s["access"] = "pending"
                s["access_reason"] = "read through Notion when the sheet is built"
                s["fix_action"] = "retry"
        elif t == "linkedin":
            s["access"] = "pending"
            s["access_reason"] = ("LinkedIn is not read automatically: save the profile as PDF, open it in the "
                                  "Pacenote browser, paste its text or fill it in by hand")
            s["fix_action"] = LINKEDIN_FIXES[0]
            s["fix_actions"] = list(LINKEDIN_FIXES)
        elif t in ("web", "web_page"):
            text = s.get("text") or ""
            if text.strip():
                s["access"] = "ok"
            else:
                allowed = web_allowed(s.get("uri") or "")
                if allowed is False:
                    s["access"] = "denied"
                    s["access_reason"] = "the site's robots.txt does not allow automatic reading"
                    s["fix_action"] = "open_in_browser"
                else:
                    s["access"] = "ok"
                    s["access_reason"] = "read when the sheet is built"
                    s["fetch"] = True
        else:
            s["access"] = "unsupported"
            s["access_reason"] = f"unknown source type {t}"
    except Exception as e:  # noqa: BLE001
        s["access"] = "denied"
        s["access_reason"] = f"cannot read: {type(e).__name__}"
        s["fix_action"] = "retry"
    s["chars"] = len(text)
    s["size_tokens"] = Z.estimate(text, route, windows) if text else (int(s.get("size_tokens") or 0) if s.get("fetch") else 0)
    if s.get("fetch") and not s["size_tokens"]:
        s["size_tokens"] = 1500        # a web page before it is read: a typical page, replaced after the fetch
        s["estimated"] = True
    if text:
        texts[s["id"]] = text
    return s


def _title(s: dict) -> str:
    if s.get("title"):
        return s["title"]
    if s.get("path"):
        return os.path.basename(s["path"])
    if s.get("uri"):
        return LABEL.get(s.get("type", ""), "Link") + ": " + s["uri"][:80]
    return {"text": "Call context", "linkedin_manual": "LinkedIn, typed by you"}.get(s.get("type", ""), s.get("type", "source"))


def normalize(raw: List[dict]) -> List[dict]:
    """Ids s1, s2 ... (kept when given), n in order, a type from the link or the path, a title."""
    out, used_ids = [], set()
    for x in raw or []:
        s = dict(x)
        if s.get("url") and not s.get("uri"):
            s["uri"] = s.pop("url")
        if not s.get("type"):
            if s.get("uri"):
                s["type"] = classify(s["uri"])["type"]
            elif s.get("path"):
                s["type"] = "file"
            else:
                s["type"] = "text"
        if s["type"] == "web" and s.get("uri") and classify(s["uri"])["type"] != "web":
            s["type"] = classify(s["uri"])["type"]
        s["title"] = _title(s)
        s.setdefault("auto", False)
        out.append(s)
    for s in out:
        if s.get("id"):
            used_ids.add(s["id"])
    k = 1
    for i, s in enumerate(out):
        if not s.get("id"):
            while f"s{k}" in used_ids:
                k += 1
            s["id"] = f"s{k}"
            used_ids.add(s["id"])
        s["n"] = i + 1
    return out


def collect(req: dict, route: Optional[str] = None) -> Tuple[List[dict], Dict[str, str], List[dict]]:
    """(sources with access and size, their texts by id, move suggestions for the context)."""
    route = route or req.get("route") or "codex"
    windows = Z.load_windows()
    raw = list(req.get("sources") or [])
    ctx = (req.get("context") or "").strip()
    if ctx and not any(s.get("type") == "text" and s.get("role") == "context" for s in raw):
        raw.insert(0, {"type": "text", "role": "context", "title": "Call context", "text": ctx, "id": "s-context"})
    srcs = normalize(raw)
    texts: Dict[str, str] = {}
    for s in srcs:
        check(s, req, texts, route, windows)
    return srcs, texts, move_suggestions(ctx, srcs)


# ---------------------------------------------------------------- candidates

def _words(text: str) -> set:
    from ..prepcontext import words
    return words(text)


def _series_slug(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", (title or "").lower())


def previous_sheets(live: str, title: str, before: Optional[str] = None, n: int = 3) -> List[str]:
    """Sheets of the same meeting series (prep-<date>-<slug>.sheet.json), newest first."""
    want = _series_slug(title)
    out = []
    try:
        names = sorted(os.listdir(live), reverse=True)
    except OSError:
        return []
    for name in names:
        m = re.match(r"^prep-(\d{4}-\d\d-\d\d-\d{4})-(.+)\.sheet\.json$", name)
        if not m or _series_slug(m.group(2)) != want:
            continue
        if before and m.group(1) >= before:
            continue
        out.append(os.path.join(live, name))
        if len(out) >= n:
            break
    return out


def _candidate(t: str, title: str, why: List[str], suggested: bool, **kw) -> dict:
    c = {"type": t, "title": title, "why": why, "suggested": suggested, "auto": True}
    c.update({k: v for k, v in kw.items() if v is not None})
    return c


def candidates(req: dict, limit: int = 40) -> dict:
    """{candidates: [...], total, excluded: {reason: count}}: the folder files ranked with a why, then the series,
    the tracker, the project state and the digest. suggested = ticked by the series (an earlier sheet used it)."""
    from .. import prepcontext as PC
    from ..localprep import previous_calls
    project = req.get("project") or {}
    root = os.path.expanduser(project.get("root") or req.get("root") or "")
    meeting = req.get("meeting") or {}
    title = meeting.get("title") or req.get("title") or ""
    today = _dt.date.fromisoformat(req["today"]) if req.get("today") else _dt.date.today()
    live = req.get("live") or (os.path.join(root, "live") if root else "")
    theirs = [p.get("name", "") for p in ((req.get("participants") or {}).get("theirs") or [])]
    contact_words = _words(" ".join(theirs + [p.get("company", "") for p in ((req.get("participants") or {}).get("theirs") or [])]))
    title_words = _words(title)
    keys = title_words | contact_words | _words(req.get("context") or "")
    have = {os.path.expanduser(s.get("path") or "") for s in req.get("sources") or [] if s.get("path")}
    out: List[dict] = []
    # the series: the previous sheet and its sources
    series_paths: set = set()
    stamp = None
    if meeting.get("start"):
        stamp = meeting["start"][:16].replace("T", "-").replace(":", "")
    prev_sheets = previous_sheets(live, title, stamp) if live else []
    if prev_sheets:
        try:
            ps = json.loads(Path(prev_sheets[0]).read_text(encoding="utf-8"))
            series_paths = {os.path.expanduser(s.get("path")) for s in ps.get("sources") or [] if s.get("path")}
        except (OSError, ValueError):
            pass
        md = prev_sheets[0][:-len(".json")] + ".md"
        out.append(_candidate("prev_call", "Previous Meeting Sheet: " + os.path.basename(prev_sheets[0]),
                              ["previous sheet"], True, path=md if os.path.exists(md) else prev_sheets[0]))
    # the earlier calls of the series (notes when there are, else the transcript)
    if live and os.path.isdir(live) and req.get("use_project_folder", True):
        for p in previous_calls(live, title, 3):
            stem = re.sub(r"(\.named)?\.md$", "", p)
            notes = stem + ".notes.md"
            use = notes if os.path.exists(notes) else p
            out.append(_candidate("prev_call", "Earlier call: " + os.path.basename(stem), ["same meeting"], True,
                                  path=use, modified_at=_mtime(use)))
        # the tracker: open commitments of the project, this series first
        try:
            from .. import commitments as CM
            items = CM.open_items(live, CM.series_key(project.get("slug", ""), title), 15)
        except Exception:  # noqa: BLE001
            items = []
        if items:
            lines = [f"- {i.get('owner', '')}: {i.get('text', '')} (due {i.get('due') or 'not set'}, since "
                     f"{str(i.get('created', ''))[:10]})" for i in items]
            out.append(_candidate("tracker", f"Open commitments ({len(items)})", ["open items of the project"], True,
                                  text="\n".join(lines)))
    # the project state
    if root and req.get("use_project_folder", True):
        cfg = project.get("config") or req.get("config")
        if cfg and os.path.exists(os.path.expanduser(cfg)):
            out.append(_candidate("project_state", "Project config", ["project state"], True, path=os.path.expanduser(cfg)))
        dec = os.path.join(root, "pacenote", "decisions.md")
        if os.path.exists(dec):
            out.append(_candidate("project_state", "Active decisions", ["project state"], True, path=dec, modified_at=_mtime(dec)))
        for p in PC.current_state([os.path.join(root, "_notion")] + list(req.get("notion_dirs") or [])):
            out.append(_candidate("project_state", "Current State: " + os.path.basename(p), ["project state"], True,
                                  path=p, modified_at=_mtime(p)))
        if req.get("lt"):
            out.append(_candidate("digest", "Digest of the last 14 days", ["project state"], False, cmd="digest"))
    # the folder
    folders = ([root] if root and req.get("use_project_folder", True) else []) + [f for f in req.get("folders") or [] if os.path.isdir(os.path.expanduser(f))]
    files, excluded = _walk([os.path.expanduser(f) for f in folders], set(have) | {c.get("path") for c in out})
    newer: Dict[str, str] = {}
    before = len(files)
    files = PC.drop_old_versions(files, excluded)
    for p in excluded.get("older version", []):
        newer[os.path.dirname(p)] = os.path.basename(p)
    ranked = []
    for c in files:
        p = c["path"]
        name = os.path.splitext(os.path.basename(p))[0]
        nw = _words(name)
        head = ""
        if readers.kind_of(p) in ("md", "txt", "csv", "json", "yaml", "yml"):
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    head = fh.read(6000)
            except OSError:
                head = ""
        hw = _words(head)
        why, score = [], 0
        if contact_words and (contact_words & (nw | hw)):
            why.append("same contact"); score += 6
        if title_words and (title_words & nw):
            why.append("title match"); score += 4 + len(title_words & nw)
        if c["age_days"] <= FRESH_DAYS:
            why.append(f"fresh ({c['date']})"); score += 3
        hits = len(keys & hw)
        if hits >= 3:
            why.append(f"matches the call ({hits} words)"); score += min(hits, 8)
        if PC.VERSION.search(os.path.basename(p)):
            why.append("newer version"); score += 1
        if p in series_paths:
            why.append("used by the previous sheet"); score += 10
        ranked.append((score, -_dt.date.fromisoformat(c["date"]).toordinal(), p, c, why))
    ranked.sort(key=lambda x: (-x[0], x[1], x[2]))
    for score, _, p, c, why in ranked[:limit]:
        out.append(_candidate("folder_file", os.path.relpath(p, root) if root and p.startswith(root) else os.path.basename(p),
                              why or ["rest of the folder"], p in series_paths, path=p, modified_at=c["date"],
                              score=score, kind=readers.kind_of(p)))
    return {"candidates": out, "total_files": before, "shown": min(limit, len(ranked)),
            "excluded": {k: len(v) for k, v in excluded.items()},
            "never": "_archived, hidden files, binaries, raw logs, generated call files"}


def _walk(folders: List[str], skip: set) -> Tuple[List[dict], Dict[str, list]]:
    from .. import prepcontext as PC
    today = _dt.date.today()
    cands, excluded = [], {}
    for d in folders:
        for rootd, dirs, files in os.walk(d):
            keep = []
            for x in sorted(dirs):
                why = PC._excluded_reason(rootd, x, True)
                if why or x in ("live", "_notion", "meeting-sheet"):
                    if why:
                        excluded.setdefault(why, []).append(os.path.join(rootd, x) + "/")
                else:
                    keep.append(x)
            dirs[:] = keep
            for f in sorted(files):
                p = os.path.join(rootd, f)
                if p in skip or f.startswith("."):
                    continue
                if PC.GENERATED.search(f) or f.endswith((".sheet.json", ".jsonl", ".log")):
                    excluded.setdefault("generated call file", []).append(p)
                    continue
                if not readers.supported(p):
                    excluded.setdefault("not a document", []).append(p)
                    continue
                dt = PC.file_date(p)
                cands.append({"path": p, "date": dt.isoformat(), "age_days": (today - dt).days})
    return cands, excluded
