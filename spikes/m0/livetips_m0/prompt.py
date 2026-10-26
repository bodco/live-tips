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
{address_rule}
- Classify says need_tip only when the tip would carry something concrete from the brief, fact book, cards or transcript; with no brief and no facts, only red triggers (a direct question, the PM's turn, a new request, a commitment) need a tip.
- Never answer a question with a fact that is not in the brief, fact book, cards or transcript. No fact = skip.
- The phrase uses the language the PM speaks with these people on this call (look at the PM's own lines).
- Prefer the newest topic. A tip about something the talk has left is noise.
- Numbers, names and dates come only from the brief, the fact book, the cards or the transcript. Never a number you did not see there.
- "tips_given" lists what the PM already saw, with the numbers shown: a tip that repeats a number or a gist from it is noise, even in other words.

Tip diet: one gist line plus at most one phrase or up to {fact_lines} fact lines of max {fact_words} words. One tip per topic, never repeat a tip already given. The topic must be what is discussed in the last {live_topic}s.

Output formats are given in the task at the end of each request.
"""

ADDRESS_STRICT = """- "your_turn" only when the PM is addressed by name AND asked for an update or opinion now. If someone else is giving the update, skip. A name said in the third person ("as Alex said", "Alex will check") is not an address. A turn already tipped stays tipped until the PM has spoken."""

# 2026-10-23 PM sync review: the PM may be expected to answer or add to a question asked to anyone.
ADDRESS_ANY = """- Questions to anyone count: when anyone on the call asks a question (to the PM, to another person or to the room) and the brief, the fact book, the cards or the project current state hold a concrete answer, give it. Who was addressed does not matter. Skip when nothing concrete answers it, it was already answered aloud, or the question is about someone else's project and the brief holds nothing specific on it.
- Never a tip about whose turn it is ("your turn", "your turn soon", "pause, you can start"), even with the speech in it: the PM decides when to speak and already has the speech card. When the PM is asked for an update by name, give only what is new versus the speech card (an answer to the exact question), or skip."""


CLASSIFY_ANY = "A question to anyone counts when the context holds a concrete answer: the PM could give it. Who was addressed does not matter. A mention without a question is not a reason for a tip."
CLASSIFY_STRICT = "A name in the third person is not an address."

CLASSIFY_TASK = """ROLE classify. Do NOT write a tip. Only decide if the PM needs a tip right now for the newest line(s).
Return JSON only: {"need_tip": true|false, "level": "red|orange|none", "trigger": "<trigger id or none>", "topic": "<2-4 words>"}.
need_tip is true only for a trigger in the table AND when the fact book, brief or cards hold something concrete to give, or the PM is asked directly. {address} If the question was already answered in the transcript, false."""

TIP_TASK = """ROLE tip. Event: {event}. Write the tip for the newest line(s), or skip with {{"skip": true, "reason": "..."}}.
Before writing, decide what is NEW: a fact, number, owner, date or sentence that nobody has said aloud yet and that is not in tips_given. If nothing is new, or the PM already answered the question, skip. Skip is the normal outcome; a shown tip is the exception.
Facts marked unverified, "(verify)", "to confirm" or similar are never stated as facts: at most "перевірити: ..." in items.
Tip format (JSON, keys in this order, gist first):
{{"gist": "<emoji + what is happening, max {gist_words} words, in the tips language>", "level": "red|orange|info", "topic": "<2-5 words>", "new": "<what in this tip was not said aloud yet, max 8 words>", "phrase": "<ready sentence the PM can say now, in the answer language; English: simple, max {phrase_words} words>", "items": ["<fact with number>"], "note": "<source, date>", "trigger": "<trigger id>", "fact_ids": ["<ids from the fact book used>"]}}
Emoji: red = 🔴 (direct question: 🎯), orange = 🟠, info = 🟢.
Tips language: {tips_lang}. Answer language (phrase and items): the language the PM is expected to speak right now; on a call in one language only ({langs}) always that language, never English templates.
Return JSON only, gist first."""


# Triggers the skill switches off by meeting concept (hiring.md, SKILL.md "No corrections of the PM on team calls").
INTERVIEW_OFF = {"new_requirement", "pm_commitment", "frustration", "contradicts_decision", "pm_factual_error"}


def disabled_triggers(meta: Optional[dict]) -> set:
    meta = meta or {}
    off = set()
    if meta.get("call_type") == "interview":
        off |= INTERVIEW_OFF
        if meta.get("hiring_role") in ("observer", "interviewer"):
            off.add("your_turn")             # the PM asks or watches; nobody waits for the PM's update
    if meta.get("audience") == "team":
        off.add("pm_factual_error")          # the PM thinks aloud with the team: no corrections
    if not meta.get("turn_tips", False):
        off.add("your_turn")                 # 2026-10-23: the PM starts talking on their own, not on a tip
    if not meta.get("proactive", False):
        # 2026-10-26 review: "Зафіксуй" / "Можеш додати" during other people's talk were noise (as in the
        # skill, proactive.md is off by default). Owners and dates go to the "On me" panel instead.
        off |= {"add_fact", "fix_owner_date"}
    return off


def render_rules(rules, tips_lang: str = "", meta: Optional[dict] = None) -> str:
    d = rules.diet
    off = disabled_triggers(meta)
    trig = "\n".join("- {} {}: {} -> {}".format(t["level"], t["id"], t["skill_trigger"], t["skill_tip"])
                     for t in rules.triggers["triggers"] if t["route"] in ("direct", "classify") and t["id"] not in off)
    return RULES_TEMPLATE.format(
        version=rules.version, priorities=" > ".join(rules.priorities["order"]), triggers=trig,
        fact_lines=d["limits"]["fact_lines_max"], fact_words=d["limits"]["fact_words_max"],
        live_topic=d["live_topic_window_s"],
        address_rule=ADDRESS_ANY if (meta or {}).get("answer_any", True) else ADDRESS_STRICT)


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


# Interview roles, same meaning as the skill's references/hiring.md (hiring_role).
ROLE_NOTES = {
    "observer": "Interview, role observer: the PM is silent and watches; the candidate is the OTHER person. "
                "On a question to the candidate give ONE orange tip: gist = the question verbatim, phrase = what "
                "a strong answer would contain (for comparison, not to be said). After the answer: nothing; never "
                "analyse the PM's or the candidate's replies.",
    "interviewer": "Interview, role interviewer: the PM asks the questions. Tips: the next question to ask, at most "
                   "one orange 'Уточни' follow-up after a long answer that is vague (no numbers, no own role, no "
                   "result), and what is still uncovered; never suggest answers for the candidate.",
    "coach": "Interview, role coach: the PM is the one being interviewed (a job interview, a client asking "
             "about the PM's experience). A question to the PM is a red tip: a short structure for the answer "
             "(situation, action, result with a number), a strength to lead into, and a ready opening sentence. "
             "On money, dates or scope (price, rate, salary, start date, notice period, budget) a red tip "
             "'без цифр зараз' with a sentence that defers the number; never a number.",
}

AUDIENCE_NOTES = {
    "client": "Client call: restricted internal facts may shape a tip, but numbers from them are never stated.",
    "boss": "Client rules (the PM's manager acts as the client): restricted internal facts may shape a tip, "
            "but numbers from them are never stated.",
    "team": "Team call: no corrections of the PM.",
}

TYPE_NOTES = {
    "presentation": "Presentation: the recorder owns the time line; never a timing or pacing tip. In Q&A answer "
                    "audience questions with one fact.",
}


class PromptBuilder:
    def __init__(self, rules, call_meta: dict, brief_path=None, facts_path=None, cards_path=None, extra_context: str = ""):
        self.rules = rules
        lim = rules.diet["limits"]
        self.fmt = {"tips_lang": call_meta.get("tips_lang", "uk"), "gist_words": lim["gist_words_max"],
                    "phrase_words": lim["phrase_words_max_en"], "langs": "+".join(call_meta.get("langs", [])) or "uk"}
        self.meta = dict(call_meta)
        self._brief = _read(brief_path, 40000) or "(no brief)"
        self._extra = extra_context
        self._facts = (facts_path, cards_path)
        self.blocks = []
        self.set_meeting({})

    def corpus(self) -> str:
        """Brief, facts and cards text, for the engine's number validation."""
        return (self._brief or "") + " " + (self.blocks[2]["text"] if len(self.blocks) > 2 else "")

    def refresh_facts(self) -> bool:
        """The prep can land after the start (lt prep-check adopts it): reload the fact book and the
        cards when their files change (review 2026-10-23: the real presentation ran with no facts)."""
        fp, cp = self._facts
        key = tuple((str(p), p.stat().st_mtime if p and p.exists() else None) for p in (fp, cp))
        if key == getattr(self, "_facts_key", None):
            return False
        self._facts_key = key
        self.blocks[2] = {"text": "FACT BOOK AND CARDS:\n" + (facts_block(fp, cp) or "(none)"), "cache": True}
        return True

    def set_meeting(self, change: dict) -> bool:
        """Applies a meeting concept change (call_type, audience, hiring_role) from Start call or the
        window's menu. Rebuilds the rules and header blocks (a new prompt cache prefix from then on).
        Returns True when something changed."""
        new = dict(self.meta, **{k: v for k, v in change.items() if v is not None})
        if self.blocks and new == self.meta:
            return False
        self.meta = call_meta = new
        role = "coach" if call_meta.get("hiring_role") == "candidate" else call_meta.get("hiring_role")
        import datetime as _dt
        today = _dt.date.today()
        header = "Today: {today}. Call: {title}. Project: {project}. Audience: {audience}. Type: {call_type}. Languages: {langs}. " \
                 "The PM's lines are labelled \"{me_label}\"; everyone else \"{them_label}\" (a speaker tag like [S2] may follow). " \
                 "The PM is addressed as: {aliases}.{role}{aud}{typ}".format(
                     role=(" " + ROLE_NOTES[role]) if call_meta.get("call_type") == "interview" and role in ROLE_NOTES else "",
                     aud=(" " + AUDIENCE_NOTES[call_meta.get("audience")]) if call_meta.get("audience") in AUDIENCE_NOTES else "",
                     typ=(" " + TYPE_NOTES[call_meta.get("call_type")]) if call_meta.get("call_type") in TYPE_NOTES else "",
                     today=today.strftime("%A %Y-%m-%d"),
                     title=call_meta.get("title", ""), project=call_meta.get("project", ""),
                     audience=call_meta.get("audience", "auto"), call_type=call_meta.get("call_type", "auto"),
                     langs=", ".join(call_meta.get("langs", [])), me_label=call_meta.get("me_label", ""),
                     them_label=call_meta.get("them_label", ""), aliases=", ".join(call_meta.get("name_aliases", [])))
        if call_meta.get("pm_projects"):
            header += " The PM's own projects: {}. Updates about other projects belong to other people.".format(
                ", ".join(call_meta["pm_projects"]))
        if call_meta.get("participants"):
            header += " Participants: {}. Never address anyone else.".format(", ".join(call_meta["participants"]))
        facts = self.blocks[2] if len(self.blocks) > 2 else {
            "text": "FACT BOOK AND CARDS:\n" + (facts_block(*self._facts) or "(none)"), "cache": True}
        if len(self.blocks) <= 2:
            fp, cp = self._facts
            self._facts_key = tuple((str(p), p.stat().st_mtime if p and p.exists() else None) for p in (fp, cp))
        self.blocks = [
            {"text": render_rules(self.rules, meta=call_meta), "cache": True},
            {"text": header + "\n\nBRIEF:\n" + self._brief + ("\n\n" + self._extra if self._extra else ""), "cache": True},
            facts,
        ]
        return True

    def user(self, role: str, event: str, tail_lines: List[str], state: dict, earlier_lines: List[str] = ()) -> str:
        if role == "classify":
            task = CLASSIFY_TASK.replace("{address}", CLASSIFY_ANY if self.meta.get("answer_any", True) else CLASSIFY_STRICT)
        else:
            task = TIP_TASK.format(event=event, **self.fmt)
        st = json.dumps(state, ensure_ascii=False)
        earlier = "EARLIER IN THE CALL (older lines, for what was already said):\n{}\n\n".format("\n".join(earlier_lines)) if earlier_lines else ""
        return "STATE: {}\n\n{}LIVE TRANSCRIPT (last 90 s, newest last):\n{}\n\n{}".format(st, earlier, "\n".join(tail_lines), task)
