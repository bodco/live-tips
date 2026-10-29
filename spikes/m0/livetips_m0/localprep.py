"""Pacenote 0.8.5 (owner): a preparation on this Mac (Ollama), for when neither the Claude API nor Claude Code
can run, and to compare it with them. A local model does not read files by itself well, so this module builds the
context pack (the skill's brief rules, the project config, the previous calls of this meeting, the digest, the
files the PM added, the Current State page of the Notion mirror) and asks the model once.

  python -m livetips_m0.localprep --request <request.json>

The request is the same call the app gives Claude Code (rules/ai.yaml > local). Progress goes to stdout as JSON
lines {"stage": ...}; the last line is {"ok", "duration_s", "tokens": {"input", "output"}, "model", "error"}.
Nothing leaves the Mac.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import List, Optional

PACK_CHARS = 120_000          # about 35-40K tokens: what a 26-35B model on a 32 GB Mac can hold with room to answer
NUM_CTX = 65_536


def say(**kw) -> None:
    print(json.dumps(kw, ensure_ascii=False), flush=True)


def read_text(p: str, cap: int) -> str:
    try:
        if p.lower().endswith((".docx", ".doc", ".rtf", ".odt", ".pages")):
            r = subprocess.run(["textutil", "-convert", "txt", "-stdout", p], capture_output=True, text=True, timeout=30)
            t = r.stdout
        else:
            t = Path(p).read_text(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        return ""
    return t if len(t) <= cap else t[:cap] + "\n[... cut at %d characters]" % cap


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def previous_calls(live: str, title: str, n: int = 3) -> List[str]:
    """The same pick as the app's previousCallsBlock: transcripts of this meeting by title, newest first."""
    want = slug(title)
    out, stems = [], set()
    try:
        names = sorted(os.listdir(live), reverse=True)
    except OSError:
        return []
    for name in names:
        m = re.match(r"^(\d{4}-\d\d-\d\d-\d{4}-[^.]+)(\.app)?\.md$", name)
        if not m:
            continue
        core = slug(m.group(1)[16:])
        if not want or not (core == want or (min(len(core), len(want)) >= 4 and (want in core or core in want))):
            continue
        if m.group(1) in stems:
            continue
        stems.add(m.group(1))
        named = os.path.join(live, name[:-3] + ".named.md")
        out.append(named if os.path.exists(named) else os.path.join(live, name))
        if len(out) == n:
            break
    return out


def current_state(notion_dirs: List[str]) -> List[str]:
    hits = []
    for d in notion_dirs:
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith(".md") and "current state" in f.lower().replace("-", " ").replace("_", " "):
                    hits.append(os.path.join(root, f))
    return sorted(hits, key=lambda p: -os.path.getmtime(p))[:2]


def skill_rules(skill: str) -> str:
    parts = []
    for ref in ("references/sweep.md", "references/speech.md"):
        t = read_text(os.path.join(skill, ref), 40_000)
        if t:
            parts.append(f"## {ref}\n{t}")
    return "\n\n".join(parts)


def build_pack(r: dict) -> tuple:
    used, blocks, left = [], [], PACK_CHARS

    def add(label: str, text: str, cap: int) -> None:
        nonlocal left
        if not text.strip() or left <= 2000:
            return
        text = text[:min(cap, left)]
        blocks.append(f"### {label}\n{text}")
        used.append(label)
        left -= len(text)

    add("Call context written by the PM", r.get("context") or "", 6000)
    for f in r.get("files") or []:
        add("File the PM added: " + f, read_text(f, 20_000), 20_000)
    for d in r.get("folders") or []:
        for root, _, files in os.walk(d):
            for f in sorted(files)[:20]:
                if f.lower().endswith((".md", ".txt", ".docx", ".csv")):
                    add("Folder the PM added: " + os.path.join(root, f), read_text(os.path.join(root, f), 10_000), 10_000)
    if r.get("config"):
        add("Project config: " + r["config"], read_text(r["config"], 14_000), 14_000)
    if r.get("use_project_folder", True):
        if r.get("include_prev", True):
            for p in previous_calls(r["live"], r["title"]):
                add("Previous call of this meeting: " + os.path.basename(p), read_text(p, 25_000), 25_000)
        for p in current_state(r.get("notion") or []):
            add("Notion mirror: " + os.path.basename(p), read_text(p, 12_000), 12_000)
        if r.get("lt"):
            try:
                d = subprocess.run(r["lt"] + ["digest", r["root"], "--days", "14", "--max-chars", "8000"],
                                   capture_output=True, text=True, timeout=60)
                add("Digest of the last 14 days (lt digest)", d.stdout, 8000)
            except Exception:  # noqa: BLE001
                pass
    return "\n\n".join(blocks), used


LANGS = {"uk": "Ukrainian", "en": "English", "es": "Spanish", "de": "German", "pl": "Polish", "ru": "Russian"}

NOTES_SYS = """You read one transcript of an earlier work call and write notes for the project manager (the PM) who
prepares the next call of the same meeting. Only what the transcript says; never invent. Speaker labels can be wrong
and names garbled. Write in {BRIEF_LANG}, no long dashes. Exactly these parts:
Date and length (from the file name and the times).
Discussed: 4-8 lines, what was said, with 1-3 short quotes in the original language.
Questions: every question asked, who asked, answered fully / partly / not.
Action items: who, what, when (as said).
Promises from our side (the PM's team), with dates.
The other side's concerns and moods (in one or two lines).
Open after the call: what is still unanswered or undecided."""

BRIEF_SYS = """You prepare the PM for a work call: a Live Brief the PM reads before the call and keeps open during it.
Use only the material given (notes of earlier calls, project config, Current State, digest, the PM's context and
files). Never invent facts, names, numbers or dates; when something is unknown or may be old, say so and what to
check. Newer facts win. Write the brief in {BRIEF_LANG}; quotes and ready phrases in the call language ({CALL_LANG}).
No long dashes. Be concrete and detailed (1500-2500 words): dates, numbers, ticket keys, who said what.

Start with exactly this first line: {HEAD}
Then a short header: audience, call language, the call time, participants from the invitation (mark anyone the
material says has left the project as not expected), a freshness line (the newest source and what you cannot see),
the update period (since the last call of this meeting) and what was already said there and must not be repeated.

Then these sections, in this order, with these headings:
## 1. Checklist
"- [ ] **topic:** what to cover and what to get" lines (6-10), then "**Decisions to obtain:**" (a), (b), (c)...
## 1a. Previous meetings
One paragraph per earlier call (newest first, all of them): what was discussed with short quotes. Then
"**Open after N calls:**" with Questions (answered or not), Action items (owner, due, status), Promises in flight,
the other side's concerns.
## 2. Topic map
"- topic: \"keyword\", \"keyword\" (in every call language) -> one-line status" (8-12 lines).
## 3. Commitments in flight
Our side: ...; Their side: ...
## 4. Red lines
Decided items not to reopen, what never to say to this side, out of scope, who decides.
## 5. Names and aliases
Each person with the spellings speech recognition may produce; garbled product names.
## 7. Insight Bank
15-30 one-line insights with numbers and sources (date or document).
## Sources
What was read, what is old, what was not available.

Do not write a section 6 (the speech is written separately)."""

SPEECH_SYS = """You write the PM's speech for the call: the update the PM gives when asked, from the brief and the notes.
In the call language ({CALL_LANG}); the explanation lines in {BRIEF_LANG}. No long dashes. Only facts from the material;
mark a point the PM must check first with "[check]". Format, exactly:
## 6. My update
<one line in {BRIEF_LANG}: the period and what to check before the call>
Opening: "<one ready sentence>"
1. <short point, max 8 words>
   > <the full text to read aloud: 1-3 sentences, with the facts, dates and names of that point>
2. ...
6-9 points: what changed since the last call, open questions to the other side, what comes next. Every point has its
"> " full text."""

CARDS_SYS = """From the brief, write the instant cards and the fact book of the call, following the skill's rules below.
Answer with exactly two parts and nothing else:
===CARDS===
<a JSON list of 15-30 cards: {{"id","triggers","on","level","gist","phrase","note","cooldown_s"}}; triggers are
lowercase distinctive phrases in every call language ({LANGS}), never one common word; gist in {BRIEF_LANG} with an
emoji; phrase in {CALL_LANG}, ready to say>
===FACTS===
<a JSON list of 40-80 facts: {{"id","title","text","keywords","source"}}; text with the numbers and dates; keywords in
every call language; source = the call date or the document>"""


def ollama_chat(url: str, model: str, system: str, user: str, on_tokens) -> dict:
    body = json.dumps({"model": model, "stream": True, "keep_alive": "2m",
                       "options": {"num_ctx": NUM_CTX, "temperature": 0.3},
                       "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}).encode()
    req = urllib.request.Request(url.rstrip("/") + "/api/chat", data=body, headers={"Content-Type": "application/json"})
    text, last, n = [], {}, 0
    with urllib.request.urlopen(req, timeout=3600) as resp:
        for raw in resp:
            if not raw.strip():
                continue
            ev = json.loads(raw)
            if ev.get("error"):
                raise RuntimeError(ev["error"])
            piece = (ev.get("message") or {}).get("content") or ""
            if piece:
                text.append(piece)
                n += 1
                if n % 200 == 0:
                    on_tokens(n)
            if ev.get("done"):
                last = ev
    last["text"] = "".join(text)
    return last


def as_list(s: str) -> list:
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", (s or "").strip())
    i, j = s.find("["), s.rfind("]")
    try:
        v = json.loads(s[i:j + 1]) if i >= 0 and j > i else []
    except ValueError:
        v = []
    return v if isinstance(v, list) else []


def split_parts(text: str) -> tuple:
    """The one-pass answer (kept for tests and the fallback): BRIEF, CARDS and FACTS parts."""
    def part(name: str) -> str:
        m = re.search(r"===%s===\s*(.*?)(?====[A-Z]+===|\Z)" % name, text, re.S)
        return m.group(1).strip() if m else ""
    brief = re.sub(r"^```(?:markdown|md)?\s*|\s*```$", "", part("BRIEF"))
    return brief, as_list(part("CARDS")), as_list(part("FACTS"))


def clean_md(t: str) -> str:
    return re.sub(r"^```(?:markdown|md)?\s*|\s*```$", "", (t or "").strip())


def insert_speech(brief: str, speech: str) -> str:
    """The speech goes in as section 6, before the Insight Bank."""
    speech = clean_md(speech)
    if not speech:
        return brief
    if not speech.lstrip().startswith("## "):
        speech = "## 6. My update\n" + speech
    m = re.search(r"^## (?:7\.|.*insight)", brief, re.M | re.I)
    return (brief[:m.start()] + speech.strip() + "\n\n" + brief[m.start():]) if m else brief.rstrip() + "\n\n" + speech.strip() + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    a = ap.parse_args(argv)
    r = json.loads(Path(a.request).read_text(encoding="utf-8"))
    t0 = time.time()
    res = {"ok": False, "duration_s": 0, "tokens": {"input": 0, "output": 0}, "model": r.get("model", ""), "error": None,
           "sources": [], "passes": []}
    url, model = r.get("url") or "http://127.0.0.1:11434", r["model"]

    def ask(name: str, system: str, user: str) -> str:
        t = time.time()
        out = ollama_chat(url, model, system, user, lambda n: say(stage="writing", pass_=name, pieces=n))
        res["tokens"]["input"] += int(out.get("prompt_eval_count") or 0)
        res["tokens"]["output"] += int(out.get("eval_count") or 0)
        res["passes"].append({"pass": name, "s": int(time.time() - t), "in": int(out.get("prompt_eval_count") or 0),
                              "out": int(out.get("eval_count") or 0)})
        return out.get("text", "")

    try:
        call_codes = r.get("languages") or ["uk"]
        call_lang = LANGS.get(call_codes[0], call_codes[0])
        brief_lang = LANGS.get(r.get("brief_lang") or "uk", "Ukrainian")
        langs = ", ".join(LANGS.get(c, c) for c in call_codes)
        head = f'# Live Brief: {r["title"]} (prep, {r.get("when", "")}, local model {model})'
        call = (f'Call: "{r["title"]}", {r.get("when", "")}. Project: {r.get("project_name", "")}. Audience: '
                f'{r.get("audience", "auto")}. Meeting type: {r.get("call_type", "auto")}. Call languages: {langs}.')

        # Pass 1: notes of each earlier call of this meeting (rules/ai.yaml > local)
        say(stage="pack")
        notes = []
        prev = previous_calls(r["live"], r["title"]) if r.get("use_project_folder", True) else []
        for i, p in enumerate(prev):
            say(stage="model", pass_="notes", n=i + 1, of=len(prev))
            n = ask("notes", NOTES_SYS.format(BRIEF_LANG=brief_lang),
                    f"{call}\n\nTranscript {os.path.basename(p)}:\n{read_text(p, 60_000)}")
            notes.append(f"### Notes: {os.path.basename(p)}\n{n.strip()}")
            res["sources"].append("Previous call of this meeting: " + os.path.basename(p))
        pack, used = build_pack(dict(r, include_prev=False))      # the notes stand for the transcripts
        res["sources"] += used
        notes_txt = "\n\n".join(notes) or "(no earlier calls of this meeting found)"

        # Pass 2: the brief, every section but the speech
        say(stage="model", pass_="brief")
        brief = clean_md(ask("brief", BRIEF_SYS.format(BRIEF_LANG=brief_lang, CALL_LANG=call_lang, HEAD=head),
                             f"{call}\n\n## Notes of the earlier calls (newest first)\n{notes_txt}\n\n## Material\n{pack}"))
        if not brief:
            raise RuntimeError("the model returned no brief")

        # Pass 3: the speech with full texts, then the cards and the facts
        say(stage="model", pass_="speech")
        speech = ask("speech", SPEECH_SYS.format(BRIEF_LANG=brief_lang, CALL_LANG=call_lang),
                     f"{call}\n\n## The brief\n{brief}\n\n## Notes of the last call\n{notes[0] if notes else '(none)'}")
        brief = insert_speech(brief, speech)
        say(stage="model", pass_="cards")
        rules = read_text(os.path.join(r["skill"], "references/sweep.md"), 40_000)
        m = re.search(r"\*\*Instant cards.*?(?=^## Refresh)", rules, re.S | re.M)
        cf = ask("cards", CARDS_SYS.format(BRIEF_LANG=brief_lang, CALL_LANG=call_lang, LANGS=langs),
                 f"{call}\n\n## The skill's rules for cards and facts\n{m.group(0) if m else rules[:15000]}\n\n## The brief\n{brief}")
        _, cards, facts = split_parts("===BRIEF===\nx\n" + cf)

        base = r["base"]
        Path(base + ".brief.md").write_text(brief.rstrip() + "\n\nSources (local model): " + "; ".join(res["sources"]) + "\n",
                                            encoding="utf-8")
        if cards:
            Path(base + ".cards.json").write_text(json.dumps(cards, ensure_ascii=False, indent=1), encoding="utf-8")
        if facts:
            Path(base + ".facts.json").write_text(json.dumps(facts, ensure_ascii=False, indent=1), encoding="utf-8")
        if r.get("lt"):
            say(stage="check")
            fix = ["--fix"] if not cards else []
            chk = subprocess.run(r["lt"] + ["prep-check", base + ".md"] + fix, capture_output=True, text=True, timeout=60)
            res["check"] = (chk.stdout.strip().splitlines() or [""])[-1][:300]
        res["ok"] = True
    except Exception as e:  # noqa: BLE001
        res["error"] = f"{type(e).__name__}: {e}"[:400]
    res["duration_s"] = int(time.time() - t0)
    say(**res)
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
