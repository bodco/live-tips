"""Learning from the PM's corrections as patterns (Pacenote 0.8.5; rules/learning.yaml). Shared rule with the app
(LiveTipsCore/Learning.swift, same fixture rules/fixtures/learning-patterns.json).

  python -m livetips_m0.learning [--log <edits.jsonl>] [--kind followup_instruction] [--prompt]
Prints JSON {"standing": [{"kind", "text", "calls"}]} or, with --prompt, the prompt block.
"""
import argparse
import json
import re
from pathlib import Path

LOG = Path.home() / "Library/Application Support/LiveTips/edits.jsonl"
HEAD = ("Recurring corrections (the PM made each of them on two or more different calls; "
        "apply them always, without being asked):")


def words(text: str) -> set:
    return set(re.findall(r"[^\W_]{3,}", (text or "").lower()))


def signals(records: list) -> list:
    """(kind, text, file) in log order (rules/learning.yaml > signals)."""
    out = []
    for r in records:
        k, f = r.get("kind", ""), r.get("file", "")
        if k == "followup_instruction" and r.get("text"):
            out.append((k, str(r["text"]), f))
        elif k in ("brief_edit", "followup_edit"):
            out += [(k, str(x), f) for x in r.get("removed") or [] if str(x).strip()]
        elif k == "talk_edit" and r.get("say_after"):
            out.append((k, str(r["say_after"]), f))
        elif k in ("card_onme_remove", "card_onme_edit") and (r.get("before") or {}).get("text"):
            out.append((k, str(r["before"]["text"]), f))
    return out


def standing(records: list, kinds=None) -> list:
    groups = []          # {kind, words, texts: [(i, text)], files: set}
    for i, (k, t, f) in enumerate(signals(records)):
        if kinds and k not in kinds:
            continue
        w = words(t)
        if not w:
            continue
        g = next((g for g in groups if g["kind"] == k and len(w & g["words"]) / len(w | g["words"]) >= 0.5), None)
        if g is None:
            groups.append({"kind": k, "words": w, "last": (i, t), "files": {f}})
        else:
            g["last"], g["files"] = (i, t), g["files"] | {f}
    keep = [g for g in groups if len(g["files"]) >= 2]
    keep.sort(key=lambda g: (-len(g["files"]), -g["last"][0]))
    return [{"kind": g["kind"], "text": g["last"][1], "calls": len(g["files"])} for g in keep]


def prompt(items: list) -> str:
    if not items:
        return ""
    return HEAD + "\n" + "\n".join("- [{}] {}".format(x["kind"], x["text"]) for x in items[:20])


def load(path: Path) -> list:
    out = []
    try:
        for ln in path.read_text(encoding="utf-8").splitlines():
            try:
                out.append(json.loads(ln))
            except ValueError:
                pass
    except OSError:
        pass
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", type=Path, default=LOG)
    ap.add_argument("--kind", action="append")
    ap.add_argument("--prompt", action="store_true")
    a = ap.parse_args(argv)
    items = standing(load(a.log), set(a.kind) if a.kind else None)
    print(prompt(items) if a.prompt else json.dumps({"standing": items}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
