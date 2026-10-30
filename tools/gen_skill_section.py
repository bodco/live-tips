#!/usr/bin/env python3
"""Generate the sections of the live-tips SKILL.md that come from rules/: the "Triggers" table
(rules/triggers.yaml) and, since Pacenote 0.8, "Agenda, commitments, brief freshness"
(rules/agenda.yaml, rules/commitments.yaml, rules/freshness.json).

Usage:
  gen_skill_section.py                 write rules/generated/skill_triggers.md and skill_register.md
  gen_skill_section.py --check         fail if a committed generated file is out of date
  gen_skill_section.py --compare PATH  fail if a generated section in PATH (a SKILL.md) differs

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
OUT_REG = RULES / "generated" / "skill_register.md"
REG_HEAD = "### Agenda, commitments, brief freshness"
OUT_AFTER = RULES / "generated" / "skill_after.md"
AFTER_HEAD = "### Risks and the follow-up email"


def render(rules_dir: Path = RULES) -> str:
    doc = yaml.safe_load((rules_dir / "triggers.yaml").read_text(encoding="utf-8"))
    lines = [
        "| Level | Trigger | Tip |",
        "|---|---|---|",
    ]
    for t in doc["triggers"]:
        lines.append("| {} | {} | {} |".format(t["level_label"], t["skill_trigger"], t["skill_tip"]))
    return "\n".join(lines) + "\n"


def render_register(rules_dir: Path = RULES) -> str:
    """One bullet per rule, the text exactly as in rules/ (the skill keeps a copy, compared with --compare)."""
    import json
    ag = yaml.safe_load((rules_dir / "agenda.yaml").read_text(encoding="utf-8"))
    cm = yaml.safe_load((rules_dir / "commitments.yaml").read_text(encoding="utf-8"))
    fr = json.loads((rules_dir / "freshness.json").read_text(encoding="utf-8"))
    out = ["Generated from `rules/agenda.yaml`, `rules/commitments.yaml` and `rules/freshness.json`; do not edit here.", ""]
    out.append("**Agenda.** Source: " + ag["source"] + " At most {} items, ~{} characters each.".format(ag["max_items"], ag["max_chars"]))
    out.append("- States: " + "; ".join("`{}` {}".format(k, v) for k, v in ag["states"].items()) + ".")
    out.append("- Call picture: " + ag["model_rule"])
    out.append("- Window: " + ag["emit"])
    out.append("- After the call: " + ag["wrapup"])
    out.append("")
    out.append("**Commitments register.** File: `{}`. {}".format(cm["file"], cm["format"]))
    for k, v in cm["events"].items():
        out.append("- `{}`: `{}`".format(k, v))
    out.append("- id: `{}`; series: `{}`.".format(cm["id"], cm["series_key"]))
    for k in ("owner", "duplicates", "write_when", "open_on_call", "model_rule_theirs", "model_rule_done", "closing", "export", "mine", "order"):
        out.append("- {}: {}".format(k.replace("_", " ").capitalize(), cm[k]))
    out.append("")
    out.append("**Brief freshness.** " + fr["about"])
    for k in ("prepared_at", "changes", "stale_rule", "label", "refresh", "snapshot"):
        out.append("- {}: {}".format(k.replace("_", " ").capitalize(), fr[k]))
    out.append("- Ignored paths: {}; hidden files ignored: {}; stale after {} h.".format(
        ", ".join("`{}`".format(x) for x in fr["ignore"]), "yes" if fr["ignore_hidden"] else "no", fr["stale_after_hours"]))
    return "\n".join(out) + "\n"


def render_after(rules_dir: Path = RULES) -> str:
    """Pacenote 0.8: risks heard on the call and the follow-up email draft (rules/risks.yaml, rules/followup.yaml)."""
    rk = yaml.safe_load((rules_dir / "risks.yaml").read_text(encoding="utf-8"))
    fu = yaml.safe_load((rules_dir / "followup.yaml").read_text(encoding="utf-8"))
    out = ["Generated from `rules/risks.yaml` and `rules/followup.yaml`; do not edit here.", ""]
    out.append("**Risks.** Call picture: " + rk["model_rule"])
    out.append("- During the call: " + rk["during_call"])
    out.append("- After the call: " + rk["after_call"])
    out.append("")
    out.append("**Follow-up email.** " + fu["when"])
    for k in ("language", "structure", "never"):
        out.append("- {}: {}".format(k.capitalize(), fu[k]))
    return "\n".join(out) + "\n"


def extract_section(skill_md: str, head: str) -> str:
    """The body of the SKILL.md section `head` up to the next heading, blank lines at the ends removed."""
    lines = skill_md.split("\n")
    start = next(i for i, l in enumerate(lines) if l.startswith(head))
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("#")), len(lines))
    return "\n".join(lines[start + 1:end]).strip("\n") + "\n"


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


def compare(path: Path, text: str, sections) -> int:
    """1 when the Triggers table or a generated section in a SKILL.md differs from rules/."""
    md = path.read_text(encoding="utf-8")
    bad = 0
    if extract_table(md) != text:
        sys.stderr.write("DRIFT: the Triggers table in {} differs from rules/triggers.yaml\n".format(path))
        bad = 1
    for head, body in sections:
        if head not in md or extract_section(md, head) != body:
            sys.stderr.write("DRIFT: the section '{}' in {} differs from rules/\n".format(head, path))
            bad = 1
    if not bad:
        print("OK: generated sections match rules/")
    return bad


def outputs(text, reg, after):
    return ((OUT, text), (OUT_REG, reg), (OUT_AFTER, after))


def check(files) -> int:
    for out, t in files:
        if not out.exists() or out.read_text(encoding="utf-8") != t:
            sys.stderr.write("STALE: run tools/gen_skill_section.py\n")
            return 1
    print("OK: generated section is up to date")
    return 0


def write(files) -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    for out, t in files:
        out.write_text(t, encoding="utf-8")
        print("wrote", out.relative_to(ROOT))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--compare", type=Path)
    a = ap.parse_args(argv)
    text, reg, after = render(RULES), render_register(RULES), render_after(RULES)
    if a.compare:
        return compare(a.compare, text, ((REG_HEAD, reg), (AFTER_HEAD, after)))
    return check(outputs(text, reg, after)) if a.check else write(outputs(text, reg, after))


if __name__ == "__main__":
    sys.exit(main())
