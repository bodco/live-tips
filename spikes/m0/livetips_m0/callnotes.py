"""Pacenote 0.8.5 (owner: "summaries that never drop details, so the context is not lost"): full notes of one call,
written once after the call, which later preparations read instead of the whole transcript (rules/notes.yaml).

  python -m livetips_m0.callnotes --md <transcript.md> [--model claude-sonnet-5-5] [--lang uk]

Writes <stem>.notes.md next to the transcript. Two guards against lost details:
1. The transcript is read in parts (about 25,000 characters each, on line breaks), each part gets its notes, then
   one pass merges them by topic.
2. A coverage check: every number, date, time, ticket key, domain or address, and every question of the call is
   looked up in the notes; the missing ones go back to the model with their transcript lines, and it adds them
   where they belong. The notes end with the coverage line ("Coverage: numbers 41/42, keys 6/6, questions 14/15").
Prints one JSON line {"ok", "path", "coverage", "cost_usd", "error"}.
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import List

PART_CHARS = 25_000
LANGS = {"uk": "Ukrainian", "en": "English"}

PART_SYS = """You take notes of one part of a work call for the project manager (the PM, "Я" or "Me" in the transcript).
These notes replace the transcript for later preparations, so nothing that matters may be lost. Write in {LANG};
keep quotes, names, product and ticket names, numbers, dates, times and addresses exactly as said (quotes in the
original language). Speech recognition garbles names: keep the spelling and add the likely name in brackets.
Speaker labels can be wrong. Never invent. No long dashes. Use these headings:
### Topics
For every topic: who said what (by name), the numbers and dates, what was decided or left open, 1-3 short quotes.
### Questions
Every question: who asked whom, the answer (fully / partly / not answered) and what exactly was answered.
### Decisions
### Action items
Owner: what, by when (as said).
### Promises
Ours (the PM's team) and theirs, with dates.
### Concerns and mood
### Facts and numbers
Every number, date, time, estimate, price, ticket key, domain, address, version said in this part, one line each,
with what it refers to."""

MERGE_SYS = """You merge the notes of the parts of one work call into the call's full notes. Keep every detail of every
part (numbers, dates, names, quotes, questions and their answers): merging means grouping by topic and removing
exact repeats, never shortening. Write in {LANG}. No long dashes. Start with:
# Call notes: {TITLE}
Date and time, length, participants (with sides when known).
## Summary
5-8 lines: what the call was about and what came out of it.
Then these sections: ## Topics, ## Questions, ## Decisions, ## Action items, ## Promises, ## Concerns and mood,
## Open after the call, ## Facts and numbers."""

FIX_SYS = """These details of the call are missing from its notes. Add each one where it belongs in the notes (the
right topic, question, action item or the Facts and numbers list), with what it refers to, using the transcript
lines given. Change nothing else. Answer with the full notes. Write in {LANG}. No long dashes."""


def parts(text: str, size: int = PART_CHARS) -> List[str]:
    out, cur = [], []
    n = 0
    for line in text.splitlines(keepends=True):
        if n + len(line) > size and cur:
            out.append("".join(cur)); cur, n = [], 0
        cur.append(line); n += len(line)
    if cur:
        out.append("".join(cur))
    return out


LINE = re.compile(r"^\[(\d\d:\d\d:\d\d)\]\s+([^:(\[]+?)(?:\s*\[S\d+\])?(?:\s*\([\w+-]+\))?:\s*(.*)$")
KEY = re.compile(r"\b[A-Z][A-Z0-9]{1,9}-\d{1,6}\b")
NUM = re.compile(r"(?<![\w.])\d+(?:[.,:]\d+)*(?:\s?%)?")
ADDR = re.compile(r"\b[\w-]+(?:\.[\w-]+)*\.(?:com|pro|io|net|org|ua|dev|app|co)\b|https?://\S+", re.I)
SMALL = {str(i) for i in range(0, 11)}


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower())


def details(transcript: str) -> dict:
    """What the notes must keep: numbers, ticket keys, addresses and the questions, each with its line."""
    found = {"numbers": {}, "keys": {}, "addresses": {}, "questions": []}
    for raw in transcript.splitlines():
        m = LINE.match(raw.strip())
        if not m:
            continue
        t, who, text = m.groups()
        for k in KEY.findall(text):
            found["keys"].setdefault(k, raw)
        for a in ADDR.findall(text):
            found["addresses"].setdefault(a.lower(), raw)
        for n in NUM.findall(text):
            n = n.strip()
            if n in SMALL or re.fullmatch(r"\d\d:\d\d:\d\d", n):
                continue
            found["numbers"].setdefault(n, raw)
        if text.strip().endswith("?") and len(text.split()) >= 4:
            found["questions"].append((text.strip(), raw))
    return found


def covered(notes: str, d: dict) -> dict:
    n = norm(notes)
    digits = re.sub(r"[^\d]", " ", notes)
    res = {}
    for kind in ("numbers", "keys", "addresses"):
        miss = [v for k, v in d[kind].items() if norm(k) not in n and not (kind == "numbers" and re.sub(r"\D", "", k) and
                                                                               re.search(r"\b%s\b" % re.sub(r"\D", "", k), digits))]
        res[kind] = (len(d[kind]) - len(miss), len(d[kind]), miss)
    qmiss = []
    for q, raw in d["questions"]:
        words = [w for w in re.findall(r"\w{5,}", q.lower())][:6]
        if words and sum(w in n for w in words) < max(1, len(words) // 2):
            qmiss.append(raw)
    res["questions"] = (len(d["questions"]) - len(qmiss), len(d["questions"]), qmiss)
    return res


def coverage_line(c: dict) -> str:
    return "Coverage: " + ", ".join(f"{k} {c[k][0]}/{c[k][1]}" for k in ("numbers", "keys", "addresses", "questions") if c[k][1])


def make_notes(md: Path, model: str, lang: str, provider=None) -> dict:
    from .oneshot import provider_from_env
    from .cost import cost_usd
    prov = provider or provider_from_env()
    usd = [0.0]

    def ask(system: str, user: str, max_tokens: int) -> str:
        c = prov.complete(model=model, system=[{"text": system}], user=user, max_tokens=max_tokens, cache_ttl=None)
        if c.error:
            raise RuntimeError("model request failed: " + str(c.error)[:200])
        u = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
        usd[0] += u or 0
        return c.text.strip()

    named = md.with_name(md.name[:-3] + ".named.md") if not md.name.endswith(".named.md") else md
    src = named if named.exists() else md
    text = src.read_text(encoding="utf-8", errors="replace")
    L = LANGS.get(lang, "Ukrainian")
    title = re.sub(r"^\d{4}-\d\d-\d\d-\d{4}-", "", md.stem.split(".")[0]).replace("-", " ")
    ps = parts(text)
    part_notes = [ask(PART_SYS.format(LANG=L), f"Call file: {md.name}. Part {i + 1} of {len(ps)}.\n\n{p}", 6000)
                  for i, p in enumerate(ps)]
    notes = part_notes[0] if len(ps) == 1 else ask(
        MERGE_SYS.format(LANG=L, TITLE=title),
        f"Call file: {md.name}.\n\n" + "\n\n".join(f"## Part {i + 1}\n{n}" for i, n in enumerate(part_notes)), 12000)
    if len(ps) == 1:
        notes = ask(MERGE_SYS.format(LANG=L, TITLE=title), f"Call file: {md.name}.\n\n## Part 1\n{notes}", 10000)
    d = details(text)
    c = covered(notes, d)
    miss = [raw for k in ("numbers", "keys", "addresses", "questions") for raw in (c[k][2] if k != "questions" else c[k][2])]
    if miss:
        uniq = list(dict.fromkeys(miss))[:120]
        notes = ask(FIX_SYS.format(LANG=L), "## Missing details (transcript lines)\n" + "\n".join(uniq) + "\n\n## The notes\n" + notes, 12000)
        c = covered(notes, d)
    out = md.with_name(md.name[:-3].replace(".named", "") + ".notes.md")
    out.write_text(notes.rstrip() + "\n\n" + coverage_line(c) + f". Made {time.strftime('%Y-%m-%d %H:%M')} by {model}.\n",
                   encoding="utf-8")
    return {"ok": True, "path": str(out), "coverage": coverage_line(c), "cost_usd": round(usd[0], 4), "parts": len(ps),
            "error": None}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", required=True)
    ap.add_argument("--model", default="claude-sonnet-5-5")
    ap.add_argument("--lang", default="uk")
    a = ap.parse_args(argv)
    try:
        res = make_notes(Path(a.md), a.model, a.lang)
    except Exception as e:  # noqa: BLE001
        res = {"ok": False, "path": None, "coverage": None, "cost_usd": None, "error": f"{type(e).__name__}: {e}"[:400]}
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
