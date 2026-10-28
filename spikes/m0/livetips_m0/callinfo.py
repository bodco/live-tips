"""What a held call left behind, read from its files (Pacenote 0.8.6, F6): the transcript, the last call picture,
the last agenda strip, the risks. Shared by the follow-up email, the call memory and the tests."""
import json
import re
from pathlib import Path
from typing import List, Optional

from .transcript import LINE_RE


def stem_of(md: Path) -> str:
    s = str(md)
    return s[:-3] if s.endswith(".md") else s


def tips_files(md: Path) -> List[Path]:
    """The app's tips file (<file>.tips.jsonl) and the skill's (<stem>.tips.jsonl)."""
    out = [Path(str(md) + ".tips.jsonl"), Path(stem_of(md) + ".tips.jsonl")]
    return [p for p in out if p.exists()]


def last_item(md: Path, kind: str) -> Optional[dict]:
    last = None
    for p in tips_files(md):
        for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if '"' + kind + '"' not in ln:
                continue
            try:
                o = json.loads(ln)
            except ValueError:
                continue
            if o.get("kind") == kind:
                last = o
    return last


def items_of_kind(md: Path, kind: str) -> List[dict]:
    out = []
    for p in tips_files(md):
        for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if '"' + kind + '"' in ln:
                try:
                    o = json.loads(ln)
                except ValueError:
                    continue
                if o.get("kind") == kind:
                    out.append(o)
    return out


def header(md: Path) -> dict:
    head = md.read_text(encoding="utf-8", errors="replace").splitlines()[:12]
    title = next((l.split(":", 1)[1].strip() for l in head if l.lower().startswith("# live transcript:")), md.stem)
    start = next((l.split(":", 1)[1].strip() for l in head if l.startswith("- Start:") or l.startswith("- Початок:")), "")
    proj = next((m.group(1) for l in head for m in [re.match(r"^- \S+:\s*([a-z0-9-]+)\s*$", l)] if m), "")
    return {"title": title, "start": start, "project": proj}


def lines(md: Path, max_chars: int = 120000) -> List[dict]:
    out, n = [], 0
    for raw in md.read_text(encoding="utf-8", errors="replace").splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        t, label, stag, lang, text = m.groups()
        out.append({"t": t, "who": label.strip() + (" " + stag if stag else ""), "text": text.strip()})
        n += len(raw)
        if n > max_chars:
            break
    return out


def transcript_text(md: Path, max_chars: int = 90000) -> str:
    return "\n".join("[{}] {}: {}".format(l["t"], l["who"], l["text"]) for l in lines(md, max_chars))
