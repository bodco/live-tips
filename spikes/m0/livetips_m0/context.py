"""Call context for calls started without a Cowork prep.

From what the PM typed at the start (a few lines: what the call is about, what to look for)
and the project folder, builds a text block for the cached prompt prefix:
  - the PM's context as typed,
  - the project's Current State from the local Notion mirror (_notion/current-state.md),
  - the best snippets of the project index for the context (lt search, local embeddings).
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


def build(context: str, project_root: Optional[str], lt_cmd: Optional[List[str]] = None) -> str:
    parts = []
    if context.strip():
        parts.append("CALL CONTEXT FROM THE PM (what this call is about and what to look for):\n" + context.strip())
    if project_root:
        root = Path(project_root)
        cs = current_state(root)
        if cs:
            parts.append("PROJECT CURRENT STATE (local Notion mirror):\n" + cs)
        hits = index_snippets(lt_cmd or [], root, context) if context.strip() else []
        if hits:
            lines = []
            for h in hits[:8]:
                src = h.get("rel") or h.get("path") or ""
                date = h.get("date") or h.get("last_edited") or ""
                text = (h.get("preview") or h.get("text") or "").replace("\n", " ")[:400]
                lines.append("- [{}{}] {}".format(src, ", " + date if date else "", text))
            parts.append("LOCAL MATERIALS FOUND FOR THE CONTEXT (project index):\n" + "\n".join(lines))
    return "\n\n".join(parts)
