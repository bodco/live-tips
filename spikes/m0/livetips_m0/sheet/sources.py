"""0.10.0 (Meeting Sheet, phase 2): the sources of a sheet, checked before any model runs, the same on every route.

- Links: Google Docs / Sheets / Slides / Drive files (the patterns of the app's GoogleLink), Notion, LinkedIn, web.
  A link written in the free-text context is never moved silently: it comes back as a "Move to Sources" suggestion.
- Access per source: access ok | denied | unsupported | pending, access_reason, fix_action (and fix_actions for
  LinkedIn). Google is read by the app through OAuth: the request carries the copies the app already fetched
  (google.copies) or a status hint (google.status: ok | denied | not_found); a Drive file nobody can open is
  "denied" with confirm_google (drive.file + Google Picker) until the PM confirms it there; the app then keeps a copy
  in <project>/live/google/google-file-<id16>.<ext> and the source is "ok" with that copy (picked_copy).
  Notion without a connection: connect_notion. LinkedIn: pending
  with save_as_pdf, open_in_browser, paste_text, fill_by_hand. A web page: ok, read when the sheet is built (the
  robots.txt check lives in the web module of phase 6: web_allowed() is the hook).
- Candidates from the project folder with a "why" (same contact, fresh, title match, previous sheet, newer version).
  Nothing from the folder scan is ticked unless the series says so (suggested: true).
- Auto sources (fix 2026-11-12, owner): the earlier calls of the series (notes first, the transcript without notes),
  the Tracker (open items on the PM and waiting on others, sheet/tracker.py), the project state, the digest and the
  recent commits of the folders. They are ticked (suggested: true) and every build adds them (build.py), also when
  the series memory or the wizard already lists sources; auto_sources() gives them with their why.
"""
import datetime as _dt
import hashlib
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
# 0.10.0 (Meeting Sheet, folders): a folder is a source of its own. The preparation reads its files changed in the last
# folder_days days (rules/meeting-sheet.yaml, Settings > Meeting Sheet, or the folder's own days), newest first, within
# the size budget; the whole folder stays searchable during the call (sheet/lookup.py, FolderIndex deep roots).
FOLDER_DAYS = 7
FOLDER_FALLBACK = 5          # no file in the window: the newest few, so a folder is never empty
FOLDER_TOKENS = 60000        # one folder takes at most this much of the pass
FOLDER_MAX_READS = 80        # files read for one folder at most (the rest is not an error, it stays searchable)


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


def picked_copy(req: dict, s: dict) -> Optional[str]:
    """0.10.0 (Meeting Sheet, Google Picker): the local copy of a Drive file the PM confirmed in Google Picker,
    <project>/live/google/google-file-<id16>.<ext> (GoogleDriveCopy in LiveTipsCore/GoogleCore.swift), newest first.
    None until the file was confirmed: the source stays denied with confirm_google."""
    g = google_link(s.get("uri") or s.get("url") or "")
    if not g or g[0] != "file":
        return None
    project = req.get("project") or {}
    root = os.path.expanduser(project.get("root") or req.get("root") or "")
    live = req.get("live") or (os.path.join(root, "live") if root else "")
    folder = os.path.join(os.path.expanduser(live), "google") if live else ""
    if not folder or not os.path.isdir(folder):
        return None
    prefix = f"google-file-{g[1][:16]}."
    hits = [os.path.join(folder, f) for f in os.listdir(folder) if f.startswith(prefix) and not f.endswith(".part")]
    return max(hits, key=os.path.getmtime) if hits else None


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
        if t == "folder":
            # 0.10.0 (Meeting Sheet, folders): never "a folder, not a file"; its files are taken by expand_folders()
            p = os.path.expanduser(s.get("path") or "")
            if not p or not os.path.exists(p):
                s["access"], s["access_reason"], s["fix_action"] = "denied", "folder not found", "retry"
            elif not os.path.isdir(p) or not os.access(p, os.R_OK | os.X_OK):
                s["access"], s["access_reason"], s["fix_action"] = "denied", "no permission to read the folder", "retry"
            else:
                s["access"] = "ok"
                s["modified_at"] = s.get("modified_at") or _mtime(p)
        elif t in ("file", "folder_file", "prev_call", "project_state", "tracker", "digest", "crm", "transcript") and s.get("path"):
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
        elif t == "tracker" and not s.get("path") and not (s.get("text") or "").strip():
            # 0.10.0: the Tracker source has no file; it is the open items of the project registers, collected here
            try:
                from . import tracker as TR
                _d = _dt.date.fromisoformat(req["today"]) if req.get("today") else _dt.date.today()
                tr = TR.collect(req, _d)
                text = TR.text(tr) if (tr["on_me"] or tr["waiting"]) else ""
            except Exception:  # noqa: BLE001
                text = ""
            if text.strip():
                s["access"] = "ok"
                s["title"] = s.get("title") or TR.title(tr)
            else:
                s["access"], s["access_reason"], s["fix_action"] = "pending", "no open items found in the project registers", "retry"
        elif t in TEXT_TYPES or (s.get("text") and t not in ("gdoc", "gsheet", "gslides", "drive_file", "notion", "linkedin")):
            text = s.get("text") or ""
            s["access"] = "ok" if text.strip() else "pending"
            if not text.strip():
                s["access_reason"] = "empty"
                s["fix_action"] = "paste_text" if t != "linkedin_manual" else "fill_by_hand"
        elif t in ("gdoc", "gsheet", "gslides", "drive_file"):
            copy = _lookup(g.get("copies") or {}, s)
            if not (copy and os.path.exists(os.path.expanduser(copy))) and t == "drive_file":
                copy = picked_copy(req, s) or copy      # 0.10.0 (Google Picker): confirmed earlier, on this Mac
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
        if s["type"] in ("file", "folder_file") and s.get("path") and os.path.isdir(os.path.expanduser(s["path"])):
            s["type"] = "folder"          # 0.10.0 (Meeting Sheet, folders): an older setup saved a folder as a file
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
    srcs = expand_folders(srcs, texts, req, route, windows)      # 0.10.0 (Meeting Sheet, folders)
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


def _stamp(meeting: dict) -> Optional[str]:
    return meeting["start"][:16].replace("T", "-").replace(":", "") if meeting.get("start") else None


def _folder_roots(req: dict) -> List[str]:
    """The project root and every folder added to the call (sources of type folder, or a folder saved as a file)."""
    project = req.get("project") or {}
    out = []
    root = os.path.expanduser(project.get("root") or req.get("root") or "")
    if root and os.path.isdir(root):
        out.append(root)
    for s in req.get("sources") or []:
        p = os.path.expanduser(s.get("path") or "")
        if p and os.path.isdir(p) and s.get("type") in ("folder", "folder_file", "file", None):
            out.append(p)
    out += [os.path.expanduser(f) for f in req.get("folders") or [] if os.path.isdir(os.path.expanduser(f))]
    seen, res = set(), []
    for p in out:
        if os.path.realpath(p) not in seen:
            seen.add(os.path.realpath(p))
            res.append(p)
    return res


def recent_commits(folder: str, since: _dt.date, limit: int = 20) -> str:
    """The commits of a git folder since a day (subject lines, newest first), "" when it is not a repository."""
    if not os.path.isdir(os.path.join(folder, ".git")):
        return ""
    import subprocess
    try:
        r = subprocess.run(["git", "-C", folder, "log", f"--since={since.isoformat()}", f"-n{limit}",
                            "--date=short", "--pretty=format:%ad %an: %s"], capture_output=True, text=True, timeout=15)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:  # noqa: BLE001
        return ""


def auto_sources(req: dict) -> List[dict]:
    """0.10.0 (Meeting Sheet, fix 2026-11-12, owner): what every build reads besides the PM's own sources, each
    ticked (suggested) with a why: the last 1-3 calls of the series (notes first, the transcript without notes; the
    previous sheet when there is no earlier call), the Tracker (on me and waiting on others; a workspace call: every
    project of the workspace and every folder added), the project state, the digest and the recent commits of the
    folders. Not gated by use_project_folder (that is the folder scan). The tracker candidate carries _tracker."""
    from .. import prepcontext as PC
    from ..localprep import previous_calls
    from . import tracker as TR
    project = req.get("project") or {}
    root = os.path.expanduser(project.get("root") or req.get("root") or "")
    meeting = req.get("meeting") or {}
    title = meeting.get("title") or req.get("title") or ""
    today = _dt.date.fromisoformat(req["today"]) if req.get("today") else _dt.date.today()
    live = os.path.expanduser(req.get("live") or (os.path.join(root, "live") if root else ""))
    stamp = _stamp(meeting)
    out: List[dict] = []
    # the series: the last calls before this one (a rebuild during the call never reads its own transcript)
    last_day: Optional[_dt.date] = None
    if live and os.path.isdir(live):
        calls = [p for p in previous_calls(live, title, 8) if not stamp or os.path.basename(p)[:15] < stamp][:3]
        for p in calls:
            stem = re.sub(r"(\.named)?\.md$", "", p)
            notes = stem + ".notes.md"
            use = notes if os.path.exists(notes) else p
            day = os.path.basename(stem)[:10]
            try:
                last_day = max(last_day or _dt.date.min, _dt.date.fromisoformat(day))
            except ValueError:
                pass
            why = ["same meeting series", ("notes of " if use == notes else "transcript of (no notes) ") + day]
            out.append(_candidate("prev_call", "Earlier call: " + os.path.basename(stem), why, True,
                                  path=use, modified_at=_mtime(use)))
        if not calls:
            prev_sheets = previous_sheets(live, title, stamp)
            if prev_sheets:
                md = prev_sheets[0][:-len(".json")] + ".md"
                out.append(_candidate("prev_call", "Previous Meeting Sheet: " + os.path.basename(prev_sheets[0]),
                                      ["same meeting series", "previous sheet"], True,
                                      path=md if os.path.exists(md) else prev_sheets[0]))
    # the Tracker
    try:
        tr = TR.collect(req, today)
    except Exception:  # noqa: BLE001
        tr = {"on_me": [], "waiting": [], "folders": 0}
    if tr["on_me"] or tr["waiting"]:
        c = _candidate("tracker", TR.title(tr), ["open items on you and waiting on others",
                                                 f"from {tr['folders']} project register{'s' if tr['folders'] != 1 else ''}"],
                       True, text=TR.text(tr))
        c["_tracker"] = tr
        out.append(c)
    # the project state (the project and every folder added)
    roots = _folder_roots(req)
    cfg = project.get("config") or req.get("config")
    if cfg and os.path.exists(os.path.expanduser(cfg)):
        out.append(_candidate("project_state", "Project config", ["project state"], True, path=os.path.expanduser(cfg)))
    for r in roots:
        dec = os.path.join(r, "pacenote", "decisions.md")
        if os.path.exists(dec):
            out.append(_candidate("project_state", "Active decisions" + ("" if r == root else ": " + os.path.basename(r)),
                                  ["project state"], True, path=dec, modified_at=_mtime(dec)))
    for p in PC.current_state([os.path.join(r, "_notion") for r in roots] + list(req.get("notion_dirs") or [])):
        out.append(_candidate("project_state", "Current State: " + os.path.basename(p), ["project state"], True,
                              path=p, modified_at=_mtime(p)))
    # the digest of the project and the recent commits of the folders
    if req.get("lt") and root:
        out.append(_candidate("digest", "Digest of the last 14 days", ["what changed in the project"], True, cmd="digest"))
    since = last_day or (today - _dt.timedelta(days=3))
    for r in roots:
        log = recent_commits(r, since)
        if log:
            out.append(_candidate("digest", "Recent commits: " + os.path.basename(r),
                                  ["recent work", f"commits since {since.isoformat()}"], True, text=log))
    return out


def candidates(req: dict, limit: int = 40) -> dict:
    """{candidates: [...], total, excluded: {reason: count}}: the auto sources (the series, the Tracker, the project
    state, the digest, ticked), then the folder files ranked with a why. suggested = ticked."""
    from .. import prepcontext as PC
    project = req.get("project") or {}
    root = os.path.expanduser(project.get("root") or req.get("root") or "")
    meeting = req.get("meeting") or {}
    title = meeting.get("title") or req.get("title") or ""
    live = req.get("live") or (os.path.join(root, "live") if root else "")
    theirs = [p.get("name", "") for p in ((req.get("participants") or {}).get("theirs") or [])]
    contact_words = _words(" ".join(theirs + [p.get("company", "") for p in ((req.get("participants") or {}).get("theirs") or [])]))
    title_words = _words(title)
    keys = title_words | contact_words | _words(req.get("context") or "")
    have = {os.path.expanduser(s.get("path") or "") for s in req.get("sources") or [] if s.get("path")}
    # the series: the sources of the previous sheet rank first in the folder scan
    series_paths: set = set()
    prev_sheets = previous_sheets(live, title, _stamp(meeting)) if live else []
    if prev_sheets:
        try:
            ps = json.loads(Path(prev_sheets[0]).read_text(encoding="utf-8"))
            series_paths = {os.path.expanduser(s.get("path")) for s in ps.get("sources") or [] if s.get("path")}
        except (OSError, ValueError):
            pass
    out: List[dict] = []
    for c in auto_sources(req):
        c.pop("_tracker", None)
        if not (c.get("path") and os.path.expanduser(c["path"]) in have):
            out.append(c)
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


# ---------------------------------------------------------------- folders

def _settings(req: dict) -> dict:
    """rules/meeting-sheet.yaml settings with the request's settings and options over them."""
    out: dict = {}
    try:
        from . import presets as P
        out.update((P.load_rules().get("settings") or {}))
    except Exception:  # noqa: BLE001
        pass
    for k in ("settings", "options"):
        if isinstance(req.get(k), dict):
            out.update({kk: v for kk, v in req[k].items() if v is not None})
    return out


def folder_days(s: dict, settings: dict) -> int:
    """The folder's own days (Expert Sources), else Settings > Meeting Sheet, else rules (7)."""
    for v in (s.get("days"), settings.get("folder_days"), FOLDER_DAYS):
        try:
            if v is not None and int(v) > 0:
                return int(v)
        except (TypeError, ValueError):
            continue
    return FOLDER_DAYS


def file_day(path: str) -> _dt.date:
    """0.10.0 (Meeting Sheet, folders): the newer of the date in the name and the file's time (a dated note edited
    later counts as changed)."""
    from ..prepcontext import DATE_IN_NAME
    days = []
    m = DATE_IN_NAME.search(os.path.basename(path))
    if m:
        try:
            days.append(_dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3))))
        except ValueError:
            pass
    try:
        days.append(_dt.date.fromtimestamp(os.path.getmtime(path)))
    except OSError:
        pass
    return max(days) if days else _dt.date(1970, 1, 1)


def folder_files(folder: str, today: Optional[_dt.date] = None) -> Tuple[List[dict], Dict[str, list]]:
    """Every file of the folder that passes the filters of the preparation (archived, hidden, prep-runs, generated
    call files, binaries, logs, older -vN versions), newest first: [{path, date, age_days, mtime}], excluded."""
    from .. import prepcontext as PC
    today = today or _dt.date.today()
    files, excluded = _walk([os.path.expanduser(folder)], set())
    files = PC.drop_old_versions(files, excluded)
    out = []
    for c in files:
        d = file_day(c["path"])
        try:
            mt = os.path.getmtime(c["path"])
        except OSError:
            mt = 0.0
        out.append({"path": c["path"], "date": d.isoformat(), "age_days": (today - d).days, "mtime": mt})
    out.sort(key=lambda c: (-_dt.date.fromisoformat(c["date"]).toordinal(), -c["mtime"], c["path"]))
    return out, excluded


def _match(path: str, keys: set) -> int:
    if not keys:
        return 0
    w = _words(os.path.splitext(os.path.basename(path))[0])
    head = ""
    if readers.kind_of(path) in ("md", "txt", "csv", "json", "yaml", "yml"):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                head = fh.read(4000)
        except OSError:
            head = ""
    return 2 * len(keys & w) + len(keys & _words(head))


def _meeting_keys(req: dict) -> set:
    meeting = req.get("meeting") or {}
    theirs = (req.get("participants") or {}).get("theirs") or []
    text = " ".join([meeting.get("title") or req.get("title") or "", req.get("goal") or "", req.get("context") or ""]
                    + [p.get("name", "") + " " + p.get("company", "") for p in theirs if isinstance(p, dict)])
    return _words(text)


def folder_line(info: dict) -> str:
    """The folder row: "12 recent files for the preparation (last 7 days) · 340 searchable during the call"."""
    n, days, total = int(info.get("recent") or 0), int(info.get("days") or FOLDER_DAYS), int(info.get("searchable") or 0)
    if info.get("fallback"):
        head = (f"no file changed in the last {days} days: the newest {n} file{'s' if n != 1 else ''} "
                f"for the preparation") if n else f"no file changed in the last {days} days"
    else:
        head = f"{n} recent file{'s' if n != 1 else ''} for the preparation (last {days} days)"
    line = f"{head} · {total} searchable during the call"
    if info.get("over_budget"):
        line += f" · {info['over_budget']} more did not fit the size budget"
    return line


def expand_folders(srcs: List[dict], texts: Dict[str, str], req: dict, route: str, windows: dict) -> List[dict]:
    """0.10.0 (Meeting Sheet, folders): each folder source (access ok) gets its files changed in the last N days as
    folder_file sources (parent = the folder's id) right after it, newest first, ties by the match to the meeting,
    until the size budget; with no file in the window, the newest FOLDER_FALLBACK files. Files not taken are not
    errors. The folder keeps folder = {days, recent, in_window, searchable, fallback, over_budget, tokens} and a reason
    line; its own size is 0 (the Size step counts only the files taken). The numbers n are given again."""
    folders = [s for s in srcs if s.get("type") == "folder"]
    if not folders:
        return srcs
    fids = {s["id"] for s in folders}
    srcs = [s for s in srcs if s.get("parent") not in fids]          # a request that already lists children: again
    for s in srcs:
        if s.get("parent") in fids:
            texts.pop(s["id"], None)
    sett = _settings(req)
    today = _dt.date.fromisoformat(req["today"]) if req.get("today") else _dt.date.today()
    keys = _meeting_keys(req)
    have = {os.path.realpath(os.path.expanduser(s["path"])) for s in srcs if s.get("path") and s.get("type") != "folder"}
    info_r = Z.route_info(route, windows, req.get("model") or None)
    near = float(windows.get("near_share") or 0.8)
    room = int(Z.per_pass(info_r, windows) * near) - sum(
        int(s.get("size_tokens") or 0) for s in srcs
        if s.get("type") != "folder" and s.get("access") == "ok" and s.get("used") != "skipped")
    cap = int(sett.get("folder_tokens") or FOLDER_TOKENS)
    n_fallback = int(sett.get("folder_fallback") or FOLDER_FALLBACK)
    live = [f for f in folders if f.get("access") == "ok" and f.get("used") != "skipped"]
    out: List[dict] = []
    for s in srcs:
        out.append(s)
        if s not in live:
            continue
        days = folder_days(s, sett)
        files, _ex = folder_files(s["path"], today)
        total = len(files)
        files = [c for c in files if os.path.realpath(c["path"]) not in have]
        window = [c for c in files if c["age_days"] < days]
        fallback = not window
        pick = window if window else files[:n_fallback]
        pick.sort(key=lambda c: (-_dt.date.fromisoformat(c["date"]).toordinal(), -_match(c["path"], keys), c["path"]))
        k_left = max(1, len(live) - live.index(s))
        budget = max(0, min(cap, room // k_left))
        root = os.path.expanduser(s["path"])
        taken, over, used_t, reads = [], 0, 0, 0
        for c in pick:
            if reads >= FOLDER_MAX_READS or budget - used_t <= 0:
                over += 1
                continue
            reads += 1
            rel = os.path.relpath(c["path"], root)
            # a stable id per file (a refresh keeps the facts on the same file)
            ch = {"id": f"{s['id']}-f" + hashlib.sha1(rel.encode("utf-8")).hexdigest()[:8], "type": "folder_file", "path": c["path"], "title": rel,
                  "auto": True, "parent": s["id"], "modified_at": c["date"],
                  "why": [f"in {s.get('title') or os.path.basename(root)}", f"changed {c['date']}"] +
                         (["newest of the folder"] if fallback else [])}
            check(ch, req, texts, route, windows)
            if ch.get("access") != "ok":
                texts.pop(ch["id"], None)
                continue                                            # not taken, still searchable: not an error
            tok = int(ch.get("size_tokens") or 0)
            if used_t + tok > budget:
                texts.pop(ch["id"], None)
                over += 1
                continue
            used_t += tok
            have.add(os.path.realpath(c["path"]))
            taken.append(ch)
        room -= used_t
        info = {"days": days, "recent": len(taken), "in_window": len(window), "searchable": total,
                "fallback": fallback, "over_budget": over, "tokens": used_t}
        s["folder"] = info
        s["size_tokens"] = 0
        s["chars"] = 0
        s["reason"] = folder_line(info) if total else "the folder has no documents to read"
        s["used"] = "full" if taken and not over else ("truncated" if taken else "not_used")
        out.extend(taken)
    for i, s in enumerate(out):
        s["n"] = i + 1
    return out
