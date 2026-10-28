"""Call memory (Pacenote 0.8, F6, idea 05): a question in plain words over every transcript of one project.

The project's own local index (lt search: bge-m3 with Local AI on, text search otherwise) finds the passages; a plain
word match over the transcripts in <project>/live/ fills in when the index has none. Claude answers in 1-2 sentences
with one quote and the moment it was said. Only this project's folder is read (never another project's).

  python -m livetips_m0.memory --root <project folder> --q "<question>" [--lt <python> <lt>] [--model ...]
Prints JSON {"ok", "answer", "quote", "file", "t", "title", "date", "found"}.
"""
import argparse
import re
from pathlib import Path
from typing import List, Optional

from . import callinfo
from .context import index_snippets
from .oneshot import ask_json, emit

WORD = re.compile(r"[^\W_]{3,}", re.U)
CALL_MD = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d{4})-.+\.md$")

SYSTEM = """You answer a project manager's question about their own past calls, from transcript passages of ONE project.
Answer in {LANG}, 1-2 short sentences, plain words, no long dashes. Use only the passages; never invent.
Return JSON only: {{"answer": "...", "quote": "<the most relevant words exactly as in a passage, max 25 words>",
"passage": <number of that passage>, "found": true|false}}. When the passages do not answer, found = false and the
answer says what is missing."""


def transcripts(root: Path) -> List[Path]:
    live = root / "live"
    if not live.is_dir():
        return []
    files = [p for p in live.iterdir() if CALL_MD.match(p.name)]
    seen, out = set(), []
    for p in sorted(files, key=lambda x: x.name, reverse=True):          # newest first; the app's and the skill's once
        key = p.name.replace(".app.md", ".md")
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


def word_passages(root: Path, q: str, k: int = 8, window: int = 6) -> List[dict]:
    terms = {w.lower() for w in WORD.findall(q)}
    if not terms:
        return []
    scored = []
    for md in transcripts(root)[:80]:
        ls = callinfo.lines(md, 200000)
        for i in range(0, len(ls), window // 2 or 1):
            chunk = ls[i:i + window]
            text = " ".join(l["text"] for l in chunk).lower()
            s = sum(text.count(t) for t in terms) + 2 * sum(1 for t in terms if t in text)
            if s:
                scored.append((s, md, chunk))
    scored.sort(key=lambda x: -x[0])
    return [{"file": md, "t": ch[0]["t"], "text": "\n".join("[{}] {}: {}".format(l["t"], l["who"], l["text"]) for l in ch)}
            for _, md, ch in scored[:k]]


def index_passages(root: Path, q: str, lt: List[str], k: int = 8) -> List[dict]:
    out = []
    for h in index_snippets(lt, root, q, k=k * 2, timeout=25.0):
        p = call_file(root, h.get("path"))
        if p is None:
            continue                                             # transcripts only
        prev = str(h.get("preview") or h.get("text") or "")
        out.append({"file": p, "t": moment(p, lambda text: bool(text) and text[:40] in prev), "text": prev[:1500]})
        if len(out) >= k:
            break
    return out


def call_file(root: Path, path) -> Optional[Path]:
    """The index hit's file when it is a call transcript in <project>/live/, else None."""
    p = Path(str(path or ""))
    if not p.is_absolute():
        p = root / p
    return p if p.parent.name == "live" and CALL_MD.match(p.name) else None


def moment(md: Path, match, default: str = "") -> str:
    """The time of the first transcript line whose text matches."""
    return next((l["t"] for l in callinfo.lines(md, 400000) if match(l["text"])), default)


def gather(root: Path, q: str, lt=None) -> List[dict]:
    """Index passages first, word matches fill in up to 8."""
    ps = index_passages(root, q, lt or []) if lt else []
    seen = {(str(p["file"]), p["t"]) for p in ps}
    for p in word_passages(root, q):
        if (str(p["file"]), p["t"]) not in seen and len(ps) < 8:
            ps.append(p)
    return ps


def passages_prompt(q: str, ps: List[dict]) -> str:
    return "QUESTION: " + q + "\n\n" + "\n\n".join(
        "PASSAGE {} (call \"{}\", {}):\n{}".format(i, callinfo.header(p["file"])["title"], p["file"].name[:10], p["text"])
        for i, p in enumerate(ps))


def best_passage(ps: List[dict], obj: dict) -> dict:
    try:
        return ps[int(obj.get("passage", 0))]
    except (TypeError, ValueError, IndexError):
        return ps[0]


NOT_FOUND = {"ok": True, "found": False, "answer": "", "quote": "", "file": "", "t": "", "title": "", "date": ""}


def ask(root: Path, q: str, lt=None, model: str = "claude-haiku-5-5", lang: str = "uk", provider=None) -> dict:
    ps = gather(root, q, lt)
    if not ps:
        return dict(NOT_FOUND)
    obj, usd = ask_json(SYSTEM.format(LANG="Ukrainian" if lang == "uk" else "English"), passages_prompt(q, ps), model, 600, provider)
    obj = obj or {}
    best = best_passage(ps, obj)
    quote = str(obj.get("quote") or "")
    t = best["t"]
    if quote:                                                    # the moment of the quote, when it is a real line
        t = moment(best["file"], lambda text: quote[:30].lower() in text.lower(), t)
    return {"ok": True, "found": bool(obj.get("found", True)), "answer": str(obj.get("answer") or "").replace(chr(0x2014), "-"),
            "quote": quote, "file": str(best["file"]), "t": t, "title": callinfo.header(best["file"])["title"],
            "date": best["file"].name[:10], "cost_usd": usd}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, type=Path)
    ap.add_argument("--q", required=True)
    ap.add_argument("--lt", nargs=2)
    ap.add_argument("--model", default="claude-haiku-5-5")
    ap.add_argument("--lang", default="uk")
    a = ap.parse_args(argv)
    try:
        emit(ask(a.root, a.q, list(a.lt) if a.lt else None, a.model, a.lang))
    except Exception as e:  # noqa: BLE001
        emit({"ok": False, "error": str(e)[:300]})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
