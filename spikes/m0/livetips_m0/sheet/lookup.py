"""0.10.0 (Meeting Sheet, phase 7): the search during a call, shared by every AI way.

PM (12.11): "the point of folder search is to find info on the fly that did not get into the prep; I never saw it
work, it must work; do not tie it to Claude". This module searches, on the Mac, with no model and no Ollama:
  - the Meeting Sheet's facts (each with its source number "[2]"),
  - the files the sheet was built from (sources with a path),
  - the project folder and the folders added to the call (notes, earlier transcripts in live/, _notion/, specs).
It ranks passages by BM25 over word stems (Ukrainian and English endings share a 5-letter stem), with a small
bonus for words in the file name or heading and for newer files. The tips model of ANY route then answers from
these passages (deep.local_lookup); Claude Code is not needed. Nothing leaves the Mac but the passages sent with
the question to the route the PM chose.

    snippets(question, sheet=None, roots=[...], k=8) -> [{"src", "path", "date", "text", "score", "n"}]

Read-only. Never raises (a bad file is skipped). Time-boxed (max_seconds) for a live call.
"""
from __future__ import annotations

import json
import math
import os
import re
import time
from pathlib import Path
from typing import Iterable, List, Optional

TEXT_EXT = {".md", ".txt", ".csv", ".json", ".yaml", ".yml", ".eml", ".html", ".htm", ".tsv", ".log", ".rst", ".org"}
SKIP_DIRS = {"node_modules", "__pycache__", "site-packages", "venv", ".venv", "build", "dist", "DerivedData"}
SKIP_SUFFIX = (".tips.jsonl", ".timing.jsonl", ".llm.jsonl", ".inbox.jsonl", ".fired.jsonl", ".semantic.jsonl",
               ".feedback.jsonl", ".speakers.json", ".status.json", ".semantic-summary.json", ".edits.jsonl",
               ".cards-fired.jsonl", ".sheet-live.json")
STOP = set("""the and for that this with you your are was were have has had will would could should can about from
what when where which who whom how why into there their they them then than just also only very does did doing done
been being any some much many more most our ours its it's not but all each other such here now today please tell know
let lets get got make made say said see seen need needs want right okay yes well like think thing things one two
але або щоб тому коли якщо тобто типу просто також треба можна буде було були який яка яке які цей цього цьому ця
це ці там тут вже ще дуже нам вам вони воно його йому її мені тебе тобі тоді хто що як чи скільки зараз де чому
наш наша наше наші ваш ваша ваше ваші""".split())
DATE_RX = re.compile(r"(20\d\d)-(\d\d)-(\d\d)")
WORD_RX = re.compile(r"[^\W_]+(?:['’][^\W_]+)?", re.U)


def stem(w: str) -> str:
    w = w.lower().replace("’", "'")
    if w.isdigit():
        return w
    return w[:5] if len(w) > 5 else w


def terms(text: str) -> List[str]:
    out = []
    for w in WORD_RX.findall(text or ""):
        lw = w.lower()
        if lw in STOP or (len(lw) < 3 and not lw.isdigit()):
            continue
        out.append(stem(lw))
    return out


# Common PM words across Ukrainian and English (and near synonyms), so a question in one language finds notes in the
# other without a model. Keys and values are stems (terms()); a query term adds its group.
SYN_GROUPS = [
    ["hours", "годин", "годи", "часу"], ["left", "remai", "лишил", "залиш"], ["budge", "бюдже", "cost", "price", "ціна", "варті"],
    ["deadl", "дедла", "термі", "due", "date", "дата", "коли"], ["relea", "реліз"], ["maint", "мейнт", "підтр", "suppo"],
    ["contr", "контр", "догов", "sow"], ["decis", "рішен", "decid", "виріш"], ["risk", "ризик"], ["team", "коман", "peopl", "emplo", "staff", "людей", "люди"],
    ["novem", "листо"], ["decem", "груде"], ["octob", "жовте"], ["janua", "січня", "січен"], ["sent", "send", "надіс", "відпр"],
    ["test", "тест"], ["bug", "баг", "defec"], ["sign", "підпи", "appro", "погод"], ["estim", "оцінк", "естім"],
    ["meeti", "зустр", "call", "дзвін"], ["clien", "клієн"], ["invoi", "рахун"], ["vacat", "відпу"], ["sla", "slа"],
    ["crash", "краш", "падін"], ["notes", "нотат"], ["scope", "обсяг", "скоуп"], ["pilot", "пілот"], ["produ", "прод"],
    ["guara", "гаран"], ["penal", "штраф"], ["loss", "втрат"], ["data", "дані", "даних"], ["old", "стари", "стара"],
]
SYN = {}
for _g in SYN_GROUPS:
    for _t in _g:
        SYN.setdefault(_t, set()).update(_g)


def expand(q_terms: List[str]) -> List[str]:
    out = list(q_terms)
    for t in q_terms:
        for x in sorted(SYN.get(t, ())):
            if x not in out:
                out.append(x)
    return out


def _date_of(path: Path, rel: str) -> str:
    m = DATE_RX.search(rel)
    if m:
        return m.group(0)
    try:
        return time.strftime("%Y-%m-%d", time.localtime(path.stat().st_mtime))
    except OSError:
        return ""


def chunks(text: str, width: int = 900) -> List[tuple]:
    """(heading, passage) windows: paragraphs merged up to `width` characters, the last heading kept with each."""
    out, head, buf = [], "", []
    size = 0

    def flush():
        nonlocal buf, size
        if buf:
            out.append((head, "\n".join(buf).strip()))
        buf, size = [], 0

    for para in re.split(r"\n\s*\n", text or ""):
        p = para.strip()
        if not p:
            continue
        first = p.splitlines()[0]
        if first.startswith("#"):
            flush()
            head = first.lstrip("# ").strip()[:120]
        if size + len(p) > width and buf:
            flush()
        while len(p) > width * 2:            # one huge paragraph (a transcript without blank lines)
            cut = p.rfind("\n", 0, width)
            cut = cut if cut > width // 3 else width
            buf.append(p[:cut])
            flush()
            p = p[cut:].strip()
        buf.append(p)
        size += len(p)
    flush()
    return [c for c in out if c[1]]


def _read(path: Path, max_bytes: int) -> str:
    try:
        if path.stat().st_size > max_bytes:
            with open(path, "rb") as f:
                raw = f.read(max_bytes)
            return raw.decode("utf-8", errors="replace")
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _jsonl_text(text: str) -> str:
    """A .json / .jsonl file as its string values (keys and brackets carry no words to find)."""
    vals = []

    def walk(x):
        if isinstance(x, str):
            vals.append(x)
        elif isinstance(x, dict):
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    try:
        walk(json.loads(text))
    except Exception:  # noqa: BLE001
        for ln in text.splitlines():
            try:
                walk(json.loads(ln))
            except Exception:  # noqa: BLE001
                continue
    return "\n\n".join(vals) if vals else text


def walk_files(root: Path, max_files: int = 4000, exclude_prefix: str = "") -> Iterable[Path]:
    n = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS
                             and not d.startswith("_to_delete"))
        for fn in sorted(filenames):
            if fn.startswith(".") or fn.endswith(SKIP_SUFFIX):
                continue
            if exclude_prefix and fn.startswith(exclude_prefix):
                continue
            p = Path(dirpath) / fn
            if p.suffix.lower() not in TEXT_EXT and not fn.endswith(".jsonl"):
                continue
            yield p
            n += 1
            if n >= max_files:
                return


def sheet_passages(sheet: Optional[dict]) -> List[dict]:
    """The sheet's facts as passages: "[n] label: text", src "Meeting Sheet [n]" (the source numbers of the sheet)."""
    if not isinstance(sheet, dict):
        return []
    srcs = {s.get("id"): s for s in sheet.get("sources") or [] if isinstance(s, dict)}
    out = []
    for b in sheet.get("blocks") or []:
        if not isinstance(b, dict):
            continue
        for f in b.get("facts") or []:
            if not isinstance(f, dict) or not str(f.get("text") or "").strip() or f.get("status") == "not_found":
                continue
            ns = [srcs[i].get("n") for i in f.get("source_ids") or [] if i in srcs and srcs[i].get("n") is not None]
            cite = "".join("[{}]".format(n) for n in dict.fromkeys(ns))
            label = str(f.get("label") or b.get("title") or b.get("type") or "")
            text = "{}: {} {}".format(label, f.get("text"), cite).strip() if label else "{} {}".format(f.get("text"), cite)
            out.append({"src": "Meeting Sheet " + (cite or "(" + str(b.get("title") or b.get("type")) + ")"),
                        "path": "", "date": str(f.get("checked_at") or "")[:10], "head": label, "text": text,
                        "n": ns[0] if ns else None})
    return out


def sheet_source_paths(sheet: Optional[dict]) -> List[tuple]:
    """(path, number, title) of the sheet's sources that are files on this Mac."""
    out = []
    if not isinstance(sheet, dict):
        return out
    for s in sheet.get("sources") or []:
        if not isinstance(s, dict) or s.get("access") in ("denied", "unsupported"):
            continue
        p = s.get("path") or ""
        if p:
            pp = Path(os.path.expanduser(str(p)))
            if pp.is_file():
                out.append((pp, s.get("n"), str(s.get("title") or pp.name)))
    return out


def collect(question: str, sheet=None, roots=(), max_files: int = 4000, max_bytes: int = 400_000,
            max_seconds: float = 3.0, exclude_prefix: str = "") -> List[dict]:
    """Every passage to rank: sheet facts, sheet source files, then the folders (newest first is not needed: BM25)."""
    t0 = time.time()
    docs = sheet_passages(sheet)
    seen = set()
    for pp, n, title in sheet_source_paths(sheet):
        seen.add(str(pp.resolve()))
        text = _read(pp, max_bytes)
        if pp.suffix.lower() in (".json", ".jsonl"):
            text = _jsonl_text(text)
        for head, body in chunks(text):
            docs.append({"src": "[{}] {}".format(n, title) if n is not None else title, "path": str(pp),
                         "date": _date_of(pp, pp.name), "head": head, "text": body, "n": n})
    for r in roots:
        root = Path(os.path.expanduser(str(r)))
        if not root.is_dir():
            continue
        for pp in walk_files(root, max_files, exclude_prefix):
            if time.time() - t0 > max_seconds:
                break
            key = str(pp.resolve())
            if key in seen:
                continue
            seen.add(key)
            text = _read(pp, max_bytes)
            if not text.strip():
                continue
            if pp.suffix.lower() in (".json", ".jsonl") or pp.name.endswith(".jsonl"):
                text = _jsonl_text(text)
            try:
                rel = str(pp.relative_to(root))
            except ValueError:
                rel = pp.name
            date = _date_of(pp, rel)
            for head, body in chunks(text):
                docs.append({"src": rel, "path": str(pp), "date": date, "head": head, "text": body, "n": None})
    return docs


def rank(question: str, docs: List[dict], k: int = 8, k1: float = 1.4, b: float = 0.7) -> List[dict]:
    base_q = list(dict.fromkeys(terms(question)))
    if not base_q or not docs:
        return []
    q = expand(base_q)
    toks = [terms(d["text"]) for d in docs]
    meta = [set(terms(d.get("src", "") + " " + d.get("head", ""))) for d in docs]
    n = len(docs)
    avg = sum(len(t) for t in toks) / max(1, n)
    df = {t: 0 for t in q}
    for tt in toks:
        s = set(tt)
        for t in q:
            if t in s:
                df[t] += 1
    idf = {t: math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5)) for t in q}
    dates = sorted({d.get("date") or "" for d in docs if d.get("date")})
    newest = {dd: i / max(1, len(dates) - 1) for i, dd in enumerate(dates)}
    scored = []
    for d, tt, mm in zip(docs, toks, meta):
        if not tt:
            continue
        tf = {}
        for t in tt:
            if t in idf:
                tf[t] = tf.get(t, 0) + 1
        if not tf:
            continue
        s = 0.0
        for t, f in tf.items():
            s += idf[t] * f * (k1 + 1) / (f + k1 * (1 - b + b * len(tt) / avg))
        s += 0.35 * sum(idf[t] for t in q if t in mm)             # words in the file name or heading
        s *= 1 + 0.25 * min(1.0, len(tf) / len(base_q))            # more of the question's words, better
        s += 0.15 * newest.get(d.get("date") or "", 0)             # newer facts win ties
        if d["src"].startswith("Meeting Sheet"):
            s += 0.2                                               # the checked sheet first among equals
        scored.append((s, d))
    scored.sort(key=lambda x: -x[0])
    out, per_file = [], {}
    for s, d in scored:
        key = d.get("path") or d["src"]
        if per_file.get(key, 0) >= 2:                              # at most two passages of one file
            continue
        per_file[key] = per_file.get(key, 0) + 1
        out.append(dict(d, score=round(s, 3)))
        if len(out) >= k:
            break
    return out


def snippets(question: str, sheet=None, roots=(), k: int = 8, queries=(), budget_chars: int = 14000,
             max_seconds: float = 3.0, exclude_prefix: str = "") -> List[dict]:
    """The best passages for the question (and extra queries, e.g. from the model), within the character budget.
    Shape fits engine.passages(): src, date, text (+ path, score, n)."""
    docs = collect(question, sheet, roots, max_seconds=max_seconds, exclude_prefix=exclude_prefix)
    merged, seen = [], set()
    for q in [question] + [x for x in queries if x and x != question]:
        for h in rank(q, docs, k=k * 3):
            key = (h.get("path") or h["src"], h["text"][:60])
            if key in seen:
                continue
            seen.add(key)
            merged.append(h)
    merged.sort(key=lambda h: -h["score"])
    # the sheet holds what the prep found; the folder search is for what it did not: the sheet's short facts never
    # take more than half of the places
    cap, n_sheet, rest = max(2, k // 2), 0, []
    for h in merged:
        if h["src"].startswith("Meeting Sheet"):
            n_sheet += 1
            if n_sheet > cap:
                continue
        rest.append(h)
    out, used = [], 0
    for h in rest:
        body = (h.get("head") + "\n" if h.get("head") and not h["text"].startswith(h["head"]) else "") + h["text"]
        body = body[:1800]
        if used + len(body) > budget_chars:
            continue
        used += len(body)
        out.append({"src": h["src"], "path": h.get("path", ""), "date": h.get("date", ""), "text": body,
                    "score": h["score"], "n": h.get("n")})
        if len(out) >= k:
            break
    return out


def load_sheet_near(brief_path) -> Optional[dict]:
    """The call's sheet next to its brief (<base>.brief.md -> <base>.sheet.json), or None."""
    if not brief_path:
        return None
    p = Path(str(brief_path))
    name = p.name
    if name.endswith(".brief.md"):
        p = p.with_name(name[: -len(".brief.md")] + ".sheet.json")
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None
    return data if isinstance(data, dict) and str(data.get("schema", "")).startswith("pacenote.sheet/") else None
