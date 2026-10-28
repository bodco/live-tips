"""Rehearsal of a presentation (Pacenote 0.8.6, F6, idea 10; rules/rehearsal.yaml). Nothing is recorded: the PM
goes through the steps with a timer, then answers 3-4 hard questions in writing and gets a short assessment.

  python -m livetips_m0.rehearse questions --base <prep base> [--lang en] [--model ...]
  python -m livetips_m0.rehearse score --base <prep base> --answers <answers.json> [--lang en] [--model ...]
<prep base> = the path of the preparation without .brief.md. Prints JSON.
"""
import argparse
import json
from pathlib import Path

import yaml

from .oneshot import ask_json, emit
from .rules import DEFAULT_RULES

LANGS = {"en": "English", "uk": "Ukrainian"}


def rules() -> dict:
    p = DEFAULT_RULES / "rehearsal.yaml"
    return yaml.safe_load(p.read_text(encoding="utf-8")) if p.exists() else {}


def material(base: str) -> str:
    parts = []
    for ext, cap in ((".brief.md", 20000), (".outline.json", 12000), (".slides.json", 16000), (".facts.json", 8000)):
        p = Path(base + ext)
        if p.exists():
            parts.append("{}:\n{}".format(ext.strip(".").upper(), p.read_text(encoding="utf-8", errors="replace")[:cap]))
    return "\n\n".join(parts) or "(no preparation)"


def questions(base: str, lang: str = "en", model: str = "claude-sonnet-5-5", provider=None) -> dict:
    r = rules()
    n = int(r.get("questions", 4))
    system = r.get("questions_prompt", "Ask {N} hard client questions about this presentation.").format(N=n, LANG=LANGS.get(lang, "English"))
    obj, usd = ask_json(system, material(base), model, 1200, provider)
    qs = [str(q.get("q") if isinstance(q, dict) else q).strip() for q in (obj or {}).get("questions") or []]
    return {"ok": True, "questions": [q.replace(chr(0x2014), "-") for q in qs if q][:n], "cost_usd": usd}


def score(base: str, answers: list, lang: str = "en", model: str = "claude-sonnet-5-5", provider=None) -> dict:
    r = rules()
    system = r.get("score_prompt", "Score each answer 1-5 with one line of feedback.").format(LANG=LANGS.get(lang, "English"))
    user = material(base) + "\n\nQUESTIONS AND THE PM'S WRITTEN ANSWERS:\n" + "\n\n".join(
        "Q{}: {}\nA{}: {}".format(i + 1, a.get("q", ""), i + 1, a.get("a", "") or "(no answer)") for i, a in enumerate(answers))
    obj, usd = ask_json(system, user, model, 1500, provider)
    obj = obj or {}
    items = []
    for i, a in enumerate(answers):
        s = (obj.get("answers") or [])[i] if i < len(obj.get("answers") or []) else {}
        try:
            sc = max(1, min(5, int(s.get("score", 0))))
        except (TypeError, ValueError):
            sc = 0
        items.append({"q": a.get("q", ""), "score": sc, "feedback": str(s.get("feedback") or "").replace(chr(0x2014), "-"),
                      "better": str(s.get("better") or "").replace(chr(0x2014), "-")})
    return {"ok": True, "answers": items, "overall": str(obj.get("overall") or "").replace(chr(0x2014), "-"), "cost_usd": usd}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["questions", "score"])
    ap.add_argument("--base", required=True)
    ap.add_argument("--answers", type=Path)
    ap.add_argument("--lang", default="en")
    ap.add_argument("--model", default="claude-sonnet-5-5")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "questions":
            emit(questions(a.base, a.lang, a.model))
        else:
            emit(score(a.base, json.loads(a.answers.read_text(encoding="utf-8")), a.lang, a.model))
    except Exception as e:  # noqa: BLE001
        emit({"ok": False, "error": str(e)[:300]})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
