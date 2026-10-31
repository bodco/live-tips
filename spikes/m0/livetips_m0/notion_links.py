"""Pacenote 0.8.8 (rules/decisions.yaml > dedupe): the Notion pages made from one call, kept next to the call in
<stem>.notion.json {"decisions": {key: {"id", "url"}}, "risks": {...}, "tasks": {...}}. The key is the normalized
text, so the same decision of the same call is never written twice (by a click or by the automatic add)."""
import json
import re
from pathlib import Path
from typing import Optional

KINDS = ("decisions", "risks", "tasks")


def norm(text: str) -> str:
    """Lower case, letters and digits only, single spaces (any script)."""
    return " ".join(re.sub(r"[^\w]+", " ", (text or "").lower().replace("_", " ")).split())


def path_for(md) -> Path:
    s = str(md)
    return Path((s[:-3] if s.endswith(".md") else s) + ".notion.json")


def load(md) -> dict:
    try:
        d = json.loads(path_for(md).read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def get(md, kind: str, text: str) -> Optional[dict]:
    if not md:
        return None
    return (load(md).get(kind) or {}).get(norm(text))


def put(md, kind: str, text: str, page_id: str, url: str = "") -> None:
    if not md:
        return
    d = load(md)
    d.setdefault(kind, {})[norm(text)] = {"id": page_id or "", "url": url or ""}
    p = path_for(md)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
    tmp.replace(p)
