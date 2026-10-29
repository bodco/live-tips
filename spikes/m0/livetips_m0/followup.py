"""Follow-up email draft after a call (Pacenote 0.8, F6, idea 04; rules/followup.yaml). Prints JSON
{"subject", "body", "lang"}; nothing is sent: the app shows it to edit, copy or open in Mail.

  python -m livetips_m0.followup --md <transcript> [--lang en] [--model claude-sonnet-...]
"""
import argparse
import json
from pathlib import Path

import yaml

from . import callinfo
from .oneshot import ask_json, emit
from .rules import DEFAULT_RULES

LANGS = {"en": "English", "uk": "Ukrainian", "es": "Spanish", "de": "German", "fr": "French", "pl": "Polish"}


def rules() -> dict:
    p = DEFAULT_RULES / "followup.yaml"
    return yaml.safe_load(p.read_text(encoding="utf-8")) if p.exists() else {}


def build_user(md: Path) -> str:
    sit = callinfo.last_item(md, "situation") or {}
    head = callinfo.header(md)
    parts = ["CALL: {} ({})".format(head["title"], head["start"])]
    if sit:
        parts.append("CALL PICTURE (decisions, the PM's actions, promises of the other side, open questions):\n" +
                     "\n".join(picture_lines(sit)))
    parts.append("TRANSCRIPT:\n" + callinfo.transcript_text(md, 60000))
    return "\n\n".join(parts)


def _due(a: dict) -> str:
    return "(" + a["due"] + ")" if a.get("due") else ""


def picture_lines(sit: dict) -> list:
    return (["Decision: " + d for d in sit.get("decisions") or []] +
            ["PM will: {} {}".format(a.get("what", ""), _due(a)) for a in sit.get("actions") or []] +
            ["{} will: {} {}".format(a.get("who", ""), a.get("what", ""), _due(a)) for a in sit.get("theirs") or []] +
            ["Open: " + a.get("what", "") for a in sit.get("asks") or [] if a.get("type") != "update"])


def draft(md: Path, lang: str = "en", model: str = "claude-sonnet-5-5", provider=None, lessons: str = "") -> dict:
    r = rules()
    system = r.get("model_prompt", "Write a short follow-up email after a work call.").format(LANG=LANGS.get(lang, "English"))
    if lessons.strip():                       # 0.8.5 (rules/learning.yaml): the PM's recurring corrections
        system += "\n\n" + lessons.strip()
    obj, usd = ask_json(system, build_user(md), model, 1500, provider)
    obj = obj or {}
    body = str(obj.get("body") or "").replace(chr(0x2014), "-").strip()
    return {"subject": str(obj.get("subject") or "").replace(chr(0x2014), "-").strip(), "body": body, "lang": lang, "cost_usd": usd}


def revise(md: Path, current: dict, instruction: str, lang: str = "en", model: str = "claude-sonnet-5-5", provider=None) -> dict:
    """0.8.5: the PM's instruction applied to the current draft (rules/followup.yaml > revise)."""
    r = rules()
    system = r.get("revise_prompt", "Revise the email as the PM asks.").format(LANG=LANGS.get(lang, "English"))
    user = "CURRENT DRAFT:\nSubject: {}\n\n{}\n\nTHE PM'S INSTRUCTION: {}\n\n{}".format(
        current.get("subject", ""), current.get("body", ""), instruction, build_user(md))
    obj, usd = ask_json(system, user, model, 1500, provider)
    obj = obj or {}
    return {"subject": str(obj.get("subject") or current.get("subject") or "").replace(chr(0x2014), "-").strip(),
            "body": str(obj.get("body") or current.get("body") or "").replace(chr(0x2014), "-").strip(), "lang": lang, "cost_usd": usd}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", required=True, type=Path)
    ap.add_argument("--lang", default="en")
    ap.add_argument("--model", default="claude-sonnet-5-5")
    ap.add_argument("--lessons", type=Path, help="a text file with the PM's recurring corrections (rules/learning.yaml)")
    ap.add_argument("--draft", type=Path, help="JSON {subject, body}: the draft to revise")
    ap.add_argument("--instruction", default="")
    a = ap.parse_args(argv)
    try:
        if a.instruction and a.draft:
            emit(dict(revise(a.md, json.loads(a.draft.read_text(encoding="utf-8")), a.instruction, a.lang, a.model), ok=True))
            return 0
        lessons = a.lessons.read_text(encoding="utf-8") if a.lessons and a.lessons.exists() else ""
        emit(dict(draft(a.md, a.lang, a.model, lessons=lessons), ok=True))
    except Exception as e:  # noqa: BLE001
        emit({"ok": False, "error": str(e)[:300]})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
