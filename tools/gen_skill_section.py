#!/usr/bin/env python3
"""Generate the "Triggers" section of the live-tips SKILL.md from rules/triggers.yaml.

Usage:
  gen_skill_section.py                 write rules/generated/skill_triggers.md
  gen_skill_section.py --check         fail if the committed generated file is out of date
  gen_skill_section.py --compare PATH  fail if the Triggers table in PATH (a SKILL.md) differs

The skill keeps a copy of the generated table; editing behaviour happens in rules/, never in
SKILL.md by hand.
"""
import argparse
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RULES = ROOT / "rules"
OUT = RULES / "generated" / "skill_triggers.md"


def render(rules_dir: Path = RULES) -> str:
    doc = yaml.safe_load((rules_dir / "triggers.yaml").read_text(encoding="utf-8"))
    lines = [
        "| Level | Trigger | Tip |",
        "|---|---|---|",
    ]
    for t in doc["triggers"]:
        lines.append("| {} | {} | {} |".format(t["level_label"], t["skill_trigger"], t["skill_tip"]))
    return "\n".join(lines) + "\n"


def extract_table(skill_md: str) -> str:
    lines = skill_md.split("\n")
    start = next(i for i, l in enumerate(lines) if l.startswith("### Triggers"))
    hdr = next(i for i in range(start, len(lines)) if lines[i].startswith("| Level |"))
    out = []
    i = hdr
    while i < len(lines) and lines[i].startswith("|"):
        out.append(lines[i].rstrip())
        i += 1
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--compare", type=Path)
    a = ap.parse_args(argv)
    text = render()
    if a.compare:
        theirs = extract_table(a.compare.read_text(encoding="utf-8"))
        if theirs != text:
            sys.stderr.write("DRIFT: the Triggers table in {} differs from rules/triggers.yaml\n".format(a.compare))
            return 1
        print("OK: Triggers table matches rules/triggers.yaml")
        return 0
    if a.check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            sys.stderr.write("STALE: run tools/gen_skill_section.py\n")
            return 1
        print("OK: generated section is up to date")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print("wrote", OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
