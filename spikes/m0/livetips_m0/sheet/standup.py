"""0.10.0 (Meeting Sheet, fix 2026-11-12, owner): stand-up quality.

A stand-up sheet is the PM's own update: short first-person lines (since last time, today, blockers, whom to ask).
The model gets the rule below; after it answers, a fact that talks about the sources instead of the work ("the call
context mentions an email; maybe it needs handling") is dropped (a meta sentence). A block left with nothing
concrete says "not found" in the sheet. When the model leaves On me today or Waiting on others empty although the
Tracker has items, the Tracker fills them. The live window never shows a not_found or a meta line on a card
(recorder/src/transcriber.py: sheet_standup uses the same patterns, kept in step by tests/test_standup_fix77.py).
"""
import re
from typing import Dict, List, Optional

BLOCKS = ("standup_since", "standup_today", "standup_blockers", "standup_waiting")

# Sentences about the sources or hedges, never a line the PM can say on a stand-up (EN and UK).
META_PATTERNS = [
    r"\b(?:call )?(?:context|sources?|invitation|invite|documents?|notes|transcripts?)\s+(?:mentions?|mentioned|says?|said|"
    r"do(?:es)? not|don't|doesn't|has no|have no|contains?|refers?|indicates?|gives? no|lacks?)\b",
    r"\b(?:is|are|was|were)\s+(?:not\s+)?(?:mentioned|given|specified|stated|provided|indicated)\b",
    r"\bnot\s+(?:given|specified|stated|provided|indicated|clear|known)\b",
    r"\b(?:no|nothing)\s+(?:data|information|details|info)\b",
    r"\b(?:maybe|perhaps|possibly|might need|may need|unclear)\b",
    r"\bin the (?:sources|context|invitation|documents)\b",
    r"(?:^|\s)(?:у|в)\s+(?:контексті|джерелах|запрошенні|документах|нотатках|транскрипті)",
    r"згадан|згадує|згадуєть",
    r"(?:^|\s)не\s+(?:вказан|зазначен|сказан|наведен|уточнен|відом)",
    r"немає\s+(?:даних|інформації|деталей|відомостей)",
    r"(?:^|\s)(?:можливо|ймовірно|неясно|незрозуміло)(?:\s|,|$)",
    r"джерел\w*\s+(?:не|немає)",
]
META = re.compile("|".join(META_PATTERNS), re.I | re.U)

NOT_FOUND = {
    "en": {"standup_since": "Nothing found about what was done since the last stand-up.",
           "standup_today": "Nothing found for today.",
           "standup_blockers": "No blockers found.",
           "standup_waiting": "Nobody found to wait on."},
    "uk": {"standup_since": "Не знайдено, що зроблено після попереднього стендапу.",
           "standup_today": "Не знайдено, що на сьогодні.",
           "standup_blockers": "Блокерів не знайдено.",
           "standup_waiting": "Не знайдено, на кого чекаю."},
}

RULE = (
    "Stand-up blocks (standup_*): every fact is one short line of the PM's own update, in the first person and concrete "
    "(what, which project or task, a number or a date), as the PM would say it on the call, for example "
    "\"Finished the date filter for Orbit\" or \"Sending Mike Carter the test accounts today\". "
    "standup_since: what the PM did since the previous stand-up, from the earlier stand-up notes and transcripts (what the "
    "PM said they would do and what got done) and from the recent files and commits of the folders. "
    "standup_today: first the Tracker items On me that are OVERDUE or due TODAY, then the PM's plan from the previous "
    "stand-up and the recent work. standup_blockers: what blocks the PM (from the earlier stand-ups, and Tracker items "
    "Waiting on others that are overdue), with value.owner = who can unblock. standup_waiting: from the Tracker "
    "Waiting on others, one fact per person and item, value.owner = the person. Never write about the sources "
    "themselves: no \"the context mentions\", \"maybe it needs handling\", \"not specified\", \"the sources do not say\". "
    "A line the PM cannot say as is does not belong in these blocks; when a stand-up block has nothing concrete, write "
    "ONE not_found fact for it.")


def is_meta(text: str) -> bool:
    return bool(META.search(text or ""))


def has_blocks(blocks: List[dict]) -> bool:
    return any(b.get("type") in BLOCKS for b in blocks)


def _missing(t: str, lang: str, checked: str) -> dict:
    return {"text": NOT_FOUND.get(lang, NOT_FOUND["en"])[t], "source_ids": [], "locator": {}, "checked_at": checked,
            "status": "not_found", "origin": "model"}


def real(facts: List[dict]) -> List[dict]:
    return [f for f in facts if f.get("status") != "not_found"]


def guard(facts: Dict[str, List[dict]], lang: str, checked: str, wanted: Optional[set] = None) -> int:
    """Drops meta facts (any status but not_found) of the stand-up blocks; a block left without facts gets one
    not_found fact. Returns how many were dropped."""
    dropped = 0
    for t in BLOCKS:
        if wanted is not None and t not in wanted:
            continue
        cur = facts.get(t) or []
        keep = [f for f in cur if f.get("status") == "not_found"
                or not (is_meta(f.get("text", "")) or is_meta(f.get("label", "")))]
        dropped += len(cur) - len(keep)
        if real(keep):
            keep = real(keep)                       # a found line makes a "not found" of the same block moot
        facts[t] = keep or [_missing(t, lang if lang in NOT_FOUND else "en", checked)]
    return dropped


def _overdue_note(x: dict, lang: str) -> str:
    if x.get("state") == "overdue" and x.get("due_date"):
        return (f" (прострочено, до {x['due_date']})" if lang == "uk" else f" (overdue since {x['due_date']})")
    if x.get("state") == "today":
        return " (до сьогодні)" if lang == "uk" else " (due today)"
    return ""


def fill_from_tracker(facts: Dict[str, List[dict]], tr: Optional[dict], src_id: Optional[str], lang: str, checked: str,
                      wanted: Optional[set] = None) -> int:
    """When the model left On me today or Waiting on others without a real line and the Tracker has items: the Tracker's
    lines (today: overdue and due today first, else the top three on me; waiting: the top four). Returns facts added."""
    if not tr or not src_id:
        return 0
    added = 0
    if (wanted is None or "standup_today" in wanted) and not real(facts.get("standup_today") or []) and tr.get("on_me"):
        urgent = [x for x in tr["on_me"] if x.get("state") in ("overdue", "today")]
        pick = (urgent or tr["on_me"])[:5 if urgent else 3]
        facts["standup_today"] = [{"label": "Tracker", "text": x["text"] + _overdue_note(x, lang), "source_ids": [src_id],
                                   "locator": {"quote": x["text"][:120]}, "checked_at": checked, "status": "found",
                                   "origin": "model"} for x in pick]
        added += len(pick)
    if (wanted is None or "standup_waiting" in wanted) and not real(facts.get("standup_waiting") or []) and tr.get("waiting"):
        pick = tr["waiting"][:4]
        facts["standup_waiting"] = [{"label": x["owner"], "text": f"{x['owner']}: {x['text']}", "source_ids": [src_id],
                                     "locator": {"quote": x["text"][:120]}, "checked_at": checked, "status": "found",
                                     "origin": "model", "value": {"owner": x["owner"]}} for x in pick]
        added += len(pick)
    return added
