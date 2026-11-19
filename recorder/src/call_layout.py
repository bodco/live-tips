"""Call folders (rules/call_layout.yaml, Bohdan 19.11.2026): one folder per call, live/<YYYY-MM-DD>-<slug>/, with the
transcript, notes, brief and Meeting Sheet on top and every service file in .work/. File names do not change; a file
still directly in live/ keeps the old flat rule. Mirrors LiveTipsCore/CallLayout.swift; recorder/src/call_layout.py is
an identical copy (pytest checks both against each other and against the rules file)."""
from __future__ import annotations

import os
import re
import time
from pathlib import Path

WORK_DIR = ".work"
VISIBLE_CALL = {".md", ".app.md", ".notes.md", ".app.notes.md", ".brief.md", ".app.brief.md"}
VISIBLE_PREP = {".sheet.md"}
QUIET_S = 600
_NAME = re.compile(r"^(prep-)?(\d{4}-\d{2}-\d{2})-(\d{4})-([^.]+)(\..+)$")


def parse(name: str):
    """'prep-2026-11-18-1515-x.sheet.json' -> dict(prep, date, key, slug, rest) or None."""
    m = _NAME.match(name)
    if not m:
        return None
    return {"prep": bool(m.group(1)), "date": m.group(2), "key": f"{m.group(2)}-{m.group(3)}-{m.group(4)}",
            "slug": m.group(4), "rest": m.group(5)}


def folder_name(date: str, slug: str) -> str:
    return f"{date}-{slug}"


def visible(name: str) -> bool:
    p = parse(name)
    if not p:
        return False
    return p["rest"] in (VISIBLE_PREP if p["prep"] else VISIBLE_CALL)


def is_call_folder(d) -> bool:
    d = Path(d)
    if d.name == WORK_DIR:
        return is_call_folder(d.parent)
    return d.name != "live" and d.parent.name == "live"


def folder(live, date: str, slug: str, create: bool = False) -> Path:
    f = Path(live) / folder_name(date, slug)
    if create:
        (f / WORK_DIR).mkdir(parents=True, exist_ok=True)
    return f


def place(name: str, d) -> Path:
    """Where the call file `name` lives, given the folder its transcript is in."""
    d = Path(d)
    if d.name == WORK_DIR:
        d = d.parent
    if not is_call_folder(d) or visible(name):
        return d / name
    return d / WORK_DIR / name


def sidecar(stem, suffix: str) -> Path:
    """Replaces `stem + suffix` (stem = the transcript without '.md', e.g. '.../X.app')."""
    s = str(stem)
    return place(os.path.basename(s) + suffix, os.path.dirname(s))


def sidecar_mk(stem, suffix: str) -> Path:
    """sidecar() for a file about to be written: its folder (a call folder's .work/) is created first."""
    p = sidecar(stem, suffix)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def sidecar_of(transcript, suffix: str) -> Path:
    t = str(transcript)
    return sidecar(t[:-3] if t.endswith(".md") else t, suffix)


def live_folder(file) -> Path:
    d = Path(file).parent
    if d.name == WORK_DIR:
        return d.parent.parent
    return d.parent if is_call_folder(d) else d


def files(live) -> list[Path]:
    """Visible call files of a live folder in both layouts (flat first, then the top of each call folder)."""
    live, out = Path(live), []
    if not live.is_dir():
        return out
    for p in sorted(live.iterdir()):
        if p.name.startswith("."):
            continue
        if p.is_file():
            out.append(p)
        elif p.is_dir() and "." not in p.name and re.match(r"^\d{4}-\d{2}-\d{2}-", p.name):
            out.extend(c for c in sorted(p.iterdir()) if not c.name.startswith("."))
    return out


def migrate(live, now: float | None = None, quiet: float = QUIET_S) -> dict:
    """Moves flat call files of `live` into call folders. Move only, nothing deleted or overwritten; idempotent."""
    live, now = Path(live), time.time() if now is None else now
    rep = {"moved": [], "conflicts": [], "skipped_busy": [], "failed": []}
    if not live.is_dir():
        return rep
    by_key: dict[str, list] = {}
    for p in sorted(live.iterdir()):
        n = parse(p.name)
        if n:
            by_key.setdefault(n["key"], []).append((p, n))
    for key in sorted(by_key):
        items = by_key[key]
        if any(now - p.stat().st_mtime < quiet for p, _ in items):
            rep["skipped_busy"].append(key)
            continue
        for p, n in items:
            to = place(p.name, folder(live, n["date"], n["slug"], create=True))
            if to.exists():
                rep["conflicts"].append(str(p))
                continue
            try:
                os.rename(p, to)
                rep["moved"].append((str(p), str(to)))
            except OSError as e:
                rep["failed"].append(f"{p}: {e}")
    return rep
