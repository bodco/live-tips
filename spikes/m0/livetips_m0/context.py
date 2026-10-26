"""Call context for calls started without a Cowork prep.

From what the PM typed at the start (a few lines: what the call is about, what to look for)
and the project folder, builds a text block for the cached prompt prefix:
  - the PM's context as typed,
  - the project's Current State from the local Notion mirror (_notion/current-state.md),
  - the best snippets of the project index for the context (lt search, local embeddings),
  - a digest of the project's recent calls (lt digest): questions, answers, promises, typed notes.
Nothing here leaves the Mac except as part of the prompt for a project with API access.
"""
import json
import subprocess
from pathlib import Path
from typing import List, Optional


def current_state(project_root: Path, limit: int = 6000) -> str:
    p = project_root / "_notion" / "current-state.md"
    if p.exists():
        return p.read_text(encoding="utf-8", errors="replace")[:limit]
    return ""


def workspace_states(root: Path, limit_each: int = 5000, max_projects: int = 5) -> List[str]:
    """A workspace call (a PM sync about several projects): the root has no Current State of its own,
    so the member projects' pages are used (folders next to it or below it with _notion/current-state.md).
    A "<Workspace> General" folder is the workspace's own folder: its parent holds the projects."""
    bases = [root]
    try:
        if root.name.lower().endswith(" general"):
            bases.append(root.parent)
        if root.is_symlink() or (root / "live").is_symlink():
            bases.append(root.resolve().parent)
    except OSError:
        pass
    out, seen = [], set()
    for base in bases:
        try:
            subs = sorted(d for d in base.iterdir() if d.is_dir() and not d.name.startswith((".", "_")))
        except OSError:
            continue
        for d in subs:
            p = d / "_notion" / "current-state.md"
            if p.exists() and p.resolve() not in seen and len(out) < max_projects:
                seen.add(p.resolve())
                out.append("[{}]\n{}".format(d.name, p.read_text(encoding="utf-8", errors="replace")[:limit_each]))
    return out


def index_snippets(lt_cmd: List[str], project_root: Path, query: str, k: int = 8, timeout: float = 25.0) -> List[dict]:
    if not lt_cmd or not query.strip():
        return []
    try:
        out = subprocess.run(lt_cmd + ["search", query, "--root", str(project_root), "-k", str(k), "--json"],
                             capture_output=True, text=True, timeout=timeout).stdout
        i = out.find("{")
        data = json.loads(out[i:]) if i >= 0 else {}
        hits = data.get("hits", []) if isinstance(data, dict) else data
        return [h for h in hits if isinstance(h, dict)]
    except Exception:
        return []


def recent_calls(lt_cmd: List[str], project_root: Path, days: int = 7, max_chars: int = 3000,
                 timeout: float = 10.0) -> str:
    """`lt digest`: what was asked, answered, promised and typed on this project's recent calls.
    Empty on any problem (no lt, error exit, timeout, no calls): the call starts without it."""
    if not lt_cmd:
        return ""
    try:
        r = subprocess.run(lt_cmd + ["digest", str(project_root), "--days", str(days), "--max-chars", str(max_chars)],
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode != 0:
            return ""
        out = (r.stdout or "").strip()
        if not out or "(no calls in the window)" in out or out.startswith("ERROR"):
            return ""
        return out[: max_chars + 200]
    except Exception:
        return ""


def build(context: str, project_root: Optional[str], lt_cmd: Optional[List[str]] = None) -> str:
    parts = []
    if context.strip():
        parts.append("CALL CONTEXT FROM THE PM (what this call is about and what to look for):\n" + context.strip())
    if project_root:
        root = Path(project_root)
        cs = current_state(root)
        if cs:
            parts.append("PROJECT CURRENT STATE (local Notion mirror):\n" + cs)
        else:
            ws = workspace_states(root)
            if ws:
                parts.append("CURRENT STATE OF THE WORKSPACE PROJECTS (local Notion mirror; a call about "
                             "several projects):\n" + "\n\n".join(ws))
        hits = index_snippets(lt_cmd or [], root, context) if context.strip() else []
        if hits:
            lines = []
            for h in hits[:8]:
                src = h.get("rel") or h.get("path") or ""
                date = h.get("date") or h.get("last_edited") or ""
                text = (h.get("preview") or h.get("text") or "").replace("\n", " ")[:400]
                lines.append("- [{}{}] {}".format(src, ", " + date if date else "", text))
            parts.append("LOCAL MATERIALS FOUND FOR THE CONTEXT (project index):\n" + "\n".join(lines))
        digest = recent_calls(lt_cmd or [], root)
        if digest:
            parts.append("RECENT CALLS (digest; what the PM already said, answered or promised on this project's "
                         "last calls; newer than the Notion state when they disagree):\n" + digest)
    return "\n\n".join(parts)
