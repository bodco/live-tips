"""Pacenote 0.9.7 (owner, case of 11.11): the context of a preparation, picked by priority instead of the folder's
alphabet, and a manifest of what was taken, compressed, skipped or excluded, the same on every way.

A real call showed what the old pack did (localprep.build_pack, 0.8.5-0.9.6): the folder the PM added was walked
in the order of os.walk, 20 files per folder in alphabetical order (with a date in the name: the oldest first), and
it filled the 120 000 characters before the project config, the previous calls and the Current State were added.
A file the PM added was cut at 20 000 characters and the "cut" mark was cut off by the second slice, so the model
never knew. The deck never reached the packed ways at all.

Now, in this order:
  0. pinned: the call context, the deck (its slide texts), the files the PM added. Taken whole; when they do not fit
     their share they are compressed by sections (every heading kept), never cut at the tail.
  1. state: the project config, the decisions snapshot, the Current State page, the 14-day digest (each capped).
  2. series: the previous calls of this meeting (the caller adds them; localprep writes notes from them).
  3. related: folder files dated in the last 14 days (date in the name first, else the file's time) or naming the
     call (title, people, words of the call context), the best match first.
  4. the rest of the folder, by match and then by date, newest first.
  never: archived and hidden folders, prep runs, generated call files (transcripts, logs, tips), binaries.

  python -m livetips_m0.prepcontext --request <request.json> [--read <read.json>]
prints the manifest (for the Claude ways: the candidates, marked read / not read from the files Claude opened).
"""
import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Characters, not bytes: Cyrillic is two bytes a letter but about the same tokens per character as Latin.
BUDGETS = {"local": 120_000, "codex": 280_000, "openai": 280_000, "gemini": 280_000, "agy": 280_000}
PINNED_SHARE = 0.55          # the pinned sources may take up to this share of the budget before they are compressed
FOLDER_FILE_CAP = 12_000     # one folder file at most (compressed by sections above it)
STATE_CAPS = {"config": 14_000, "decisions": 6_000, "current_state": 12_000, "digest": 8_000}
FRESH_DAYS = 14
TEXT_EXT = (".md", ".txt", ".docx", ".csv", ".rtf", ".odt", ".pages")
EXCLUDE_DIRS = {"_archived", "_archive", "archive", "archived", "prep-runs", "node_modules", "__pycache__",
                "_to_delete", "decks", "google"}
GENERATED = re.compile(r"\.(app\.md|named\.md|clean\.md|timing\.jsonl|tips\.jsonl|semantic\.jsonl|meet\.md|"
                       r"brief\.md|brief\.prev\.md|brief\.orig\.md|digest\.md)$|^prep-", re.I)
DATE_IN_NAME = re.compile(r"(20\d\d)-(\d\d)-(\d\d)")
STOP = set("""що як для або але при про над під між цей цього цієї ці його її їх ми ви вони він вона воно так ні також
вже ще лише тільки дуже буде було бути має треба можна котрий який яка яке які коли де там тут теж the and for with
from that this these those into about call meeting what when where which who will would should could have has had
are was were been being not only also very just more most some any each other than then them they their there here
""".split())


def read_text(p: str) -> str:
    """The whole text of a file (.docx and the like through textutil on a Mac); "" when unreadable."""
    try:
        if p.lower().endswith((".docx", ".doc", ".rtf", ".odt", ".pages")):
            r = subprocess.run(["textutil", "-convert", "txt", "-stdout", p], capture_output=True, text=True, timeout=30)
            return r.stdout
        return Path(p).read_text(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        return ""


def words(text: str) -> set:
    return {w for w in re.findall(r"[\w'’]{4,}", (text or "").lower()) if w not in STOP and not w.isdigit()}


def file_date(path: str) -> _dt.date:
    """The date in the file name (the Notion mirror writes every file at sync time), else the file's time."""
    m = DATE_IN_NAME.search(os.path.basename(path))
    if m:
        try:
            return _dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            pass
    try:
        return _dt.date.fromtimestamp(os.path.getmtime(path))
    except OSError:
        return _dt.date(1970, 1, 1)


def compress(text: str, limit: int, path: str = "") -> Tuple[str, bool]:
    """Fit text into limit characters by sections: every markdown heading stays, each section keeps its share from
    its start. A visible mark says what was done. Returns (text, compressed)."""
    if len(text) <= limit:
        return text, False
    mark = (f"[Compressed by Pacenote: {limit:,} of {len(text):,} characters; every section is kept and shortened "
            f"at its end{'; the full file: ' + path if path else ''}]\n")
    room = max(200, limit - len(mark))
    parts = re.split(r"(?m)^(?=#{1,6}\s)", text)
    parts = [p for p in parts if p]
    if len(parts) < 2:                                   # no headings: the start and the end
        head = room * 2 // 3
        return mark + text[:head] + "\n[...]\n" + text[-(room - head - 7):], True
    heads = [p.split("\n", 1)[0] + "\n" for p in parts]
    bodies = [p[len(h):] for p, h in zip(parts, heads)]
    left = room - sum(len(h) for h in heads) - 6 * len(parts)
    if left <= 0:
        return mark + "".join(heads)[:room], True
    total = sum(len(b) for b in bodies) or 1
    out = []
    for h, b in zip(heads, bodies):
        share = int(left * len(b) / total)
        out.append(h + (b if len(b) <= share else b[:share].rsplit(" ", 1)[0] + " […]\n"))
    return mark + "".join(out), True


def deck_text(deck_path: str) -> str:
    """The deck read by the app (<base>.deck.json): one block per slide with its number, title and text."""
    try:
        o = json.loads(Path(deck_path).read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return ""
    out = []
    for s in o.get("slides") or []:
        if isinstance(s, dict):
            notes = (s.get("notes") or "").strip()      # 0.9.7: the PowerPoint speaker notes, when the deck has them
            out.append(f"Slide {s.get('n', '?')}: {s.get('title', '')}\n{(s.get('text') or '').strip()}"
                       + (f"\nSpeaker notes: {notes}" if notes else ""))
    return "\n\n".join(out)


class Item(dict):
    """One manifest entry: path, label, kind, tier, chars (the source), taken (characters in the pack), status
    (full | compressed | skipped_budget | excluded | read | not_read), reason."""


def _excluded_reason(root: str, name: str, is_dir: bool) -> Optional[str]:
    if name.startswith("."):
        return "hidden"
    low = name.lower()
    if is_dir:
        if low in EXCLUDE_DIRS:
            return "archived" if "arch" in low else "generated"
        return None
    if GENERATED.search(name):
        return "generated call file"
    if not low.endswith(TEXT_EXT):
        return "not a text document"
    return None


def folder_candidates(folders: List[str], keys: set, today: _dt.date, skip: set) -> Tuple[List[Item], Dict[str, list]]:
    """Every text file of the folders the PM added, scored; and the excluded ones grouped by reason."""
    cands, excluded = [], {}
    for d in folders:
        for root, dirs, files in os.walk(d):
            keep = []
            for x in sorted(dirs):
                why = _excluded_reason(root, x, True)
                if why:
                    excluded.setdefault(why, []).append(os.path.join(root, x) + "/")
                else:
                    keep.append(x)
            dirs[:] = keep
            for f in sorted(files):
                p = os.path.join(root, f)
                if p in skip:
                    continue
                why = _excluded_reason(root, f, False)
                if why:
                    if why != "not a text document" or not f.startswith("."):
                        excluded.setdefault(why, []).append(p)
                    continue
                dt = file_date(p)
                age = (today - dt).days
                name_hits = len(keys & words(os.path.splitext(f)[0]))
                cands.append(Item(path=p, label="Folder the PM added: " + p, kind="folder_file", date=dt.isoformat(),
                                  age_days=age, name_hits=name_hits))
    return cands, excluded


VERSION = re.compile(r"[-_ ]v(\d+)(?=[-_ .])", re.I)


def drop_old_versions(cands: List[Item], excluded: Dict[str, list]) -> List[Item]:
    """speech-v2-... and speech-v3-... in one folder: only the highest version is a candidate (no v = 1). Only names
    that carry a version count, so dated notes of a series ("2026-11-02 Sync", "2026-11-10 Sync") are never merged."""
    best: Dict[Tuple[str, str], int] = {}
    def key(c):
        name = os.path.basename(c["path"])
        m = VERSION.search(name)
        stem = DATE_IN_NAME.sub("", VERSION.sub("", name))      # v2 of 02.11 and v3 of 08.11 are one document
        return (os.path.dirname(c["path"]), stem), int(m.group(1)) if m else 1
    versioned = {key(c)[0] for c in cands if VERSION.search(os.path.basename(c["path"]))}
    for c in cands:
        k, v = key(c)
        best[k] = max(best.get(k, 0), v)
    out = []
    for c in cands:
        k, v = key(c)
        if k in versioned and v < best[k]:
            excluded.setdefault("older version", []).append(c["path"])
        else:
            out.append(c)
    return out


def rank(cands: List[Item], keys: set) -> List[Item]:
    """Tier 3 (dated in the last 14 days, or the name names the call) before tier 4; inside, the best match, then
    the newest. The content is read once here (the first 6 000 characters count for the match)."""
    for c in cands:
        text = read_text(c["path"])
        c["_text"] = text
        c["chars"] = len(text)
        hits = c["name_hits"] * 3 + len(keys & words(text[:6000]))
        c["score"] = hits
        fresh = c["age_days"] <= FRESH_DAYS
        c["tier"] = 3 if (fresh or c["name_hits"] >= 2 or hits >= 8) else 4
        c["reason"] = ", ".join(x for x in [f"dated {c['date']}" if fresh else "",
                                            f"matches the call ({hits})" if hits else ""] if x) or "rest of the folder"
    return sorted([c for c in cands if c["chars"] > 0],
                  key=lambda c: (c["tier"], -c["score"], -_dt.date.fromisoformat(c["date"]).toordinal()))


def call_keys(r: dict) -> set:
    return words(" ".join([r.get("title") or "", r.get("context") or "", " ".join(r.get("participants") or [])]))


def build(r: dict, previous: Optional[List[Tuple[str, str]]] = None, route: str = "local") -> Tuple[str, List[str], List[Item], dict]:
    """The pack, the labels used (the old `sources`), the manifest and a summary.
    previous: [(label, text)] of the previous calls (tier 2) the caller wants in the pack."""
    budget = int(r.get("pack_chars") or BUDGETS.get(route, BUDGETS["local"]))
    today = _dt.date.fromisoformat(r["today"]) if r.get("today") else _dt.date.today()
    keys = call_keys(r)
    blocks, used, manifest = [], [], []
    left = budget

    def put(item: Item, text: str, limit: int) -> None:
        nonlocal left
        item["chars"] = item.get("chars") or len(text)
        if not text.strip():
            return
        room = min(limit, left)
        if room < min(1500, len(text)):          # a small source that fits is always taken
            item.update(status="skipped_budget", taken=0)
            manifest.append(item)
            return
        body, squeezed = compress(text, room, item.get("path", ""))
        blocks.append(f"### {item['label']}\n{body}")
        used.append(item["label"])
        left -= len(body)
        item.update(status="compressed" if squeezed else "full", taken=len(body))
        manifest.append(item)

    # 0. pinned
    pinned: List[Tuple[Item, str]] = []
    if (r.get("context") or "").strip():
        pinned.append((Item(label="Call context written by the PM", kind="context", tier=0, reason="pinned"), r["context"]))
    if r.get("deck"):
        dt = deck_text(r["deck"])
        info = (r.get("deck_lines") or "").strip()
        if dt:
            pinned.append((Item(path=r["deck"], label="The deck attached to the call (slide texts)", kind="deck",
                                tier=0, reason="pinned"), (info + "\n\n" if info else "") + dt))
    files = [f for f in (r.get("files") or [])]
    for f in files:
        pinned.append((Item(path=f, label="File the PM added: " + f, kind="file", tier=0, reason="pinned"), read_text(f)))
    share = int(budget * PINNED_SHARE)
    need = sum(len(t) for _, t in pinned)
    if need <= share:
        for it, t in pinned:
            put(it, t, len(t))
    else:                                   # the largest give way first, the small ones stay whole
        caps, rest, n = {}, share, len(pinned)
        for i, (it, t) in sorted(enumerate(pinned), key=lambda x: len(x[1][1])):
            fair = rest // max(1, n)
            caps[i] = min(len(t), fair) if len(t) > fair else len(t)
            rest -= caps[i]
            n -= 1
        for i, (it, t) in enumerate(pinned):
            put(it, t, caps[i])

    # 1. state
    if r.get("config"):
        put(Item(path=r["config"], label="Project config: " + r["config"], kind="config", tier=1, reason="project state"),
            read_text(r["config"]), STATE_CAPS["config"])
    root = r.get("root") or ""
    dec = os.path.join(root, "pacenote", "decisions.md") if root else ""
    use_project = r.get("use_project_folder", True)
    if use_project and dec and os.path.exists(dec):
        put(Item(path=dec, label="Active decisions: " + dec, kind="decisions", tier=1, reason="project state"),
            read_text(dec), STATE_CAPS["decisions"])
    if use_project:
        for p in current_state(r.get("notion") or []):
            put(Item(path=p, label="Notion mirror: " + os.path.basename(p), kind="current_state", tier=1,
                     reason="project state"), read_text(p), STATE_CAPS["current_state"])
        if r.get("lt") and root:
            try:
                d = subprocess.run(r["lt"] + ["digest", root, "--days", "14", "--max-chars", str(STATE_CAPS["digest"])],
                                   capture_output=True, text=True, timeout=60)
                put(Item(label="Digest of the last 14 days (lt digest)", kind="digest", tier=1, reason="project state"),
                    d.stdout, STATE_CAPS["digest"])
            except Exception:  # noqa: BLE001
                pass

    # 2. series
    for label, text in previous or []:
        put(Item(label=label, kind="previous_call", tier=2, reason="same meeting"), text, 25_000)

    # 3-4. the folders the PM added
    skip = {it.get("path") for it, _ in pinned} | {m.get("path") for m in manifest}
    cands, excluded = folder_candidates(r.get("folders") or [], keys, today, skip)
    for c in rank(drop_old_versions(cands, excluded), keys):
        text = c.pop("_text", "")
        for k in ("name_hits", "age_days"):
            c.pop(k, None)
        put(c, text, FOLDER_FILE_CAP)
    for why, paths in sorted(excluded.items()):
        manifest.append(Item(kind="excluded", status="excluded", reason=why, count=len(paths), examples=paths[:8]))
    return "\n\n".join(blocks), used, manifest, summarize(manifest, budget, r)


def current_state(notion_dirs: List[str]) -> List[str]:
    hits = []
    for d in notion_dirs:
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if not x.startswith(".") and x.lower() not in EXCLUDE_DIRS]
            for f in files:
                if f.endswith(".md") and "current state" in f.lower().replace("-", " ").replace("_", " "):
                    hits.append(os.path.join(root, f))
    return sorted(hits, key=lambda p: -os.path.getmtime(p))[:2]


def summarize(manifest: List[Item], budget: int, r: dict) -> dict:
    """Counts and warnings for prep.json and the brief's context line."""
    st = {}
    for m in manifest:
        if m.get("kind") == "excluded":
            st["excluded"] = st.get("excluded", 0) + int(m.get("count") or 0)
        else:
            st[m.get("status", "")] = st.get(m.get("status", ""), 0) + 1
    warn = []
    for m in manifest:
        if m.get("kind") in ("file", "deck", "context") and m.get("status") in ("compressed", "skipped_budget"):
            warn.append({"kind": "pinned_" + m["status"], "path": m.get("path") or m.get("label"),
                         "taken": m.get("taken", 0), "chars": m.get("chars", 0)})
    fresh = [m for m in manifest if m.get("kind") == "folder_file" and m.get("status") in ("skipped_budget", "not_read")
             and m.get("tier") == 3 and m.get("reason", "").startswith("dated")]
    if fresh:     # a recent file that matches the call and did not make it: the PM should know
        warn.append({"kind": "fresh_skipped", "count": len(fresh), "examples": [m["path"] for m in fresh[:5]]})
    deck_used = any(m.get("kind") == "deck" and m.get("status") in ("full", "compressed", "read") for m in manifest)
    if (r.get("call_type") == "presentation" or r.get("deck")) and not deck_used:
        warn.append({"kind": "deck_missing"})
    return {"budget_chars": budget, "counts": st, "deck_used": deck_used, "warnings": warn}


def summary_line(summary: dict, lang: str = "en") -> str:
    """One line for the top of the brief: what the preparation read and what it did not."""
    c = summary.get("counts", {})
    uk = lang.startswith("uk") or lang == "Ukrainian"
    parts = []
    lab = (("повністю", "стиснуто", "пропущено (бюджет)", "виключено фільтром", "прочитано", "не прочитано") if uk else
           ("in full", "compressed", "skipped (budget)", "excluded by filters", "read", "not read"))
    for k, name in zip(("full", "compressed", "skipped_budget", "excluded", "read", "not_read"), lab):
        if c.get(k):
            parts.append(f"{c[k]} {name}")
    deck = ("дек: використано" if summary.get("deck_used") else "дек: не використано") if uk else \
           ("deck: used" if summary.get("deck_used") else "deck: not used")
    line = ("Контекст підготовки: " if uk else "Preparation context: ") + ", ".join(parts + [deck]) + "."
    for w in summary.get("warnings", []):
        name = os.path.basename(str(w.get("path", "")))
        if w["kind"] == "pinned_compressed":
            line += (f" ⚠️ Доданий файл {name} стиснуто: {w['taken']:,} з {w['chars']:,} символів." if uk else
                     f" ⚠️ The file you added, {name}, was compressed: {w['taken']:,} of {w['chars']:,} characters.")
        elif w["kind"] == "pinned_skipped_budget":
            line += f" ⚠️ Доданий файл {name} не вліз." if uk else f" ⚠️ The file you added, {name}, did not fit."
        elif w["kind"] == "fresh_skipped":
            ex = ", ".join(os.path.basename(x) for x in w["examples"][:3])
            line += (f" ⚠️ Не взято {w['count']} свіжих файлів про цей дзвінок (за 14 днів): {ex}." if uk else
                     f" ⚠️ {w['count']} recent files about this call (last 14 days) did not fit: {ex}.")
        elif w["kind"] == "pinned_not_read":
            line += f" ⚠️ Доданий файл {name} не відкрито." if uk else f" ⚠️ The file you added, {name}, was not opened."
        elif w["kind"] == "deck_missing":
            line += " ⚠️ Дек не потрапив у підготовку." if uk else " ⚠️ The deck did not reach the preparation."
    return line


def with_line(brief: str, line: str) -> str:
    """The context line goes right under the brief's first line (its title), where the PM looks first."""
    if not line:
        return brief
    head, _, rest = brief.partition("\n")
    return head + "\n\n> " + line + "\n" + (rest if rest.startswith("\n") else "\n" + rest)


def write_context(base: str, manifest: List[Item], summary: dict) -> None:
    """<base>.context.json: the whole manifest (prep.json keeps only the summary, the ledger nothing)."""
    try:
        Path(base + ".context.json").write_text(json.dumps({"summary": summary, "manifest": manifest}, ensure_ascii=False,
                                                           indent=1, default=str), encoding="utf-8")
    except OSError:
        pass


def mark_read(r: dict, read: List[str]) -> Tuple[List[Item], dict]:
    """The Claude ways read by themselves: the same candidates, marked read / not read from what Claude opened."""
    names = {os.path.basename(x) for x in read} | set(read)
    def was(p: str) -> bool:
        return p in names or os.path.basename(p) in names
    keys = call_keys(r)
    today = _dt.date.fromisoformat(r["today"]) if r.get("today") else _dt.date.today()
    manifest: List[Item] = []
    if r.get("deck"):
        manifest.append(Item(path=r["deck"], label="The deck", kind="deck", tier=0, status="read" if was(r["deck"]) else "not_read"))
    for f in r.get("files") or []:
        manifest.append(Item(path=f, label="File the PM added: " + f, kind="file", tier=0,
                             status="read" if was(f) else "not_read"))
    cands, excluded = folder_candidates(r.get("folders") or [], keys, today, set(r.get("files") or []))
    for c in rank(drop_old_versions(cands, excluded), keys):
        c.pop("_text", None); c.pop("name_hits", None); c.pop("age_days", None)
        c["status"] = "read" if was(c["path"]) else "not_read"
        manifest.append(c)
    for why, paths in sorted(excluded.items()):
        manifest.append(Item(kind="excluded", status="excluded", reason=why, count=len(paths), examples=paths[:8]))
    s = summarize(manifest, 0, r)
    # a file the PM added that Claude never opened is the same failure as a compressed one
    for m in manifest:
        if m.get("kind") in ("file", "deck") and m["status"] == "not_read":
            s["warnings"].append({"kind": "pinned_not_read", "path": m["path"]})
    return manifest, s


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    ap.add_argument("--read", help="a JSON list of the files Claude read (the plan / api ways)")
    ap.add_argument("--route", default="local")
    ap.add_argument("--write", action="store_true", help="write <base>.context.json and the line into <base>.brief.md")
    a = ap.parse_args(argv)
    r = json.loads(Path(a.request).read_text(encoding="utf-8"))
    if a.read:
        read = json.loads(Path(a.read).read_text(encoding="utf-8"))
        manifest, s = mark_read(r, read)
    else:
        _, _, manifest, s = build(r, route=a.route)
    line = summary_line(s, r.get("brief_lang") or "en")
    if a.write and r.get("base"):
        write_context(r["base"], manifest, s)
        bp = Path(r["base"] + ".brief.md")
        if bp.exists():
            t = bp.read_text(encoding="utf-8")
            if line not in t:
                bp.write_text(with_line(t, line), encoding="utf-8")
        print(json.dumps({"summary": s, "line": line}, ensure_ascii=False, default=str))
    else:
        print(json.dumps({"manifest": manifest, "summary": s, "line": line}, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
