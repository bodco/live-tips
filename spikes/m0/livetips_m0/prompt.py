"""Prompt assembly with a stable, cacheable prefix.

Order of system blocks (each ends with a cache breakpoint, max 4):
  1. rules (from rules/, identical for every call of this rules version)
  2. call header and brief (stable for the call)
  3. fact book and cards (append-only during the call; new facts go to the tail until rebuild)
The user message is the volatile tail: event, state, last ~90 s of transcript, the role task.
"""
import json
from pathlib import Path
from typing import List, Optional

RULES_TEMPLATE = """You are Live Tips, a silent co-pilot for a project manager (PM) during a video call.
You see the live transcript and return ONE JSON object, nothing else.

Rules version {version}.

Invariants:
- Facts or silence. A tip carries a number, a date, a name, a status, a source, a concrete question or a concrete next step. Never generic advice. If nothing useful, return {{"skip": true, "reason": "..."}}.
- No commitments for the PM: never suggest an estimate number, a date or a scope the PM does not own. Estimates come from the engineer.
- Never invent. Every fact comes from the brief, the fact book, the cards or the transcript.
- Never use the long dash. No abbreviations, no ticket keys in tips. Russian is never used.
- Restricted internal facts may shape a tip on a client call but are never stated as numbers.

Priority, highest first: {priorities}. The live topic always beats the plan.

Triggers (level, id, when, what to give):
{triggers}

Context discipline (most common failures, check every time):
- Read the whole transcript you get. If the fact, owner or date was already said aloud by anyone, or the PM already answered, return skip.
- "your_turn" only when the PM is addressed by name AND asked for an update or opinion now. If someone else is giving the update, skip.
- Never answer a question with a fact that is not in the brief, fact book, cards or transcript. No fact = skip.
- The phrase uses the language the PM speaks with these people on this call (look at the PM's own lines).
- Prefer the newest topic. A tip about something the talk has left is noise.

Tip diet: one gist line plus at most one phrase or up to {fact_lines} fact lines of max {fact_words} words. One tip per topic, never repeat a tip already given. The topic must be what is discussed in the last {live_topic}s.

Output formats are given in the task at the end of each request.
"""

CLASSIFY_TASK = """ROLE classify. Do NOT write a tip. Only decide if the PM needs a tip right now for the newest line(s).
Return JSON only: {"need_tip": true|false, "level": "red|orange|none", "trigger": "<trigger id or none>", "topic": "<2-5 words>", "reason": "<max 10 words>"}.
need_tip is true only for a trigger in the table AND when the fact book, brief or cards hold something concrete to give, or the PM is asked directly."""

TIP_TASK = """ROLE tip. Event: {event}. Write the tip for the newest line(s), or skip with {{"skip": true, "reason": "..."}}.
Tip format (JSON, keys in this order, gist first):
{{"gist": "<emoji + what is happening, max {gist_words} words, in the tips language>", "level": "red|orange|info", "phrase": "<ready sentence the PM can say now, in the answer language; English: simple, max {phrase_words} words>", "items": ["<fact with number>"], "note": "<source, date>", "topic": "<2-5 words>", "trigger": "<trigger id>", "fact_ids": ["<ids from the fact book used>"]}}
Emoji: red = 🔴 (direct question: 🎯), orange = 🟠, info = 🟢.
Tips language: {tips_lang}. Answer language: the language the PM is expected to speak right now.
Return JSON only, gist first."""


def render_rules(rules, tips_lang: str = "") -> str:
    d = rules.diet
    trig = "\n".join("- {} {}: {} -> {}".format(t["level"], t["id"], t["skill_trigger"], t["skill_tip"])
                     for t in rules.triggers["triggers"] if t["route"] in ("direct", "classify"))
    return RULES_TEMPLATE.format(
        version=rules.version, priorities=" > ".join(rules.priorities["order"]), triggers=trig,
        fact_lines=d["limits"]["fact_lines_max"], fact_words=d["limits"]["fact_words_max"],
        live_topic=d["live_topic_window_s"])


def _read(p: Optional[Path], limit: int) -> str:
    if p and p.exists():
        return p.read_text(encoding="utf-8", errors="replace")[:limit]
    return ""


def facts_block(facts_path: Optional[Path], cards_path: Optional[Path], limit: int = 30000) -> str:
    out = []
    for p, kind in ((facts_path, "fact"), (cards_path, "card")):
        if not p or not p.exists():
            continue
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except ValueError:
            continue
        items = data if isinstance(data, list) else data.get(kind + "s", data.get("items", []))
        for it in items if isinstance(items, list) else []:
            if not isinstance(it, dict):
                continue
            fid = it.get("id", "")
            text = it.get("text") or it.get("phrase") or ""
            title = it.get("title") or it.get("gist") or ""
            src = it.get("source") or it.get("note") or ""
            out.append("- [{}:{}] {} | {} | {}".format(kind, fid, title, text, src))
    s = "\n".join(out)
    return s[:limit]


class PromptBuilder:
    def __init__(self, rules, call_meta: dict, brief_path=None, facts_path=None, cards_path=None):
        self.rules = rules
        lim = rules.diet["limits"]
        self.fmt = {"tips_lang": call_meta.get("tips_lang", "uk"), "gist_words": lim["gist_words_max"],
                    "phrase_words": lim["phrase_words_max_en"]}
        self.meta = call_meta
        tips_lang = call_meta.get("tips_lang", "uk")
        header = "Call: {title}. Project: {project}. Audience: {audience}. Type: {call_type}. Languages: {langs}. " \
                 "The PM's lines are labelled \"{me_label}\"; everyone else \"{them_label}\" (a speaker tag like [S2] may follow). " \
                 "The PM is addressed as: {aliases}.".format(
                     title=call_meta.get("title", ""), project=call_meta.get("project", ""),
                     audience=call_meta.get("audience", "auto"), call_type=call_meta.get("call_type", "auto"),
                     langs=", ".join(call_meta.get("langs", [])), me_label=call_meta.get("me_label", ""),
                     them_label=call_meta.get("them_label", ""), aliases=", ".join(call_meta.get("name_aliases", [])))
        self.blocks = [
            {"text": render_rules(rules), "cache": True},
            {"text": header + "\n\nBRIEF:\n" + (_read(brief_path, 40000) or "(no brief)"), "cache": True},
            {"text": "FACT BOOK AND CARDS:\n" + (facts_block(facts_path, cards_path) or "(none)"), "cache": True},
        ]

    def user(self, role: str, event: str, tail_lines: List[str], state: dict, earlier_lines: List[str] = ()) -> str:
        task = CLASSIFY_TASK if role == "classify" else TIP_TASK.format(event=event, **self.fmt)
        st = json.dumps(state, ensure_ascii=False)
        earlier = "EARLIER IN THE CALL (older lines, for what was already said):\n{}\n\n".format("\n".join(earlier_lines)) if earlier_lines else ""
        return "STATE: {}\n\n{}LIVE TRANSCRIPT (last 90 s, newest last):\n{}\n\n{}".format(st, earlier, "\n".join(tail_lines), task)
