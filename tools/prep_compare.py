#!/usr/bin/env python3
"""Compare the preparations of one call kept in prep-runs (rules/ai.yaml > prep_runs).

  python3 tools/prep_compare.py <appRoot>/prep-runs/<base> [--md out.md]

One row per run: route, model, minutes, price, tokens, turns, brief words, the brief sections found (sweep.md:
checklist, previous meetings, topic map, commitments, red lines, names, my update, insight bank), speech points
and how many have a full text, cards, facts, facts with a source, and the sources line. Numbers only: the quality
review reads the briefs themselves.
"""
import json
import re
import sys
from pathlib import Path

SECTIONS = [("checklist", r"checklist|чекліст|decisions to obtain|рішення"),
            ("previous", r"previous meetings|попередні зустрічі|попередні дзвінки"),
            ("topics", r"topic map|карта тем|теми"),
            ("commitments", r"commitments|зобов|обіцянк"),
            ("red_lines", r"red lines|червоні лінії|не відкривати"),
            ("names", r"names and aliases|імена"),
            ("my_update", r"my update|мій апдейт|мій спіч|твій спіч|my speech|your speech"),
            ("insight", r"insight bank|банк|факти")]


def load(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return default


def row(d: Path) -> dict:
    run = load(d / "run.json", {})
    brief = (d / "brief.md").read_text(encoding="utf-8", errors="replace") if (d / "brief.md").exists() else ""
    heads = [h.lower() for h in re.findall(r"^#{2,4}\s+(.+)$", brief, re.M)]
    found = [k for k, rx in SECTIONS if any(re.search(rx, h) for h in heads)]
    upd = re.search(r"^##\s*(?:\d+\.\s*)?(?:my update|мій апдейт|мій спіч|твій спіч|my speech|your speech)[^\n]*\n(.*?)(?=^##\s|\Z)",
                    brief, re.M | re.S | re.I)
    sec = upd.group(1) if upd else ""
    points = len(re.findall(r"^\s*(?:\d+[.)]|[-*])\s+\S", sec, re.M))
    fulls = len(re.findall(r"^\s*>\s*\S", sec, re.M))
    cards, facts = load(d / "cards.json", []), load(d / "facts.json", [])
    tok = run.get("tokens") or {}
    return {"run": d.name, "route": run.get("route", "?"), "model": run.get("model", "?"), "ok": run.get("ok"),
            "min": round((run.get("duration_s") or 0) / 60, 1), "usd": run.get("cost_usd"),
            "in_tok": tok.get("input"), "out_tok": tok.get("output"), "cache_read": tok.get("cache_read"), "turns": run.get("turns"),
            "words": len(brief.split()), "sections": f"{len(found)}/{len(SECTIONS)}", "missing": ", ".join(k for k, _ in SECTIONS if k not in found),
            "points": points, "full_texts": fulls, "cards": len(cards) if isinstance(cards, list) else 0,
            "facts": len(facts) if isinstance(facts, list) else 0,
            "facts_src": sum(1 for f in facts if isinstance(f, dict) and f.get("source")) if isinstance(facts, list) else 0}


def main(argv) -> int:
    if not argv:
        print(__doc__)
        return 2
    root = Path(argv[0]).expanduser()
    rows = [row(d) for d in sorted(root.iterdir()) if d.is_dir() and not d.name.endswith("-before")]
    cols = ["run", "route", "model", "ok", "min", "usd", "in_tok", "out_tok", "cache_read", "turns", "words", "sections",
            "points", "full_texts", "cards", "facts", "facts_src", "missing"]
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    lines += ["| " + " | ".join("" if r[c] is None else str(r[c]) for c in cols) + " |" for r in rows]
    text = "\n".join(lines)
    print(text)
    if "--md" in argv:
        Path(argv[argv.index("--md") + 1]).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
