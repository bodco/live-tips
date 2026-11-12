"""Prompt assembly with a stable, cacheable prefix.

Order of system blocks (each ends with a cache breakpoint, max 4):
  1. rules (from rules/, identical for every call of this rules version)
  2. call header and brief (stable for the call)
  3. fact book and cards (append-only during the call; new facts go to the tail until rebuild)
The user message: the earlier lines of the call as a cached block (0.8.3), then the volatile part: state, the live transcript, the role task.
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

Tip diet: one gist sentence, one short why, then one phrase or up to {fact_lines} fact lines of max {fact_words} words. One tip per topic, never repeat a tip already given. The topic must be what is discussed in the last {live_topic}s.
How a tip sounds (2026-11-05, owner: tips read like telegrams and had to be re-read): write as a colleague who whispers to the PM, in full plain sentences with verbs, never a label or a noun pile. The PM must understand the situation in one read and be able to build his own answer from the tip, even without the phrase.
- gist: who does what and what it means for the PM ("Mike asks who signs off security", "Emily thinks the pilot starts Monday, it is the 10th"), never a topic title ("Security sign-off owner").
- why: what the PM needs to know to answer: what exactly is asked or claimed, what the brief or the facts say, and what to watch for (a trap, a commitment to avoid). Plain words, no abbreviations.
- phrase: what the PM can say, as people talk: a short answer first, then one sentence of reason or next step.

Output formats are given in the task at the end of each request.
"""

ADDRESS_STRICT = """- "your_turn" only when the PM is addressed by name AND asked for an update or opinion now. If someone else is giving the update, skip. A name said in the third person ("as Alex said", "Alex will check") is not an address. A turn already tipped stays tipped until the PM has spoken."""

# 2026-10-23 PM sync review: the PM may be expected to answer or add to a question asked to anyone.
ADDRESS_ANY = """- Questions to anyone count: when anyone on the call asks a question (to the PM, to another person or to the room) and the brief, the fact book, the cards or the project current state hold a concrete answer, give it. Who was addressed does not matter. Skip when nothing concrete answers it, it was already answered aloud, or the question is about someone else's project and the brief holds nothing specific on it.
- Never a tip about whose turn it is ("your turn", "your turn soon", "pause, you can start"), even with the speech in it: the PM decides when to speak and already has the speech card. When the PM is asked for an update by name, give only what is new versus the speech card (an answer to the exact question), or skip."""


CLASSIFY_ANY = ("A question to anyone counts when the context holds a concrete answer: the PM could give it. Who was addressed does not matter. "
                "A mention without a question is not a reason for a tip, with one exception (0.9.2): answer_in_primary, when the other side "
                "states something (a claim, a doubt, a pain) that the fact book, the cards or the brief answer with a ready answer, proof or "
                "caveat, and nobody said it aloud yet; name the topic so the same one is not tipped twice.")
CLASSIFY_STRICT = "A name in the third person is not an address."

CLASSIFY_TASK = """ROLE classify. Do NOT write a tip. Only decide if the PM needs a tip right now for the newest line(s).
Return JSON only: {"need_tip": true|false, "level": "red|orange|none", "trigger": "<trigger id or none>", "topic": "<2-4 words>"}.
need_tip is true only for a trigger in the table AND when the fact book, brief or cards hold something concrete to give, or the PM is asked directly. {address} If the question was already answered in the transcript, false."""

TIP_TASK = """ROLE tip. Event: {event}. Write the tip for the newest line(s), or skip with {{"skip": true, "reason": "..."}}.
When someone needs something from the PM (a question, a request, a "what did you find") and the context here does not hold it, but the project may (earlier calls, research and notes the PM or Claude made in the project folder, Notion pages), add "search": "<what to find, in your own words>" to the tip or to the skip; the project is then searched and the answer comes as its own card. Decide this from the moment, not from the words: who needs what, and whether the PM has it at hand.
Before writing, decide what is NEW: a fact, number, owner, date or sentence that nobody has said aloud yet and that is not in tips_given. If nothing is new, or the PM already answered the question, skip. Skip is the normal outcome; a shown tip is the exception.
Facts marked unverified, "(verify)", "to confirm" or similar are never stated as facts: at most "перевірити: ..." in items.
Tip format (JSON, keys in this order, gist first):
{{"gist": "<emoji + one plain sentence: who says or asks what and what it means for the PM, max {gist_words} words, in the tips language>", "level": "red|orange|info", "topic": "<2-5 words>", "new": "<what in this tip was not said aloud yet, max 8 words>", "why": "<1-2 plain sentences in the tips language: the context the PM needs to answer (what exactly is asked, what the brief or facts say, what to avoid), max {why_words} words; empty when the gist says it all>", "phrase": "<what the PM can say now, in the answer language, 1-3 natural spoken sentences: the answer first, then a reason or next step; English: simple words, max {phrase_words} words>", "items": ["<fact with number>"], "note": "<source, date>", "trigger": "<trigger id>", "fact_ids": ["<ids from the fact book used>"]}}
Emoji: red = 🔴 (direct question: 🎯), orange = 🟠, info = 🟢.
Tips language: {tips_lang}. Answer language (phrase and items): the language the PM is expected to speak right now; on a call in one language only ({langs}) always that language, never English templates.
Return JSON only, gist first."""


# Triggers the skill switches off by meeting concept (hiring.md, SKILL.md "No corrections of the PM on team calls").
INTERVIEW_OFF = {"new_requirement", "pm_commitment", "frustration", "contradicts_decision", "pm_factual_error",
                 "scope_pushback", "value_doubt", "answer_in_primary"}   # 0.9.2: the PM listens, no counter-answers


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
        address_rule=_address_rule(meta))


def _address_rule(meta: Optional[dict]) -> str:
    """0.10.0 co-driver (owner 2026-11-12): questions to anyone, and a search instead of a skip (livetips_m0.codriver)."""
    meta = meta or {}
    if not meta.get("answer_any", True):
        return ADDRESS_STRICT
    if meta.get("codriver", True):
        from .codriver import ADDRESS_CODRIVER
        return ADDRESS_ANY + "\n" + ADDRESS_CODRIVER
    return ADDRESS_ANY


def _read(p: Optional[Path], limit: int) -> str:
    if p and p.exists():
        return p.read_text(encoding="utf-8", errors="replace")[:limit]
    return ""


def facts_block(facts_path: Optional[Path], cards_path: Optional[Path], limit: int = 30000) -> str:
    out = []
    for p, kind in ((facts_path, "fact"), (cards_path, "card")):
        out += fact_lines(_json_file(p), kind)
    return "\n".join(out)[:limit]


def _json_file(p: Optional[Path]):
    if not p or not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except ValueError:
        return None


def fact_lines(data, kind: str) -> List[str]:
    """"- [fact:<id>] title | text | source" lines from a fact book or a card file (a list or {facts|cards|items: [...]})."""
    if data is None:
        return []
    items = data if isinstance(data, list) else data.get(kind + "s", data.get("items", []))
    return [fact_line(kind, it) for it in (items if isinstance(items, list) else []) if isinstance(it, dict)]


def fact_line(kind: str, it: dict) -> str:
    return "- [{}:{}] {} | {} | {}".format(kind, it.get("id", ""), it.get("title") or it.get("gist") or "",
                                          it.get("text") or it.get("phrase") or "", it.get("source") or it.get("note") or "")


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


def files_key(*paths) -> tuple:
    """Paths with their modification times: a change of any file changes the key."""
    return tuple((str(p), p.stat().st_mtime if p and p.exists() else None) for p in paths)


def meeting_notes(meta: dict) -> str:
    """The interview role, audience and call type notes that apply to this call."""
    role = "coach" if meta.get("hiring_role") == "candidate" else meta.get("hiring_role")
    notes = [ROLE_NOTES[role]] if meta.get("call_type") == "interview" and role in ROLE_NOTES else []
    notes += [AUDIENCE_NOTES[meta["audience"]]] if meta.get("audience") in AUDIENCE_NOTES else []
    notes += [TYPE_NOTES[meta["call_type"]]] if meta.get("call_type") in TYPE_NOTES else []
    return "".join(" " + n for n in notes)


def people_notes(meta: dict) -> str:
    out = ""
    if meta.get("pm_projects"):
        out += " The PM's own projects: {}. Updates about other projects belong to other people.".format(
            ", ".join(meta["pm_projects"]))
    if meta.get("participants"):
        out += " Participants: {}. Never address anyone else.".format(", ".join(meta["participants"]))
    return out


def call_header(meta: dict, today) -> str:
    """The call's header line for the prompt: date, call, audience, type, languages, labels and meeting notes."""
    return "Today: {today}. Call: {title}. Project: {project}. Audience: {audience}. Type: {call_type}. Languages: {langs}. " \
           "The PM's lines are labelled \"{me_label}\"; everyone else \"{them_label}\" (a speaker tag like [S2] may follow). " \
           "The PM is addressed as: {aliases}.{notes}".format(
               notes=meeting_notes(meta), today=today.strftime("%A %Y-%m-%d"),
               title=meta.get("title", ""), project=meta.get("project", ""),
               audience=meta.get("audience", "auto"), call_type=meta.get("call_type", "auto"),
               langs=", ".join(meta.get("langs", [])), me_label=meta.get("me_label", ""),
               them_label=meta.get("them_label", ""), aliases=", ".join(meta.get("name_aliases", []))) + people_notes(meta)


class PromptBuilder:
    def __init__(self, rules, call_meta: dict, brief_path=None, facts_path=None, cards_path=None, extra_context: str = ""):
        self.rules = rules
        lim = rules.diet["limits"]
        self.fmt = {"tips_lang": call_meta.get("tips_lang", "uk"), "gist_words": lim["gist_words_max"],
                    "phrase_words": lim["phrase_words_max_en"], "why_words": lim.get("why_words_max", 35), "langs": "+".join(call_meta.get("langs", [])) or "uk"}
        self.meta = dict(call_meta)
        self._brief = _read(brief_path, 40000) or "(no brief)"
        self._brief_path = brief_path
        self._brief_key = (brief_path.stat().st_mtime if brief_path and Path(brief_path).exists() else None)
        self._extra = extra_context
        self._correction = ""          # 0.9.x: the PM's live correction, in the cached brief block
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
        key = files_key(fp, cp)
        if key == getattr(self, "_facts_key", None):
            return False
        self._facts_key = key
        self.blocks[2] = {"text": "FACT BOOK AND CARDS:\n" + (facts_block(fp, cp) or "(none)"), "cache": True}
        return True

    def refresh_brief(self) -> bool:
        """2026-10-27 (owner): a preparation that finishes after the call started is picked up mid-call.
        Reloads the brief when its file appears or changes; returns True when it did."""
        bp = self._brief_path
        if not bp or not Path(bp).exists():
            return False
        key = Path(bp).stat().st_mtime
        if key == self._brief_key:
            return False
        text = _read(bp, 40000)
        if not text:
            return False
        self._brief_key, self._brief = key, text
        self.blocks = []
        self.set_meeting({})          # rebuilds the blocks with the new brief (a new cache prefix)
        return True

    def set_meeting(self, change: dict) -> bool:
        """Applies a meeting concept change (call_type, audience, hiring_role) from Start call or the
        window's menu. Rebuilds the rules and header blocks (a new prompt cache prefix from then on).
        Returns True when something changed."""
        new = dict(self.meta, **{k: v for k, v in change.items() if v is not None})
        if self.blocks and new == self.meta:
            return False
        self.meta = call_meta = new
        import datetime as _dt
        header = call_header(call_meta, _dt.date.today())
        facts = self.blocks[2] if len(self.blocks) > 2 else {
            "text": "FACT BOOK AND CARDS:\n" + (facts_block(*self._facts) or "(none)"), "cache": True}
        if len(self.blocks) <= 2:
            self._facts_key = files_key(*self._facts)
        self.blocks = [
            {"text": render_rules(self.rules, meta=call_meta), "cache": True},
            {"text": header + "\n\nBRIEF:\n" + self._brief + ("\n\n" + self._extra if self._extra else "")
                     + ("\n\n" + self._correction if self._correction else ""), "cache": True},
            facts,
        ]
        return True

    def set_correction(self, text: str) -> None:
        """The PM's correction during the call (rules/live_prep.yaml > correction): rebuilt into the cached brief block,
        so every later request has it once, at the cost of one new cache prefix."""
        if text == self._correction:
            return
        self._correction = text
        self.blocks = []
        self.set_meeting({})

    def user(self, role: str, event: str, tail_lines: List[str], state: dict, earlier_lines: List[str] = ()) -> str:
        if role == "classify":
            addr = CLASSIFY_ANY if self.meta.get("answer_any", True) else CLASSIFY_STRICT
            if self.meta.get("answer_any", True) and self.meta.get("codriver", True):
                from .codriver import CLASSIFY_CODRIVER     # 0.10.0 co-driver (owner 2026-11-12)
                addr = CLASSIFY_ANY + " " + CLASSIFY_CODRIVER
            task = CLASSIFY_TASK.replace("{address}", addr)
        else:
            task = TIP_TASK.format(event=event, **self.fmt)
        st = json.dumps(state, ensure_ascii=False)
        if role != "classify" and state.get("pm_ratings"):
            # 0.9.4 (rules/learning.yaml > tip_rating): act by the reason, the comment wins; never mute a red tip or a fact
            task += ("\nSTATE.pm_ratings are the PM's ratings of earlier tips in this call (partly = fine but off the point, "
                     "not_useful = no). Act by the reason: off_topic = fewer tips of that kind, too_long = shorter, "
                     "wrong_fact = do not repeat that fact, late or not_now = no change. His comment wins over the reasons.")
        now = "STATE: {}\n\nLIVE TRANSCRIPT (the last minutes, newest last):\n{}\n\n{}".format(st, "\n".join(tail_lines), task)
        if not earlier_lines:
            return now
        # 0.8.3 (prompt caching): the earlier lines change only every 2 minutes, so they come first and are
        # read from the cache; the state, the live lines and the task change on every request and come after.
        earlier = "EARLIER IN THE CALL (older lines, for what was already said):\n{}\n\n".format("\n".join(earlier_lines))
        return [{"text": earlier, "cache": "5m"}, {"text": now}]
