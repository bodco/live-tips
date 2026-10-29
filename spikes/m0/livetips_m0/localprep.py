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
    if r.get("config"):
        add("Project config: " + r["config"], read_text(r["config"], 12_000), 12_000)
    if r.get("use_project_folder", True):
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
        for d in r.get("folders") or []:
            for root, _, files in os.walk(d):
                for f in sorted(files)[:20]:
                    if f.lower().endswith((".md", ".txt", ".docx", ".csv")):
                        add("Folder the PM added: " + os.path.join(root, f), read_text(os.path.join(root, f), 10_000), 10_000)
    return "\n\n".join(blocks), used


SYSTEM = """You prepare a project manager (the PM) for a work call, from the material given below only (never invent
facts, names, numbers or dates; when something is missing, say so). Follow the skill's rules for the Live Brief, the
instant cards and the fact book exactly (formats in the rules). Write in {LANG}. No long dashes.
Answer with exactly three parts and nothing else:
===BRIEF===
<the brief in Markdown; first line: {HEAD}>
===CARDS===
<a JSON list of 15-40 instant cards, the format of the rules>
===FACTS===
<a JSON list of 40-120 facts: {{"id","title","text","keywords","source"}}>"""


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


def split_parts(text: str) -> tuple:
    def part(name: str) -> str:
        m = re.search(r"===%s===\s*(.*?)(?====[A-Z]+===|\Z)" % name, text, re.S)
        return m.group(1).strip() if m else ""
    def as_list(s: str):
        s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s.strip())
        i, j = s.find("["), s.rfind("]")
        try:
            v = json.loads(s[i:j + 1]) if i >= 0 and j > i else []
        except ValueError:
            v = []
        return v if isinstance(v, list) else []
    brief = re.sub(r"^```(?:markdown|md)?\s*|\s*```$", "", part("BRIEF"))
    return brief, as_list(part("CARDS")), as_list(part("FACTS"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", required=True)
    a = ap.parse_args(argv)
    r = json.loads(Path(a.request).read_text(encoding="utf-8"))
    t0 = time.time()
    res = {"ok": False, "duration_s": 0, "tokens": {"input": 0, "output": 0}, "model": r.get("model", ""), "error": None,
           "sources": []}
    try:
        say(stage="pack")
        pack, used = build_pack(r)
        res["sources"] = used
        lang = "Ukrainian" if (r.get("languages") or ["uk"])[0] == "uk" else "English"
        head = f'# Live Brief: {r["title"]} (prep, {r.get("when", "")}, local model {r.get("model", "")})'
        system = SYSTEM.format(LANG=lang, HEAD=head)
        user = (f'Call: "{r["title"]}", {r.get("when", "")}. Project: {r.get("project_name", "")}. Audience: '
                f'{r.get("audience", "auto")}. Meeting type: {r.get("call_type", "auto")}. Languages: '
                f'{"+".join(r.get("languages") or [])}.\n\n## The skill\'s rules\n{skill_rules(r["skill"])}\n\n'
                f"## Material (read all of it; newer facts win)\n{pack}")
        say(stage="model", chars=len(user))
        out = ollama_chat(r.get("url") or "http://127.0.0.1:11434", r["model"], system, user,
                          lambda n: say(stage="writing", pieces=n))
        res["tokens"] = {"input": int(out.get("prompt_eval_count") or 0), "output": int(out.get("eval_count") or 0)}
        brief, cards, facts = split_parts(out.get("text", ""))
        if not brief:
            raise RuntimeError("the model returned no brief")
        base = r["base"]
        Path(base + ".brief.md").write_text(brief.rstrip() + "\n\nSources: " + "; ".join(used) + "\n", encoding="utf-8")
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
