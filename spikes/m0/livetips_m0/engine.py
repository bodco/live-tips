"""Event-driven tip engine: local signals -> (classify) -> tip -> diet -> window file.

Times: every timestamp in spans is "call seconds of day" from the injected clock, so it can be
compared with the recorder's seg_end. Monotonic time is used for durations of model calls.
"""
import functools
import json
import re
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

import jsonschema

from . import usage
from . import agenda as agenda_mod
from . import commitments as register
from .cost import cost_usd
from .prompt import disabled_triggers
from .providers import HedgedProvider
from .signals import Detector
from .situation import jaccard, next_situation
from .transcript import Line, s_to_hms

WORD = re.compile(r"\w+", re.UNICODE)

# Meeting concept in code (2026-10-23, from the skill's hiring.md, presentation.md, SKILL.md "Tip diet").
# Coach role: money, dates and scope asked of the PM get a red "no numbers now" tip.
COACH_MONEY_CUES = ["price", "cost", "rate", "salary", "start date", "notice period", "budget",
                    "цінов", "вартіст", "ставк", "зарплат", "дата старту", "дату старту", "бюджет"]
COACH_MONEY_WORDS = {"ціна", "ціни", "ціну", "ціні", "ціною", "rate", "rates", "cost", "costs"}
MEETING_EXEMPT_PER_MIN = 2           # hiring tips ignore the orange rate, max 2 per minute
INTERVIEWER_ANSWER_WORDS = 40        # a them answer this long gets at most one "Уточни" tip
INTERVIEWER_MORE_WORDS = 150        # 2026-11-02: and one more for every 150 words the same answer goes on
TEAM_TIPS_PER_HOUR = 12              # team audience: non-red model tips per hour
QA_SHARE_MAX = 0.40                  # presentation Q&A: the PM's share below this for QA_WINDOW_S
QA_WINDOW_S = 60
PACING = re.compile(r"(time left|minutes? left|min left|pace|pacing|behind schedule|skip (the )?slides?|speed up|"
                    r"хвилин\w* (лишил|залишил)|залишилось \d+ ?хв|лишилось \d+ ?хв|темп|пропусти слайд|прискор|\bтаймінг|⏱)",
                    re.I | re.U)
OBSERVER_EVENT = ("Interview, role observer: the other side asked the candidate a question. Give ONE orange tip: gist = "
                  "the interviewer's question VERBATIM (merge rephrasings into one question, the 7-word limit does not "
                  "apply), phrase = what a strong answer contains, 4-5 sentences in the interview language, note = "
                  "'for comparison, not to say' written in the tips language. Never analyse the PM. trigger direct_question.")
# 0.9.x (owner, 2026-11-04): the interviewer gets answers to the other side's questions to them, and never a tip
# that answers for the interviewee.
GIST_REPEAT_S = 300                  # a non-red gist repeated within 5 minutes is dropped (rules/diet.yaml)
GIST_REPEAT_MIN = 0.6                # token overlap of the gists' content words
_GIST_LABELS = {"clarify", "уточни", "уточнити", "add", "додай", "fix", "зафіксуй", "ask", "спитай", "now", "зараз", "що"}


def gist_core(gist: str) -> set:
    """The content words of a gist: no emoji, no label words ("Clarify:", "Уточни"), no short words."""
    words = re.findall(r"[\w'ʼ’]+", gist.lower())
    return {w for w in words if len(w) > 2 and w not in _GIST_LABELS}


def jaccard_sets(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


RED_LATE_FACTOR = 2                  # a red tip may land up to 2 x stale_after_s after its speech (shown as late)
CORRECTION_MAX = 2000                # the PM's correction: who, goal, document; long text belongs in the prep
ANSWER_IN_PRIMARY_NOTE = ("\nThe other side stated something (not a question) that the prepared material answers: give the ready "
                          "answer, proof or caveat from the fact book, the cards or the brief, with fact_ids and the source. Skip only "
                          "when it was said aloud already or nothing concrete answers it.")
INTERVIEWER_ROLE_NOTE = ("\nThe PM is the interviewer (also in discovery interviews). When the other person asks the PM a question, "
                         "answer it for the PM from the brief and the facts. Otherwise never answer on behalf of the interviewee "
                         "or repeat their answer as a PM statement: give one open follow-up question, or nothing when it is "
                         "already answered. Address the current speaker, not the person named in an older brief.")
INTERVIEWER_EVENT = ("Interview, role interviewer: the other person (a candidate, or a colleague or user in a discovery or "
                     "research interview) just gave a long answer to the PM's question. Give ONE orange tip: gist starting with "
                     "'🟠 ' and 'Clarify: ' in the tips language, phrase = ONE open follow-up question the PM can ask now, in the "
                     "interview language, that digs into what was just said: the last concrete case (when, who, what happened next), "
                     "how often or how many, show it on screen, why it is done that way, what it costs or breaks; or the next "
                     "checklist or card question the answer leads to (cards Q1-Qn, their follow-ups). Never a yes/no or leading "
                     "question, never suggest answers. Skip only when the answer already gave a concrete case with numbers and "
                     "the next checklist question was asked. trigger add_fact.")
COACH_QUESTION_EVENT = ("Interview, role coach: the PM is being asked a question. Give ONE red tip: gist = what is asked, "
                        "phrase = a ready opening sentence, items = situation, action, result with a number, only from the "
                        "brief, the fact book or the cards. trigger direct_question.")
COACH_MONEY_EVENT = ("Interview, role coach: the other side asks about money, dates or scope (price, rate, salary, start date, "
                     "notice period, budget). Give ONE red tip: gist like '🔴 No numbers now' in the tips language, phrase = a calm sentence that "
                     "defers the number (for example 'I would like to understand the scope first and come back with a "
                     "number'), never a number. trigger direct_question.")
QA_EVENT = ("Presentation Q&A: someone in the audience asks a question after the talk. Answer it with one fact from the "
            "brief, the fact book or the cards, or skip. Never a timing or pacing tip. trigger direct_question.")


def meeting_role(meta: Optional[dict]) -> str:
    """observer, interviewer or coach on an interview call (legacy "candidate" = coach), else ""."""
    meta = meta or {}
    if meta.get("call_type") != "interview":
        return ""
    r = meta.get("hiring_role") or ""
    return "coach" if r == "candidate" else r


_HEAD_STR = r'"{}"\s*:\s*"((?:[^"\\]|\\.)*)"'


def partial_head(buf: str) -> Optional[dict]:
    """gist, level and topic from a streaming tip JSON once all three are complete (topic may be
    absent for red tips: red is shown on gist + level). None while incomplete or for a skip."""
    if '"skip"' in buf[:40]:
        return None
    out = {}
    for k in ("gist", "level", "topic"):
        m = re.search(_HEAD_STR.format(k), buf)
        if m:
            try:
                out[k] = json.loads('"' + m.group(1) + '"')
            except ValueError:
                return None
    if not out.get("gist") or out.get("level") not in ("red", "orange", "info"):
        return None
    if out["level"] != "red" and "topic" not in out:
        return None
    return out


# 0.9.2 (rules/ai.yaml > openai): a model running on after its answer writes stray tokens ("ેણ", "_REALTYPE").
# Call languages are written in these scripts; letters of any other one in a tip mean the text is garbled.
TIP_SCRIPTS = ("LATIN", "CYRILLIC", "GREEK")
GARBLED_TOKEN = re.compile(r"(?<![\w/.])_[A-Z]{4,}\b")


def garbled(obj: dict, keys=("gist", "why", "phrase", "note", "items")) -> Optional[str]:
    """Why a tip's text looks garbled ("foreign script", "token"), else None."""
    parts = []
    for k in keys:
        v = obj.get(k)
        parts += v if isinstance(v, list) else [v]
    text = " ".join(str(x) for x in parts if x)
    if sum(1 for ch in text if unicodedata.category(ch)[0] in "LM"
           and not unicodedata.name(ch, "").startswith(TIP_SCRIPTS + ("COMBINING", "MODIFIER LETTER"))) >= 2:
        return "foreign script"
    if GARBLED_TOKEN.search(text):
        return "token"
    return None


DECIDE_ITEM = re.compile(r"\b(agree|decide|approve|confirm|sign off)|погод|виріш|затверд|підтверд|узгод", re.I)


def decided_on(item: str, decisions: List[str]) -> bool:
    """A decision of the call shares 2+ word stems (5 letters) with the agenda item."""
    stems = lambda t: {w[:5] for w in re.findall(r"[\w'’]{4,}", t.lower())}  # noqa: E731
    want = stems(re.sub(DECIDE_ITEM, " ", item))
    return any(len(want & stems(d)) >= 2 for d in decisions)


def first_json(text: str) -> Optional[dict]:
    i = text.find("{")
    while i >= 0:
        try:
            obj, _ = json.JSONDecoder().raw_decode(text[i:])
            if isinstance(obj, dict):
                return obj
        except ValueError:
            pass
        i = text.find("{", i + 1)
    return None



def load_active_decisions(project_dir: str, limit: int = 30) -> list:
    """0.8.8 (rules/decisions.yaml > snapshot): <project>/pacenote/decisions.md, written before the preparation."""
    if not project_dir:
        return []
    try:
        from .decision_notion import parse_snapshot
        return parse_snapshot((Path(project_dir) / "pacenote" / "decisions.md").read_text(encoding="utf-8"))[:limit]
    except (OSError, ValueError):
        return []


def decision_conflict_card(d: dict, c: dict, t: str, uk: bool) -> dict:
    """The card of rules/decisions.yaml > during_call: "<DD.MM> decided: X (who)" and one sentence to remind them."""
    date = str(d.get("date") or "")
    dm = "{}.{}".format(date[8:10], date[5:7]) if len(date) >= 10 else date
    who = " ({})".format(d["stated_by"]) if d.get("stated_by") else ""
    gist = "{} {}: {}{}".format(dm, "вирішили" if uk else "decided", d.get("title", ""), who).strip()
    remind = str(c.get("remind") or "").replace(chr(0x2014), "-").strip()
    return {"schema_version": 1, "engine": "app", "kind": "decision_conflict", "level": "info", "t": t, "at": t,
            "src": c.get("t") or t, "who": str(c.get("who") or ""), "gist": gist, "items": [remind] if remind else []}

class JsonlWriter:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, obj: dict) -> None:
        with self.lock, self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False, default=lambda o: str(type(o).__name__)) + "\n")


# 2026-10-26 review: the engine keeps a running picture of the call (Haiku, every ~10 s) instead of
# judging every line alone: the topic and whose it is, open asks to the PM, what the PM took on,
# decisions, which speech points were said. The window shows it as a status line and an "On me" panel.
SITUATION_SYS = """You keep the running state of a video call for a project manager (the PM). The PM's lines are labelled "{me}"; the PM is addressed as: {aliases}. The PM's own projects: {projects}. Participants: {people}. Today: {today}.
Return JSON only, no prose:
{{"topic": "<what is discussed now, max 6 words, in {lang}>", "owner": "<who leads this topic: a name, PM, or empty; never a transcript channel label>", "mine": true|false, "floor": "<who speaks now: a name or PM>",
 "asks": [{{"id": "a1", "t": "<HH:MM:SS of the line>", "who": "<name>", "what": "<what the PM is asked, max 12 words, in {lang}>", "type": "question|request|update"}}],
 "actions": [{{"id": "m1", "what": "<what the PM must do, max 12 words, in {lang}>", "due": "<day or date, or empty>", "from": "<who asked, or PM>"}}],
 "decisions": ["<a decision made on this call, max 14 words, in {lang}>"],
 "speech_done": [<numbers of the PM's speech points already said aloud by the PM>]}}
Rules:
- mine = the topic is about the PM's projects or work, or the PM is asked or assigned something in it. Someone else's update about their own project is not mine.
- asks = OPEN questions or requests TO THE PM: by name, by "you" after the PM spoke, or about the PM's projects; also a request said in the third person ("Alex will check"). type update = the PM is asked for their status or given the floor for their update (also by a nickname or short form of the PM's name, "давай", "твоя черга", "over to you", or the host moving to the PM's projects). Remove an ask once the PM answered it or did it. Questions to other people, and questions the PM asked others, are not asks.
- actions = only what the PM personally took on in the PM's own lines ("{me}": "I will...", "я зроблю...") or what someone explicitly assigned to the PM by name or "you" in reply to the PM (keep them until the call ends, update the due date when it changes). The PM taking an item over counts too: "це на мені", "я беру", "беру на себе", "I'll take it", "that's on me" said by the PM after an item makes that item the PM's action. NEVER an item from someone else's update about their own work, even in the first person ("I will prepare the report for Brian" said by another speaker is THEIR task), never a task for another named person, never a general to-do of the team. When unsure who owns it, leave it out.
- decisions = only decisions actually agreed aloud, keep them all.
- speech_done = only points the PM said aloud in the PM's own lines ("{me}"); nobody else's update counts. Empty until the PM gives the update.
- Keep the ids of items you keep; new items get new ids. Never invent: only what was said."""

SITUATION_STRONG = re.compile(r"(\?|\b(you|your|ти|тобі|тебе|твій|твоя|ваш|вам|вас|can you|could you|зможеш|можеш|глянь|подивись|перевір|скинь|надішли|зроби)\b)", re.I)

# "Your turn", "your turn soon", "pause: you can start" (PM sync review 2026-10-23).
TURN_GIST = re.compile(r"(твоя черга|твій черг|черга .{0,12}тебе|можеш почати|your turn|you can start|over to you)", re.I)


def context_windows(lines, end: float, span: float, bucket: float, tail_s: float = 90):
    """Split the call so far into the earlier lines and the live tail (0.8.3, prompt caching).

    The border between them moves in fixed `bucket` steps, not with every new line, so every request inside
    one bucket starts with the same earlier lines and reads them from the cache. The tail is at least
    `tail_s` seconds and at most `tail_s + bucket`. Lines are in time order and have `t_s`."""
    cut = ((end - tail_s) // bucket) * bucket if bucket else end - tail_s
    lines = [l for l in lines if l.t_s <= end]
    earlier = [l for l in lines if cut - span < l.t_s <= cut]
    return earlier, [l for l in lines if l.t_s > cut]


# 2026-10-26 client call: 16 red tips in 33 min, most for questions to the room. Red is for the PM:
# addressed by name or "you", a new request, the PM's commitment, or an open ask the call picture found.
RED_TRIGGERS = ("new_requirement", "pm_commitment", "contradicts_decision", "pm_factual_error",
                "scope_pushback", "value_doubt")


def demote_red(obj: dict, trigger: str, span: dict) -> None:
    if obj.get("level") != "red" or span.get("to_pm") or span.get("force_level") or obj.get("trigger", trigger) in RED_TRIGGERS:
        return
    obj["level"] = "orange"
    if obj.get("gist", "").startswith(("🎯", "🔴")):
        obj["gist"] = "🟠" + obj["gist"][1:]


def tip_timing(span: dict, c, done: float) -> None:
    span["tip_ttft_ms"] = c.ms(c.t_first_token)
    span["tip_gist_ms"] = c.ms(c.t_gist)
    span["tip_ms"] = c.ms(c.t_done)
    if c.t_gist is not None:
        span["gist_at"] = span["tip_start"] + (c.t_gist - c.t_start)
    span["tip_done"] = done


def tip_item(obj: dict, uid: str, line: Line, trigger: str, done: float, late: bool) -> dict:
    item = {"schema_version": 1, "engine": "app", "uid": uid, "t": s_to_hms(done), "src": line.t, "kind": "tip",
            "level": obj.get("level", "orange"), "gist": obj["gist"], "why": obj.get("why", ""), "phrase": obj.get("phrase", ""),
            "items": obj.get("items", []), "note": obj.get("note", ""), "topic": obj.get("topic", ""),
            "trigger": obj.get("trigger", trigger), "fact_ids": obj.get("fact_ids", []),
            "at": s_to_hms(done), "late": late}
    return {k: v for k, v in item.items() if v not in ("", [], None) or k == "late"}


SOS_EVENT = ("HELP NOW pressed: the PM is speaking and cannot type. Give ONE red tip now: gist starting with "
                     "'🆘 ', the next sentence the PM can say right now (answer to the open question, a fact with its number, "
                     "or a bridge such as 'Let me give you the exact number after the call.'), up to 2 fact lines. Never skip. Add \"answered\": false when no concrete fact answers the open question (a deeper search then starts by itself).")
ASK_TAIL = (" Add \"answered\": true when the context really answers it, false otherwise. Never skip a typed "
                      "question: when the answer is not here, gist says what is known nearest, phrase is a sentence the PM "
                      "can say right now (an honest bridge such as checking and coming back with a date), and a deeper "
                      "search of the project folder starts by itself.")


# 2026-11-02 (owner, two calls): "Anything else you wanted to go over today?" got "Nope, my list is closed" while four
# brief items were still open, and "що я там ще забув?" got "no question to you". The wrap check lists what is not
# covered yet: agenda items and the brief's "Decisions to obtain", checked against the whole transcript.
ANY_ELSE = re.compile(r"\b(anything else|any(thing)? other (questions?|items?|topics?|things?)|what else|something else|"
                      r"anything (you wanted|we should|i('m| am) (missing|forgetting))|is that (all|everything)|"
                      r"щось ще|що ще (є|в тебе|у вас|обговори|додати)|ще якісь (питання|теми)|є ще (питання|щось)|"
                      r"чи все|це все\?)", re.I | re.U)
WRAP_SAY = re.compile(r"\b(my list is|that'?s (all|it) from (me|my side)|nothing else from (me|my side)|i think we covered|"
                      r"we covered (everything|it all)|по всьому пройшли|все пройшли|в мене все|у мене все|більше питань нема|"
                      r"ми все покрили|покрили з того)", re.I | re.U)
WRAP_ASK = re.compile(r"(забув|забула|пропустив|не спитав|не обговорили|що ще|що лишилось|що залишилось|forgot|forget|missed|"
                      r"what else|not covered|what is left|what's left|anything left)", re.I | re.U)
WRAP_GAP_S = 300
WRAP_MIN_S = 480          # not in the first 8 minutes of the call
WRAP_EVENT = ("WRAP CHECK: the call may be ending (someone asked whether there is anything else, the PM said he is done, "
              "or the PM asked what he forgot). Compare the WHOLE CALL TRANSCRIPT below with the AGENDA and DECISIONS TO "
              "OBTAIN. Give ONE red tip: gist like '🎯 Not covered yet: N' in the tips language; items = up to 5 items "
              "that were NOT really talked about or NOT obtained (an item only named in passing counts as not covered; "
              "the agenda states are a hint, the transcript decides; never list an item marked [skip], the PM dropped it), each a short line the PM can raise now; phrase = "
              "one sentence in the call language to raise the first one (for example 'One more thing before we go: ...'). "
              "When everything was covered: gist '✅ All covered' in the tips language, items = the 1-2 next steps with "
              "owner and date heard on the call, or 'next step has no date' when none was said. Never skip.")


def not_answered(obj: Optional[dict]) -> bool:
    return (not obj) or bool(obj.get("skip")) or obj.get("answered") is False


def no_ready_answer(kind: str, uk: bool, searching: bool = True) -> dict:
    gist = ("🆘 " if kind == "sos" else "") + ("Готової відповіді немає, шукаю в папці проєкту" if uk else
                                                   "No ready answer, searching the project folder")
    if not searching:
        gist = "Готової відповіді немає" if uk else "No ready answer"
    phrase = ("Дайте мені хвилину, я перевірю і скажу точно." if uk else "Give me a minute, I will check and tell you exactly.")
    return {"gist": gist, "phrase": phrase, "level": "info", "topic": kind}


def request_item(obj: dict, kind: str, text: str, src: str, done: float) -> dict:
    item = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": src,
            "kind": "tip" if kind == "sos" else "answer", "level": "red" if kind == "sos" else obj.get("level", "info"),
            "gist": obj.get("gist", ""), "why": obj.get("why", ""), "phrase": obj.get("phrase", ""), "items": obj.get("items", []),
            "note": obj.get("note", ""), "at": s_to_hms(done)}
    if kind == "ask":
        item["q"] = text
    return {k: v for k, v in item.items() if v not in ("", [], None)}


SPEECH_JSON = re.compile(r"^##\s*speech\.json\s*\n(\{.*?\})\s*$", re.M | re.S)
SPEECH_SECTION = re.compile(r"^##\s*(?:\d+\.\s*)?(?:Мій спіч|Твій спіч|My speech|Your speech|My update|Мій апдейт)[^\n]*\n(.*?)(?=^##\s|\Z)",
                            re.M | re.S | re.I)


def speech_cards(text: str) -> List[dict]:
    """Speech cards already written to a tips file, oldest first."""
    out = []
    for ln in text.splitlines():
        if '"speech"' not in ln:
            continue
        try:
            it = json.loads(ln)
        except ValueError:
            continue
        if it.get("kind") == "speech":
            out.append(it)
    return out


def speech_from_brief(brief_text: str, default_gist: str):
    """The ready "## speech.json" item of the brief, else one built from the speech section, else None."""
    return speech_json(brief_text) or speech_section(brief_text, default_gist)


def speech_json(brief_text: str):
    m = SPEECH_JSON.search(brief_text)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def speech_section(brief_text: str, default_gist: str) -> Optional[dict]:
    """The speech section of the brief. A "> " line right under a point is that point's full text (speech.md)."""
    m = SPEECH_SECTION.search(brief_text)
    if not m:
        return None
    body = [l.strip() for l in m.group(1).splitlines() if l.strip() and not l.startswith("#")]
    quoted = lambda l: l.startswith('"') or l.startswith("“")  # noqa: E731
    gist = next((l.strip("* ") for l in body if l.startswith("**")), default_gist)
    phrase = next((l.strip('"“” ') for l in body if quoted(l)), "")
    items: list = []
    for l in body:
        if l.startswith(">"):
            full = l.lstrip("> ").strip()
            if items and full:
                last = items[-1] if isinstance(items[-1], dict) else {"text": items[-1], "full": ""}
                last["full"] = (last["full"] + " " + full).strip()
                items[-1] = last
            continue
        if not l.startswith("**") and not quoted(l):
            items.append(l.lstrip("-* "))
    return {"gist": gist, "phrase": phrase, "items": items[:12]}


def speech_point(x):
    """A speech point as the window takes it: a plain string, or {"text", "full"} when it has a full text."""
    if isinstance(x, dict):
        text, full = str(x.get("text") or "").strip(), str(x.get("full") or "").strip()
        return {"text": text, "full": full} if full and full != text else text
    return str(x)


def point_text(x) -> str:
    """The short line of a speech point."""
    return str(x.get("text") or "") if isinstance(x, dict) else str(x)


def similar_topic(topic: str, topics: List[str], sim: float) -> bool:
    return bool(topic) and any(jaccard(topic, t) >= sim for t in topics)


def same_tip(obj: dict, shown: dict, sim: float) -> bool:
    """The same gist, or a topic close enough to one already shown."""
    return obj.get("gist", "") == shown.get("gist") or similar_topic(obj.get("topic", ""), [shown.get("topic", "")], sim)


def mentions_money(text: str) -> bool:
    tl = text.lower()
    words = re.findall(r"[\w'ʼ’]+", tl)
    if any(w in COACH_MONEY_WORDS for w in words):
        return True
    return any((c in tl) if " " in c else any(w.startswith(c) for w in words)
               for c in COACH_MONEY_CUES if c not in ("rate", "cost"))


# 2026-11-02 (a discovery interview): the PM's "Мхм", "Ну да", "Ok" were taken as his last question, so the
# clarify tip stopped after the first answers. Short acknowledgements are skipped when looking for the question.
BACKCHANNEL = set("""мхм мг ага ахам угу ну да так та ок окей ok okay yes yeah yep right sure got it i see понятно зрозуміло
ясно добре норм нормально класно супер цікаво interesting cool nice great т е тобто 100 точно звісно ясне ага-ага""".split())


def is_backchannel(text: str) -> bool:
    t = (text or "").strip()
    if "?" in t:
        return False
    words = re.findall(r"[\w'ʼ’-]+", t.lower())
    return len(words) <= 1 or (len(words) <= 4 and all(w in BACKCHANNEL for w in words))


def last_question_and_answer(hist: List[Line]):
    """The PM's last real line (acknowledgements skipped) and the other side's lines after it (newest first)."""
    answer = []
    for h in reversed(hist):
        if h.speaker == "me":
            if is_backchannel(h.text):
                continue
            return h, answer
        answer.append(h)
    return None, answer


OWNER_DATE = (re.compile(r"\b(by|till|until|до|на|в)\s+(monday|tuesday|wednesday|thursday|friday|понеділ|вівтор|серед|четвер|п.ятниц|завтра|tomorrow|\d{1,2}[./]\d{1,2})"),
              re.compile(r"\b(i will|i'll|я зроблю|я візьму|беру на себе|will do|візьм)"))


def turn_resolved(trigger: str, after: List[Line]) -> Optional[str]:
    if trigger not in ("your_turn", "direct_question"):
        return None
    pm = [h for h in after if h.speaker == "me"]
    if len(pm) >= 2 or any(len(h.text) > 80 for h in pm):
        return "pm_answered"
    if len([h for h in after if h.speaker == "them"]) >= 3 and not pm:
        return "talk_moved_on"
    return None


def owner_or_date_said(trigger: str, after: List[Line]) -> Optional[str]:
    if trigger != "fix_owner_date":
        return None
    txt = " ".join(h.text for h in after).lower()
    return "owner_or_date_said" if any(r.search(txt) for r in OWNER_DATE) else None


def numbers_said(obj: Optional[dict], after: List[Line]) -> Optional[str]:
    if not (obj and obj.get("topic")):
        return None
    said = " ".join(h.text for h in after).lower()
    nums = re.findall(r"\d[\d.,]*", " ".join([obj.get("phrase", "")] + [point_text(x) for x in (obj.get("items") or [])]))
    return "numbers_already_said" if nums and all(n in said for n in nums) else None


def hedge_delays(models: dict, after_s: Optional[dict]) -> dict:
    """Seconds to wait before a second request, per model id (the shortest of its roles)."""
    after = dict({"classify": 2.0, "tip": 3.0}, **(after_s or {}))
    by_model = {}
    for role, mid in models.items():
        if mid and role in after:
            by_model[mid] = min(after[role], by_model.get(mid, after[role]))
    return by_model


def raise_tip_tokens(cfg: dict) -> None:
    mt = cfg.setdefault("max_tokens", {})
    if isinstance(mt, dict) and mt.get("tip", 0) and mt["tip"] < 900:
        mt["tip"] = 900                   # 300 cut the two best tips of the PM sync (long Ukrainian phrase); 900 since the why line (2026-11-05)


def _due(a: dict) -> str:
    return " (" + a["due"] + ")" if a.get("due") else ""


def picture_items(sit: dict, uk: bool) -> List[str]:
    """The call picture as summary lines: decisions, what is on the PM and on them, risks, open asks."""
    L = (lambda u, e: u if uk else e)  # noqa: E731
    items = [L("Рішення: ", "Decision: ") + d for d in sit.get("decisions") or []]
    items += [L("На мені: ", "On me: ") + a.get("what", "") + _due(a) for a in sit.get("actions") or []]
    items += [L("За ними: ", "On them: ") + a.get("who", "") + ": " + a.get("what", "") + _due(a) for a in sit.get("theirs") or []]
    items += [L("Ризик: ", "Risk: ") + r.get("what", "") for r in sit.get("risks") or []]
    items += [L("Без відповіді: ", "Unanswered: ") + a.get("what", "") + (" · " + a["who"] if a.get("who") else "")
              for a in sit.get("asks") or [] if a.get("type") != "update"]
    return items


def missed_speech(speech_items: List[str], done, uk: bool) -> List[str]:
    """Speech points never said, only when some were said (otherwise the speech did not happen at all)."""
    done = set(done or [])
    missed = [x for i, x in enumerate(speech_items) if i not in done]
    if not (speech_items and missed and len(missed) < len(speech_items)):
        return []
    return [("Не сказав зі спічу: " if uk else "Not said from the speech: ") + x for x in missed[:5]]


def passages(snips: List[dict]) -> str:
    return "\n\n".join("[{}{}]\n{}".format(x["src"], ", " + x["date"] if x["date"] else "", x["text"]) for x in snips)


def unique_sources(snips: List[dict]) -> List[str]:
    srcs = []
    for x in snips:
        if x["src"] not in srcs:
            srcs.append(x["src"])
    return srcs


def find_event(text: str, snips: List[dict]) -> str:
    if snips:
        found = passages(snips)
        return ("The PM asked to search the project folder: " + text + ". Below are passages found in the project "
            "files (newest facts win when they disagree). Answer as one tip: gist = the answer in a few words, "
            "phrase = a sentence the PM can say if useful, items = up to 4 facts with numbers, dates and owners, "
            "note = the file names used. Only what the passages, the brief or the call say; when the answer is "
            "not there, say so in the gist and name the closest thing found.\n\nPASSAGES FROM THE PROJECT FOLDER:\n" + found)
    return ("The PM asked to search the project folder: " + text + ". The search found nothing in the project "
            "files. Answer from the brief, the fact book, the current state and the call if they cover it; "
            "otherwise gist = 'Nothing found in the project folder'.")


def find_item(obj: dict, srcs: List[str], text: str, src: str, done: float) -> dict:
    note = obj.get("note") or ""
    if srcs and not note:
        note = "Sources: " + ", ".join(srcs[:4])
    item = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": src, "kind": "answer",
            "level": obj.get("level", "info"), "gist": "🔎 " + str(obj.get("gist", "")).lstrip("🔎 "),
            "phrase": obj.get("phrase", ""), "items": obj.get("items", []), "note": note, "at": s_to_hms(done),
            "q": "find: " + text, "sources": srcs[:6]}
    return {k: v for k, v in item.items() if v not in ("", [], None)}


def ask_span(line: Line, a: dict, now: float) -> dict:
    return {"line_id": line.line_id, "src": line.t, "speaker": line.speaker, "seg_end": line.seg_end,
            "written": line.written, "available_at": now, "route": "situation",
            "event": "Open {} to the PM from {}: {}. Give the PM the answer or the next step: gist = what is asked, "
                     "phrase = a ready sentence, items = 1-2 facts from the brief, fact book or call. Skip if the PM "
                     "already answered.".format(a.get("type", "question"), a.get("who", "someone"), a.get("what", "")),
            "force_level": "red"}


def merge_hits(results) -> List[dict]:
    """Index hits of several queries, one per (path, preview start), best score first."""
    seen, hits = set(), []
    for res in results:
        for h in res:
            key = (h.get("path"), (h.get("preview") or "")[:60])
            if key not in seen:
                seen.add(key)
                hits.append(h)
    hits.sort(key=lambda h: -(h.get("score") or 0))
    return hits


def fit_snippets(hits: List[dict], budget_chars: int, hit_text) -> List[dict]:
    """Up to 10 passages that fit the character budget, in hit order."""
    out, used = [], 0
    for h in hits:
        body = hit_text(h)
        if not body or used + len(body) > budget_chars:
            continue
        used += len(body)
        out.append({"src": h.get("rel") or Path(h.get("path") or "").name, "date": h.get("date") or "", "text": body})
        if len(out) >= 10:
            break
    return out


def pacing_tip(obj: dict, trigger: str) -> bool:
    """A non-red tip about time or pacing (in a presentation the recorder owns the time line)."""
    if obj.get("level") == "red":
        return False
    text = " ".join([obj.get("gist", ""), obj.get("topic", ""), obj.get("phrase", "")])
    return trigger == "timer_checkpoint" or obj.get("trigger") == "timer_checkpoint" or bool(PACING.search(text))


_STOP = {"what", "when", "which", "where", "will", "would", "could", "should", "with", "have", "this", "that", "your",
         "they", "them", "there", "about", "from", "does", "коли", "який", "яка", "яке", "які", "хто", "скільки", "буде",
         "можна", "чи", "щодо", "також", "якщо", "вони", "ваша", "ваш", "наша", "наш", "цього", "цей", "ця", "що"}


def brief_covers(question: str, brief: str, share: float = 0.6) -> bool:
    """The brief already speaks about the question: most of its content words (by a 5-letter stem, so Ukrainian
    endings match) are in the brief and the fact book. A background search starts only when it does not."""
    words = [w.lower() for w in re.findall(r"[^\W_]{4,}", question or "", re.U)]
    stems = {w[:5] for w in words if w not in _STOP}
    if not stems:
        return True
    text = (brief or "").lower()
    if not text.strip() or text.strip().startswith("(no brief)") and len(text.strip()) < 20:
        return False
    hit = sum(1 for st in stems if st in text)
    return hit / len(stems) >= share


def deep_item(res: dict, uk: bool) -> dict:
    """The card fields of a deep folder lookup result (or of its failure)."""
    if res.get("error"):
        return {"gist": ("🔎 Пошук у папці не вдався: " if uk else "🔎 The folder search failed: ") + str(res["error"])[:90],
                "level": "info"}
    note = ("Джерела: " if uk else "Sources: ") + ", ".join(res["sources"]) if res.get("sources") else ""
    return {"gist": "🔎 " + str(res.get("gist", "")).lstrip("🔎 "), "phrase": res.get("phrase", ""),
            "items": [str(x) for x in (res.get("items") or [])][:4], "level": "info", "note": note}


def numbers_seen(text: str, corpus: str) -> bool:
    """Every number of two or more characters in the text also appears in the (lower-case) corpus."""
    for n in re.findall(r"\d[\d.,]*\d|\d", text or ""):
        n = n.rstrip(".,")
        if n and len(n) > 1 and n not in corpus:
            return False
    return True


def check_numbers(obj: dict, corpus: str) -> dict:
    items = [i for i in (obj.get("items") or []) if numbers_seen(point_text(i) + " " + (i.get("full", "") if isinstance(i, dict) else ""), corpus)]
    dropped = len(obj.get("items") or []) - len(items)
    obj["items"] = items
    if dropped:
        obj["_dropped_items"] = dropped
    if obj.get("phrase") and not numbers_seen(obj["phrase"], corpus):
        obj["_unseen_number_in_phrase"] = True
    return obj


def situation_due(since: Optional[float], interval: float, strong: bool) -> bool:
    """Time for a new call picture: the first one, every interval, or 3 s after a strong line."""
    return since is None or since >= interval or (strong and since >= 3)


def commitment_card(c: dict, t: str, uk: bool) -> dict:
    mine = (c.get("owner") or "me") == "me"
    who = ("На мені" if mine else "На них") if uk else ("On me" if mine else "On them")
    return {"schema_version": 1, "engine": "app", "kind": "commitment_done", "level": "info", "t": t, "at": t,
            "src": t, "id": c["id"], "text": c.get("text", ""), "owner": c.get("owner") or "me",
            "gist": who + " · " + ("Зроблено? " if uk else "Done? ") + c.get("text", "")}


def speech_out(item: dict, now: float, default_gist: str, note: str) -> dict:
    """The speech card as the window shows it."""
    out = {"schema_version": 1, "engine": "app", "uid": "speech", "t": s_to_hms(now), "src": s_to_hms(now), "kind": "speech",
           "level": "info", "gist": item.get("gist") or default_gist, "phrase": item.get("phrase", ""),
           "items": [p for p in (speech_point(x) for x in (item.get("items") or [])) if point_text(p)][:14], "note": note, "at": s_to_hms(now)}
    return {k: v for k, v in out.items() if v not in ("", [], None)}


def add_queries(qs: List[str], obj: Optional[dict]) -> None:
    """New, non-empty queries from the model, case-insensitively unique."""
    for q in (obj or {}).get("queries") or []:
        if isinstance(q, str) and q.strip() and q.strip().lower() not in [x.lower() for x in qs]:
            qs.append(q.strip())


def pm_share(lines: List[Line]) -> float:
    me = sum(len(h.text) for h in lines if h.speaker == "me")
    return me / (sum(len(h.text) for h in lines) or 1)


def pm_leads(share: float, was: bool, presentation: bool) -> bool:
    """Hysteresis: in at 65% (55% in a presentation), out below 55%."""
    if was:
        return share >= 0.55
    return share > (0.55 if presentation else 0.65)


def with_deep_note(note: Optional[str], uk: bool, fast: bool = False) -> str:
    if fast:     # 0.9.6: the call agent answers in seconds (Orbit: 3-11 s)
        return (note + " · " if note else "") + ("шукаю в папках проєкту, кілька секунд" if uk else "searching the project folders, a few seconds")
    return (note + " · " if note else "") + ("шукаю глибше в папці проєкту, ~1 хв" if uk else "searching the project folder, about 1 min")


def repeats_speech(obj: dict, speech_phrase: str) -> bool:
    return bool(speech_phrase and obj.get("phrase") and jaccard(obj["phrase"], speech_phrase) >= 0.45)


def line_span(line: Line, sig, now: float) -> dict:
    """The timing record of one transcript line, filled in as it goes through the engine."""
    return {"line_id": line.line_id, "src": line.t, "speaker": line.speaker, "seg_end": line.seg_end,
            "written": line.written, "available_at": now, "signals": sig.tags,
            "to_pm": bool(sig.name_vocative or (sig.question and sig.second_person))}


def strong_line(line: Line, sig) -> bool:
    """The other side names the PM or says something that changes the picture of the call."""
    return line.speaker == "them" and bool(sig.name_vocative or sig.name_mention or SITUATION_STRONG.search(line.text))


def spans_enough(lines: List[Line], seconds: float = 100) -> bool:
    return bool(lines) and lines[-1].t_s - lines[0].t_s >= seconds


def asks_the_pm(sig) -> bool:
    """A question to the PM by name or "you", not about a third person."""
    return bool((sig.name_vocative or (sig.question and sig.second_person)) and not sig.third_person)


def route_when_off(sig) -> Optional[str]:
    """The trigger is switched off for this meeting: a question or a name still goes to classify,
    except for the PM's own commitments and new requirements."""
    if (sig.question or sig.name_mention) and sig.trigger_hint not in ("pm_commitment", "new_requirement"):
        return "classify"
    return None


@dataclass
class TipRun:
    """One tip request on its way from the model to the window."""
    line: Line
    trigger: str
    span: dict
    gate: Optional[dict]
    uid: str
    shown: Optional[bool] = False     # early gist: False not yet, True on screen, None decided against
    kept: bool = False                # the early gist was on screen when the full tip arrived
    obj: Optional[dict] = None
    done: float = 0.0


class Engine:
    def __init__(self, *, cfg: dict, rules, provider, prompt, out_dir: Path, stem: str,
                 clock: Callable[[], float], budget=None):
        self.cfg = cfg
        self.context_revision = 0
        self.correction_path = out_dir / (stem + ".context-correction.txt")
        self._agenda_backup = None
        try:
            self.context_correction = self.correction_path.read_text(encoding="utf-8")[:CORRECTION_MAX]
        except OSError:
            self.context_correction = ""
        self.rules = rules
        self.provider = provider
        self.prompt = prompt
        self.clock = clock
        self.budget = budget
        self.detector = Detector(rules, cfg.get("name_aliases", []))
        self.models = cfg["models"]                      # {"classify": id, "tip": id}
        self._setup_hedging(provider, cfg)
        self.ttl = cfg.get("cache_ttl", "1h")
        self.direct_enabled = cfg.get("direct_route", True)
        self.classify_enabled = bool(self.models.get("classify"))
        self.periodic_s = cfg.get("periodic_classify_s", 20)
        d = rules.diet
        self.rate_s = cfg.get("active_rate_seconds", d["active_rate_seconds"])
        self.pm_window = d["pm_speaking_window_s"]
        self.topic_sim = d["topic_similarity_min"]
        self.stale_s = d["stale_after_s"]
        self.history: List[Line] = []
        # Result application nests local state helpers; model requests stay outside this lock.
        self.lock = threading.RLock()
        self.pool = ThreadPoolExecutor(max_workers=cfg.get("max_parallel_calls", 4))
        self.futures = []
        self.tips: List[dict] = []
        self.last_nonred_emit: Optional[float] = None
        self.last_classify_at: Optional[float] = None
        self.classify_busy = False
        self.classify_pending: Optional[Line] = None
        self.tipped_lines = set()
        self.out_tips = JsonlWriter(Path(cfg["tips_out"]) if cfg.get("tips_out") else out_dir / (stem + ".app.tips.jsonl"))
        self.out_llm = JsonlWriter(out_dir / (stem + ".app.llm.jsonl"))
        self.out_timing = JsonlWriter(out_dir / (stem + ".app.timing.jsonl"))
        self.tip_validator = jsonschema.Draft202012Validator(rules.model_tip_schema)
        self.cls_validator = jsonschema.Draft202012Validator(rules.classify_schema)
        self.paused = False
        self.tips_set: Optional[bool] = None     # 0.8.5: the Tips switch (None: by the call type, off for Transcript)
        # The first tip call writes the prompt cache; parallel first calls would each pay the write.
        self.tip_cache_warm = threading.Event()
        self.tip_warm_lock = threading.Lock()
        self.red_repeat_s = d.get("red_repeat_window_s", 60)
        self.diet_lock = threading.Lock()     # diet check + "shown" bookkeeping are one step
        # Names the PM gave to voices in the tips window (<stem>.speakers.json, written by the recorder).
        self.speakers = SpeakerNames(cfg.get("speakers_file"))
        self.clarified_for: Dict[int, int] = {}   # interviewer: PM question line id -> answer words at the last "Уточни"
        # 2026-10-23 PM sync review: a question to anyone on the call may be one the PM is expected to
        # answer or add to; the addressee is ignored (cfg "answer_any", on by default).
        self.answer_any = cfg.get("answer_any", True)
        # 2026-10-26: "Зафіксуй / Можеш додати" by the periodic classify only when proactive is on.
        self.proactive = cfg.get("proactive", False)
        self.situation: dict = {}
        self.sit_busy = False
        self.sit_pending = False
        self.sit_last_at: Optional[float] = None
        self.sit_last_line = -1
        self.sit_interval = cfg.get("situation_interval_s", 10)
        self.sit_enabled = cfg.get("situation", True) and bool(self.models.get("classify"))
        self.sit_asks_tipped = set()
        self.speech_items: List[str] = []
        self.speech_item: Optional[dict] = None
        self.ask_log: List[dict] = []
        # Pacenote 0.8 (F5): the agenda as a contract and the commitments register (rules/agenda.yaml,
        # rules/commitments.yaml). The register lives in the call's folder (<project>/live/commitments.jsonl).
        self.agenda_items: List[tuple] = []
        self.agenda_ids = []
        self.agenda_full: List[str] = []       # 2026-11-02: the full text of each item (the strip shortens it)
        self.agenda_obtain = ""                 # the brief's "Decisions to obtain" text (the wrap check)
        self.agenda_done: set = set()
        self.agenda_now = -1
        self.agenda_manual: Dict[int, str] = {}
        self.agenda_sent: Optional[list] = None
        self.register_dir = cfg.get("register_dir") or ""
        # 0.8.7 (rules/sales.yaml): sales mode on top of any call type; None = off, nothing changes
        self.t_started = clock()
        self._setup_sales(cfg, rules)
        self.commit_proposed: set = set()
        self.onme_ticked: Dict[str, bool] = {}
        # 0.8.5 (owner): an On me line the PM marked "not mine" or reworded in the window; norm text -> new text ("" = drop)
        self.onme_fixed: Dict[str, str] = {}
        # 0.9.4: tip ratings from the window, "<card>|<t>|<gist>" -> {verdict, reasons, comment, tip}; the last one wins
        self.tip_ratings: Dict[str, dict] = {}
        # 0.8.6 (rules/commitments.yaml > mine): lines the PM made his with "Mine" in the window
        self.onme_mine: List[dict] = []
        self.risks_shown: set = set()
        self.open_commitments = self._load_commitments(cfg, rules)
        # 0.8.8 (rules/decisions.yaml): the project's active decisions from the local snapshot, never from Notion live
        self.active_decisions = load_active_decisions(cfg.get("project_dir") or "")
        self.conflicts_shown: set = set()
        if self.context_correction:
            self._apply_correction_to_prompt()      # a restarted engine keeps the PM's correction of this call
        raise_tip_tokens(cfg)

    def _setup_sales(self, cfg, rules):
        self.sales = None
        sc = cfg.get("sales") or {}
        if isinstance(sc, dict) and sc.get("enabled"):
            from .sales import SalesTracker, load_cards
            self.sales = SalesTracker(*self._sales_config(cfg, rules, sc), load_cards(cfg.get("project_dir") or ""),
                                      float(cfg.get("planned_min") or 30) * 60)

    @staticmethod
    def _sales_config(cfg, rules, sc):
        language = "en" if str(cfg.get("ui_lang") or "").startswith("en") else "uk"
        return getattr(rules, "sales", {}) or {}, str(sc.get("method") or ""), language

    def _setup_hedging(self, provider, cfg: dict) -> None:
        """M2 hedging: a second request when the first one is slow (cfg "hedge", on by default)."""
        hg = cfg.get("hedge", {}) if isinstance(cfg.get("hedge"), dict) else {}
        routed = getattr(provider, "name", "") == "routed"
        if routed:   # 0.8.2: the app's monthly API limit stops the key, not Claude Code
            provider.api_blocked = lambda: bool(self.budget and self.budget.state() == "hard")
        if not hg.get("enabled", True) or isinstance(provider, HedgedProvider):
            return
        by_model = hedge_delays(self.models, hg.get("after_s"))
        if routed:   # a second request only on the API: Claude Code is slow to start and spends the plan
            provider.wrap("api", lambda p: HedgedProvider(p, by_model, on_extra=self._extra_usage))
        else:
            self.provider = HedgedProvider(provider, by_model, on_extra=self._extra_usage)

    def _load_commitments(self, cfg: dict, rules) -> List[dict]:
        """Open commitments of this meeting series from the register (rules/commitments.yaml)."""
        if not (cfg.get("commitments", True) and self.register_dir):
            return []
        try:
            m = self.meta()
            return register.open_items(self.register_dir, register.series_key(m.get("project", ""), m.get("title", "")),
                                       int((getattr(rules, "commitments", None) or {}).get("open_limit", 15)))
        except Exception:  # noqa: BLE001  (the register is a helper; tips go on without it)
            return []

    # ---------- input ----------
    def on_line(self, line: Line) -> None:
        now = self.clock()
        with self.lock:
            self.history.append(line)
        self._every_fifth_line(line)
        sig = self.detector.detect(line)
        span = line_span(line, sig, now)
        if self.paused or self._budget_stops() or self.tips_off():
            return
        if self._wrap_due(line):
            with self.lock:
                self.last_wrap_at = now
            self.on_request("wrap")
        self._maybe_situation(line, sig, now)
        # rules/diet.yaml > stale_after_s: an old line still counts for the agenda, the situation and the brief
        # reload above; it only never starts an automatic tip (no model call for speech nobody waits on now)
        if self._expired(line):
            self.out_timing.write({"line_id": line.line_id, "src": line.t, "outcome": "historical_line"})
            return
        if self._meeting_route(line, sig, span, now):
            return
        if meeting_role(self.meta()) == "observer":
            return                            # observer: only the question tips above, nothing after the answer
        self._dispatch_line(line, sig, span, now)

    def _dispatch_line(self, line, sig, span, now):
        route = self._route(line, sig, span)
        if route == "direct":
            span["route"] = "direct"
            self._submit_tip(line, sig.trigger_hint, span)
        elif route == "classify":
            self._classify_route(line, sig, span)
        elif self._periodic_due(line, now):
            span["route"] = "periodic"
            self._submit_classify(line, span)

    def _every_fifth_line(self, line: Line) -> None:
        if line.line_id % 5:
            return
        if hasattr(self.prompt, "refresh_facts") and self.prompt.refresh_facts():
            self.out_timing.write({"line_id": line.line_id, "src": line.t, "outcome": "facts_reloaded"})
        self.reload_prep()

    def _meeting_route(self, line: Line, sig, span: dict, now: float) -> bool:
        mh = self.meeting_hint(line, sig, now)
        if not mh:
            return False
        span["route"] = "direct"
        span["meeting"] = mh["kind"]
        span["event"] = mh["event"]
        if mh.get("level"):
            span["force_level"] = mh["level"]
        if mh.get("exempt"):
            span["rate_exempt"] = True
        self._submit_tip(line, mh["trigger"], span)
        return True

    def _route(self, line: Line, sig, span: dict) -> Optional[str]:
        route = sig.route if self.direct_enabled else ("classify" if sig.route else None)
        if not route and self.answer_any and line.speaker == "them" and sig.question:
            route = "classify"                # a question to anyone: the PM may answer or add (2026-10-23)
        # Meeting concept (2026-10-23): triggers the skill switches off for this call type / audience.
        if route and sig.trigger_hint in disabled_triggers(getattr(self.prompt, "meta", None)):
            span["off"] = sig.trigger_hint
            route = route_when_off(sig)
        return route

    def _classify_route(self, line: Line, sig, span: dict) -> None:
        if not self.classify_enabled:
            span["route"] = "tip_only"
            self._submit_tip(line, sig.trigger_hint, span)
            return
        if not (self.cfg.get("parallel_tip", True) and asks_the_pm(sig)):
            span["route"] = "classify"
            self._submit_classify(line, span)
            return
        # 2026-10-26 replay: a question to anyone ran Sonnet in parallel 30 times per call for 3 tips;
        # now only a question to the PM (by name or "you") runs in parallel, others wait for classify.
        # 2026-10-23: a likely trigger runs classify and the tip at once; classify only vetoes the
        # tip before it is shown (saves the 1.3 s classify step on about 20% of tips).
        span["route"] = "parallel"
        span["gate"] = {"event": threading.Event(), "need_tip": None, "obj": None}
        tip_span = dict(span)
        self._submit_classify(line, span)
        self._submit_tip(line, sig.trigger_hint, tip_span)

    def _periodic_due(self, line: Line, now: float) -> bool:
        return bool(self.proactive and line.speaker == "them" and self.classify_enabled and (
            self.last_classify_at is None or now - self.last_classify_at >= self.periodic_s))

    # ---------- model roles ----------
    def _windows(self, line: Line):
        """The earlier lines (up to `context_earlier_s` back, cut at `context_bucket_s` steps) and the live tail."""
        with self.lock:
            hist = [h for h in self.history if h.line_id <= line.line_id]
        return context_windows(hist, line.t_s, self.cfg.get("context_earlier_s", 240), self.cfg.get("context_bucket_s", 120))

    def _earlier(self, line: Line) -> List[str]:
        earlier, _ = self._windows(line)
        return ["[{}] {}: {}".format(h.t, self.speakers.who(h), h.text[:300]) for h in earlier][-80:]

    def _tail(self, line: Line) -> List[str]:
        _, tail = self._windows(line)
        return ["[{}] {}: {}".format(h.t, self.speakers.who(h), h.text) for h in tail][-60:]

    def _state(self) -> dict:
        """tips_given carries the numbers already shown (review 2026-10-23: "63 h" was shown three times
        because the state held only gists)."""
        with self.lock:
            recent = [t for t in self.tips if not t.get("partial")][-10:]
        given = []
        for t in recent:
            nums = sorted(set(re.findall(r"\d[\d.,:%]*", " ".join([t.get("phrase", "")] + [point_text(x) for x in (t.get("items") or [])]))))
            given.append(t["gist"] + ((" [" + ", ".join(nums[:6]) + "]") if nums else ""))
        st = {"tips_given": given, "now": s_to_hms(self.clock())}
        rated = [r for r in getattr(self, "tip_ratings", {}).values() if r["verdict"] != "used"][-8:]
        if rated:                    # 0.9.4 (rules/learning.yaml > tip_rating): the PM's ratings in this call
            st["pm_ratings"] = [{k: v for k, v in r.items() if v} for r in rated]
        sit = self.situation
        if sit:
            st["situation"] = {"topic": sit.get("topic", ""), "owner": sit.get("owner", ""), "mine": sit.get("mine"),
                               "open_asks_to_pm": [a.get("what", "") for a in sit.get("asks") or []][:4]}
        return st

    # ---------- freshness checks (code, not prompt) ----------
    def _after(self, line: Line) -> List[Line]:
        with self.lock:
            return [h for h in self.history if h.line_id > line.line_id]

    def _expired(self, line: Line, limit: Optional[float] = None) -> bool:
        """Age of the source audio, allowing calls to cross midnight."""
        # the end of speech; without a timing record the time the line arrived (a 28 s segment is not old when it lands)
        end = line.seg_end if line.seg_end is not None else (line.written if line.written is not None else line.t_s)
        age = self.clock() - end
        if age < -43200:
            age += 86400
        return age > (self.stale_s if limit is None else limit)

    def stale(self, line: Line, trigger: str, obj: Optional[dict] = None) -> Optional[str]:
        """Review 2026-10-23: in 38 of 52 late tips the trigger was already resolved when the tip came.
        A question to the PM or the PM's turn is closed once the PM has spoken after it (two or more
        of the PM's lines, or one long one), or once two other lines moved the talk on without it.
        "Fix owner/date" is closed when an owner or a date was named after the trigger."""
        if self._expired(line):
            return "expired"
        after = self._after(line)
        if not after:
            return None
        return turn_resolved(trigger, after) or owner_or_date_said(trigger, after) or numbers_said(obj, after)

    def validate_facts(self, obj: dict, line: Line) -> dict:
        """Numbers in items must exist in the brief, the fact book, the cards or the transcript so far
        (review 2026-10-23: 17 invented facts in 72 weak app tips). Offending items are dropped; a
        phrase with an unseen number loses the number to the gist's topic only when nothing is left."""
        corpus = self.prompt.corpus()
        with self.lock:
            corpus += " " + " ".join(h.text for h in self.history[-400:])
        return check_numbers(obj, corpus.lower())

    def _budget_stops(self) -> bool:
        """The app's own API limit is reached and this call has no way around the key."""
        if not (self.budget and self.budget.state() == "hard"):
            return False
        return not (getattr(self.provider, "name", "") == "routed" and self.provider.can_run_without_api())

    def _bill(self, c):
        """Count what a model call cost against the app's budget; the rounded price rides on the completion."""
        usd = cost_usd(c.model, c.input_tokens, c.cache_write_5m, c.cache_write_1h, c.cache_read, c.output_tokens)
        if self.budget and usd:
            self.budget.add(usd)
        c.usd = round(usd, 6) if usd is not None else None
        return c

    def _extra_usage(self, c) -> None:
        """The losing request of a hedged pair finished: it is billed, so it counts."""
        self._bill(c)
        self.out_llm.write({"at": s_to_hms(self.clock()), "role": "hedge_extra", "model": c.model,
                            "ttft_ms": c.ms(c.t_first_token), "total_ms": c.ms(c.t_done),
                            "input": c.input_tokens, "cache_read": c.cache_read, "cache_write_5m": c.cache_write_5m,
                            "cache_write_1h": c.cache_write_1h, "output": c.output_tokens,
                            "usd": c.usd, "error": c.error})

    def _call(self, role: str, line: Line, event: str, on_text=None, provider=None, model=None):
        if role == "tip" and meeting_role(self.meta()) == "interviewer":
            event += INTERVIEWER_ROLE_NOTE
        user = self.prompt.user(role, event, self._tail(line), self._state(), self._earlier(line))
        max_tokens = self.cfg.get("max_tokens", {}).get(role, 60 if role == "classify" else 300)
        extra = (self.cfg.get("request_extra") or {}).get(role)
        # 2026-11-06 (owner): a typed question goes to the preparation's model (provider + model given)
        c = (provider or self.provider).complete(model=model or self.models[role], system=self.prompt.blocks, user=user,
                                                 max_tokens=max_tokens, cache_ttl=self.ttl, extra=None if provider else extra,
                                                 on_text=on_text)
        self._bill(c)
        self.out_llm.write({"at": s_to_hms(self.clock()), "role": role + ("_prep" if provider else ""), "model": c.model, "line_id": line.line_id,
                            "ttft_ms": c.ms(c.t_first_token), "gist_ms": c.ms(c.t_gist), "total_ms": c.ms(c.t_done),
                            "input": c.input_tokens, "cache_read": c.cache_read, "cache_write_5m": c.cache_write_5m,
                            "cache_write_1h": c.cache_write_1h, "output": c.output_tokens,
                            "usd": c.usd, "error": c.error,
                            "stop": c.stop_reason, "hedge": c.hedge,
                            # 0.9.2: what a cut answer said is kept too (an audit needs it); model output, never the prompt
                            "reasoning": c.reasoning_tokens or None, "incomplete": c.incomplete, "retried": c.retried,
                            "tail": c.tail or None, "route": getattr(c, "route", None),
                            "text_head": c.text[:160] if c.text else None,
                            "text": c.text if (self.cfg.get("debug_log_text") and not c.error) else None})
        return c

    def _submit_classify(self, line: Line, span: dict) -> None:
        with self.lock:
            if self.classify_busy:
                self.classify_pending = line      # coalesce: only the newest waiting line is classified next
                span["coalesced"] = True
                self.out_timing.write(dict(span, outcome="classify_coalesced"))
                return
            self.classify_busy = True
            self.last_classify_at = self.clock()
        self.futures.append(self.pool.submit(self._run_classify, line, span))

    def _run_classify(self, line: Line, span: dict) -> None:
        try:
            span["classify_start"] = self.clock()
            c = self._call("classify", line, "classify")
            span["classify_done"] = self.clock()
            span["classify_ms"] = c.ms(c.t_done)
            obj = first_json(c.text) if not c.error else None
            if c.error or obj is None or list(self.cls_validator.iter_errors(obj)):
                self._classify_failed(span, c)
            else:
                self._classified(line, span, obj)
        finally:
            self._classify_next()

    def _classify_failed(self, span: dict, c) -> None:
        span["outcome"] = "classify_error" if c.error else "classify_invalid"
        span["error"] = c.error
        if span.get("gate") is not None:
            g = span.pop("gate")
            g["need_tip"] = None                # no verdict: the tip decides
            g["event"].set()
        self.out_timing.write(span)

    def _classified(self, line: Line, span: dict, obj: dict) -> None:
        span["classify"] = obj
        if span.get("gate") is not None:
            gate = span.pop("gate")
            gate["need_tip"] = bool(obj.get("need_tip"))
            gate["obj"] = obj
            gate["event"].set()
            span["outcome"] = "classify_for_parallel"
        elif obj.get("need_tip"):
            if obj.get("trigger") == "answer_in_primary":
                why = self._aip_blocked(obj)
                if why:
                    span["outcome"] = why
                    self.out_timing.write(span)
                    return
                span["event"] = (span.get("event") or "answer_in_primary") + ANSWER_IN_PRIMARY_NOTE
            self._submit_tip(line, obj.get("trigger", "none"), span, level_hint=obj.get("level"))
            return
        else:
            span["outcome"] = "no_tip"
        self.out_timing.write(span)

    def _aip_blocked(self, obj: dict) -> Optional[str]:
        """0.9.2 (rules/diet.yaml > answer_in_primary): at most N such tips in 10 minutes, never twice on one topic."""
        cfg = (self.rules.diet or {}).get("answer_in_primary") or {}
        now = self.clock()
        with self.lock:
            shown = [t for t in self.tips if t.get("trigger") == "answer_in_primary" and not t.get("partial")]
        if sum(1 for t in shown if t.get("_at", -1e9) >= now - 600) >= int(cfg.get("per_10_min", 2)):
            return "aip_rate"
        topic = str(obj.get("topic") or "")
        if cfg.get("once_per_topic", True) and topic and any(jaccard(topic, str(t.get("topic") or "")) >= self.topic_sim
                                                            for t in shown):
            return "aip_same_topic"
        return None

    def _classify_next(self) -> None:
        with self.lock:
            nxt = self.classify_pending
            self.classify_pending = None
            self.classify_busy = False
        if nxt is not None:
            self._submit_classify(nxt, {"line_id": nxt.line_id, "src": nxt.t, "speaker": nxt.speaker,
                                        "seg_end": nxt.seg_end, "written": nxt.written,
                                        "available_at": self.clock(), "route": "classify_pending"})

    def _submit_tip(self, line: Line, trigger: str, span: dict, level_hint: Optional[str] = None) -> None:
        with self.lock:
            if line.line_id in self.tipped_lines:
                span["outcome"] = "dup_line"
                self.out_timing.write(span)
                return
            self.tipped_lines.add(line.line_id)
        span["context_revision"] = self.context_revision
        self.futures.append(self.pool.submit(self._run_tip, line, trigger, span))

    def _run_tip(self, line: Line, trigger: str, span: dict) -> None:
        if self._expired(line) or span.get("context_revision", self.context_revision) != self.context_revision:
            self.out_timing.write(dict(span, outcome="obsolete_before_request"))
            return
        span["tip_start"] = self.clock()
        run = TipRun(line, trigger, span, span.pop("gate", None),        # parallel route: classify's verdict arrives here
                     "a{}-{}".format(line.line_id, int(span["tip_start"] * 1000) % 1000000))
        c = self._tip_call(line, span.get("event") or trigger, functools.partial(self._early_gist, run))
        run.done = self.clock()
        run.kept = run.shown is True
        tip_timing(span, c, run.done)
        outcome = self._judge_tip(run, c)
        if outcome:
            span["outcome"] = outcome
            if run.kept:
                self._retract(run.uid)
            self.out_timing.write(span)
            return
        self._emit_tip(run)

    def _tip_call(self, line: Line, event: str, on_text):
        if self.tip_cache_warm.is_set():
            return self._call("tip", line, event, on_text=on_text)
        with self.tip_warm_lock:
            c = self._call("tip", line, event, on_text=on_text)
            if not c.error:
                self.tip_cache_warm.set()
        return c

    # Streamed gist (2026-10-23): as soon as the gist, level and topic are complete in the stream, run the
    # diet on them and show the gist; the full tip replaces it by uid.
    def _early_gist(self, run: "TipRun", buf: str) -> None:
        if run.shown or not self.cfg.get("stream_gist", True):
            return
        part = partial_head(buf)
        if not part:
            return
        if run.span.get("force_level"):
            part["level"] = run.span["force_level"]
        if garbled(part):
            run.shown = None                   # wait for the full tip: it is judged (and dropped) there
            return
        if self.meeting_block(part, run.trigger, run.span):
            run.shown = None
            return
        now = self.clock()
        hold = self._early_hold(run)
        if hold == "wait":
            return                             # classify still running: the gist waits for its verdict
        if hold or not self._early_admit(run, part, now):
            run.shown = None                   # decided: wait for the full tip, no early card
            return
        self._show_early(run, part, now)

    def _early_hold(self, run: "TipRun") -> Optional[str]:
        if run.span.get("context_revision", self.context_revision) != self.context_revision:
            return "drop"
        if self.stale(run.line, run.trigger):
            return "drop"                      # the trigger is already resolved: no early card
        gate = run.gate
        if gate is None:
            return None
        if not gate["event"].is_set():
            return "wait"
        return "drop" if gate["need_tip"] is False else None

    def _early_admit(self, run: "TipRun", part: dict, now: float) -> bool:
        exempt = bool(run.span.get("rate_exempt"))
        with self.diet_lock:
            if self._diet(part, now, exempt=exempt):
                return False
            with self.lock:                    # counts for the rate and same-topic checks at once
                self.tips.append(dict(part, uid=run.uid, partial=True, _at=now, _exempt=exempt))
                if part["level"] != "red":
                    self.last_nonred_emit = now
        return True

    def _show_early(self, run: "TipRun", part: dict, now: float) -> None:
        line = run.line
        seg_end0 = line.seg_end if line.seg_end is not None else line.t_s
        self.out_tips.write({"schema_version": 1, "engine": "app", "uid": run.uid, "partial": True, "t": s_to_hms(now),
                             "src": line.t, "kind": "tip", "level": part["level"], "gist": part["gist"], "at": s_to_hms(now)})
        run.shown = True
        run.span["shown_at"] = now
        run.span["e2e_shown_s"] = round(now - seg_end0, 2)

    def _retract(self, uid: str) -> None:
        with self.lock:
            self.tips[:] = [t for t in self.tips if t.get("uid") != uid]
        self.out_tips.write({"schema_version": 1, "engine": "app", "kind": "retract", "uid": uid})

    def _judge_tip(self, run: "TipRun", c) -> Optional[str]:
        """None: the tip goes out. Otherwise the outcome that stopped it (span carries the details)."""
        span = run.span
        if span.get("context_revision", self.context_revision) != self.context_revision:
            return "context_changed"
        obj, why = self._parse_tip(c, span)
        if why:
            return why
        if span.get("force_level"):
            obj["level"] = span["force_level"]
        run.obj = obj
        for step in (self._tip_blocked, self._tip_vetoed, self._tip_stale, self._tip_unseen_number, self._tip_aip_repeat,
                     self._tip_diet):
            outcome = step(run)
            if outcome:
                span["gist"] = obj.get("gist")
                return outcome
        return None

    def _parse_tip(self, c, span: dict):
        """(the tip, None) or (None, why it is not one): a failed call, bad JSON or schema, a skip."""
        obj = first_json(c.text) if not c.error else None
        if c.error or obj is None:
            span["error"] = c.error
            return None, "tip_error" if c.error else "tip_invalid"
        bad = self._schema_error(obj)
        if bad:
            span["error"] = bad
            return None, "tip_invalid"
        if not obj.get("skip"):
            g = garbled(obj)
            if g:
                span["error"] = "garbled: " + g
                return None, "tip_invalid"
        if obj.get("skip"):
            span["reason"] = obj.get("reason")
            return None, "skip"
        return obj, None

    def _schema_error(self, obj: dict) -> Optional[str]:
        errs = list(self.tip_validator.iter_errors(obj))
        if not errs:
            return None
        best = jsonschema.exceptions.best_match(errs)
        return "{}: {}".format("/".join(str(p) for p in best.absolute_path), best.message[:160])

    def _tip_aip_repeat(self, run: "TipRun") -> Optional[str]:
        """0.9.2 (diet.yaml > answer_in_primary > once_per_topic): an answer to a statement built on a fact an earlier
        such answer used is the same answer in other words (04.11: "no structure" twice in a minute)."""
        if run.trigger != "answer_in_primary" and run.obj.get("trigger") != "answer_in_primary":
            return None
        ids = {str(x) for x in run.obj.get("fact_ids") or []}
        with self.lock:
            used = {str(x) for t in self.tips if t.get("trigger") == "answer_in_primary" and not t.get("partial")
                    for x in t.get("fact_ids") or []}
        return "aip_same_facts" if ids & used else None

    def _tip_blocked(self, run: "TipRun") -> Optional[str]:
        return self.meeting_block(run.obj, run.obj.get("trigger", run.trigger), run.span)

    def _tip_vetoed(self, run: "TipRun") -> Optional[str]:
        gate = run.gate
        if gate is None:
            return None
        gate["event"].wait(2.0)
        if gate["need_tip"] is False:
            return "classify_vetoed"
        if gate.get("obj") and gate["obj"].get("trigger") and run.trigger == "none":
            run.trigger = gate["obj"]["trigger"]
        return None

    def _tip_stale(self, run: "TipRun") -> Optional[str]:
        demote_red(run.obj, run.trigger, run.span)
        why = self.stale(run.line, run.obj.get("trigger", run.trigger), run.obj)
        # a red warning (a wrong number, a promise to stop) is worth showing late: up to twice the window, marked late
        if why == "expired" and run.obj.get("level") == "red" and not self._expired(run.line, self.stale_s * RED_LATE_FACTOR):
            why = None
        return "stale_" + why if why else None

    def _tip_unseen_number(self, run: "TipRun") -> Optional[str]:
        obj = self.validate_facts(run.obj, run.line)
        if obj.get("_dropped_items"):
            run.span["dropped_items"] = obj.pop("_dropped_items")
        return "unseen_number" if obj.pop("_unseen_number_in_phrase", False) else None

    def _tip_diet(self, run: "TipRun") -> Optional[str]:
        if run.kept:
            return None                        # a gist already on screen is kept
        with self.diet_lock:
            verdict = self._diet(run.obj, run.done, exempt=bool(run.span.get("rate_exempt")))
            if not verdict and run.obj.get("level") != "red":
                with self.lock:
                    self.last_nonred_emit = run.done
        return "diet_" + verdict if verdict else None

    def _emit_tip(self, run: "TipRun") -> None:
        line, span, done = run.line, run.span, run.done
        seg_end = line.seg_end if line.seg_end is not None else line.t_s
        item = tip_item(run.obj, run.uid, line, run.trigger, done, late=(done - seg_end) > self.stale_s)
        if not getattr(run, "partial", False):
            usage.log("tip_shown", {"kind": str(item.get("kind", ""))[:40]})     # 0.8.7 (M): the kind only
        with self.lock:
            self.tips[:] = [t for t in self.tips if not (t.get("uid") == run.uid and t.get("partial"))]
            self.tips.append(dict(item, _at=done, _exempt=bool(span.get("rate_exempt"))))
            if item["level"] != "red":
                self.last_nonred_emit = done
        self.out_tips.write(item)
        span.update(outcome="emitted", emit_at=done, level=item["level"], e2e_s=round(done - seg_end, 2))
        if span.get("gist_at") is not None:
            span["e2e_gist_s"] = round(span["gist_at"] - seg_end, 2)
        span["gist"] = item["gist"]
        self.out_timing.write(span)

    # ---------- diet (code, not prompt) ----------
    def _phrase_repeat(self, obj: dict, now: float) -> bool:
        """The same answer in other words (the client call repeated "we can only speak to our module" 8
        times): a phrase this close to one shown in the last 10 minutes is noise, at any level."""
        ph = obj.get("phrase") or ""
        if len(ph.split()) < 5:
            return False
        with self.lock:
            shown = [t.get("phrase", "") for t in self.tips if t.get("_at", -1e9) >= now - 600 and not t.get("partial")]
        return any(p and jaccard(ph, p) >= self.cfg.get("phrase_repeat_min", 0.42) for p in shown)

    def _gist_repeat(self, obj: dict, now: float) -> bool:
        """Review of the calls of 2026-11-02/03: in a discovery interview 11 of 31 tips repeated a gist shown
        23-77 s before ("Deal stages from the first contact" three times), each with its own topic string, so the
        topic diet and the window's exact-topic merge missed them. A non-red gist this close to one shown in the
        last GIST_REPEAT_S is the same tip again."""
        core = gist_core(obj.get("gist") or "")
        if len(core) < 3:
            return False
        with self.lock:
            shown = [t.get("gist", "") for t in self.tips if t.get("_at", -1e9) >= now - GIST_REPEAT_S
                     and not t.get("partial") and t.get("level") != "red"]
        return any(jaccard_sets(core, gist_core(g)) >= GIST_REPEAT_MIN for g in shown)

    def _diet(self, obj: dict, now: float, exempt: bool = False) -> Optional[str]:
        if self._phrase_repeat(obj, now):
            return "phrase_repeat"
        if obj.get("level") != "red" and self._gist_repeat(obj, now):
            return "gist_repeat"
        if obj.get("level") == "red":
            return self._red_diet(obj, now)
        if self.presenting(now):
            return "presenting"
        why = self._team_diet(obj, now)
        if why:
            return why
        if exempt:
            return self._exempt_diet(now)
        return self._rate_diet(obj, now)

    def _red_diet(self, obj: dict, now: float) -> Optional[str]:
        """A red tip is never rate-limited, but the same red tip twice within a minute is noise
        (two lines of one turn can both trigger "your turn")."""
        with self.lock:
            recent = [t for t in self.tips if t.get("level") == "red" and t.get("_at", -1e9) >= now - self.red_repeat_s]
        if any(same_tip(obj, t, self.topic_sim) for t in recent):
            return "red_repeat"
        # 2026-10-26 replay: one question in two or three lines gave three red tips in 20 s.
        if any(t.get("_at", -1e9) >= now - self.cfg.get("red_burst_s", 15) for t in recent):
            return "red_burst"
        return None

    def _team_diet(self, obj: dict, now: float) -> Optional[str]:
        """Team calls: no info tips (the PM did not ask; window asks and SOS do not pass the diet) and
        at most TEAM_TIPS_PER_HOUR non-red model tips per hour."""
        if self.meta().get("audience") != "team":
            return None
        if obj.get("level") == "info":
            return "team_info"
        with self.lock:
            uids = {t.get("uid") or id(t) for t in self.tips if t.get("level") != "red" and "_at" in t
                    and t["_at"] >= now - 3600 and t.get("kind", "tip") == "tip"}
        return "team_hour_cap" if len(uids) >= TEAM_TIPS_PER_HOUR else None

    def _exempt_diet(self, now: float) -> Optional[str]:
        """Hiring tips ignore the orange rate (hiring.md "Live tips by role"), max 2 per minute."""
        with self.lock:
            n = len({t.get("uid") for t in self.tips if t.get("_exempt") and t.get("_at", -1e9) >= now - 60})
        return "meeting_rate" if n >= MEETING_EXEMPT_PER_MIN else None

    def _rate_diet(self, obj: dict, now: float) -> Optional[str]:
        if self.last_nonred_emit is not None and now - self.last_nonred_emit < self.rate_s:
            return "rate"
        with self.lock:
            pm_recent = any(h.speaker == "me" and h.written is not None and 0 <= now - h.written <= self.pm_window
                            for h in self.history[-6:])
            topics = [t.get("topic", "") for t in self.tips if t.get("_at", -1e9) >= now - 600]
        if pm_recent:
            return "pm_speaking"
        return "same_topic" if similar_topic(obj.get("topic", ""), topics, self.topic_sim) else None

    # ---------- meeting concept and live mode ----------
    def meta(self) -> dict:
        return getattr(self.prompt, "meta", None) or {}

    def set_meeting(self, change: dict) -> bool:
        """call_type / audience / hiring_role changed in the window's menu (status.json). Every meeting
        rule in the engine reads the prompt's meta live, so a change applies from the next line."""
        changed = self.prompt.set_meeting(change) if hasattr(self.prompt, "set_meeting") else False
        if changed:
            with self.lock:
                self.clarified_for.clear()
            self._presenting = False
        return changed

    def _is_question(self, line: Line, sig=None) -> bool:
        if sig is not None and sig.question:
            return True
        words = re.findall(r"[\w'ʼ’]+", line.text.lower())
        return "?" in line.text or (bool(words) and any(w in self.detector.q for w in words[:2]))

    def meeting_hint(self, line: Line, sig, now: float) -> Optional[dict]:
        """Routing by meeting concept (hiring.md "Live tips by role", presentation.md Q&A). Returns
        {kind, trigger, event, level?, exempt?} for a line that goes straight to a tip, or None."""
        meta = self.meta()
        role = meeting_role(meta)
        if line.speaker != "them":
            return None
        by_role = {"observer": self._observer_hint, "coach": self._coach_hint, "interviewer": self._interviewer_hint}
        if role in by_role:
            return by_role[role](line, sig)
        if meta.get("call_type") == "presentation" and self._is_question(line, sig) and self.qa_mode(now):
            return {"kind": "presentation_qa", "trigger": "direct_question", "event": QA_EVENT}
        return None

    def _observer_hint(self, line: Line, sig) -> Optional[dict]:
        if self._is_question(line, sig) and not sig.name_mention:
            return {"kind": "observer_question", "trigger": "direct_question", "event": OBSERVER_EVENT,
                    "level": "orange", "exempt": True}
        return None

    def _coach_hint(self, line: Line, sig) -> Optional[dict]:
        if mentions_money(line.text):
            return {"kind": "coach_money", "trigger": "direct_question", "event": COACH_MONEY_EVENT, "level": "red"}
        if self._is_question(line, sig):
            return {"kind": "coach_question", "trigger": "direct_question", "event": COACH_QUESTION_EVENT, "level": "red"}
        return None

    def _interviewer_hint(self, line: Line, sig) -> Optional[dict]:
        """One clarifying tip per long answer to the PM's last question."""
        with self.lock:
            hist = [h for h in self.history if h.line_id <= line.line_id]
        q, answer = last_question_and_answer(hist)
        if q is None:
            return None
        if not (self._is_question(q) or len(re.findall(r"[\w'ʼ’]+", q.text)) >= 6):   # the PM asks; Whisper drops "?"
            return None
        words = sum(len(h.text.split()) for h in answer)
        # one clarify per answer, and one more for every INTERVIEWER_MORE_WORDS the answer goes on (a 5-minute story)
        need = self.clarified_for[q.line_id] + INTERVIEWER_MORE_WORDS if q.line_id in self.clarified_for else INTERVIEWER_ANSWER_WORDS
        if words < need:
            return None
        with self.lock:
            self.clarified_for[q.line_id] = words
        return {"kind": "interviewer_clarify", "trigger": "add_fact", "event": INTERVIEWER_EVENT,
                "level": "orange", "exempt": True}

    def qa_mode(self, now: float) -> bool:
        """Presentation Q&A: the PM spoke before, and the PM's share of the last QA_WINDOW_S seconds
        (characters) is below QA_SHARE_MAX over a window that covers most of it."""
        with self.lock:
            hist = list(self.history)
        if not any(h.speaker == "me" for h in hist):
            return False
        recent = [h for h in hist if h.t_s >= now - QA_WINDOW_S]
        if not recent or now - min(h.t_s for h in hist) < QA_WINDOW_S:
            return False
        me = sum(len(h.text) for h in recent if h.speaker == "me")
        tot = sum(len(h.text) for h in recent) or 1
        return me / tot < QA_SHARE_MAX

    def meeting_block(self, obj: dict, trigger: str, span: dict) -> Optional[str]:
        """Model tips the meeting concept does not allow, checked on the streamed gist and the full tip."""
        meta = self.meta()
        if not meta.get("turn_tips", self.cfg.get("turn_tips", False)) and TURN_GIST.search(obj.get("gist", "") or ""):
            return "turn_tip"                 # 2026-10-23: the PM starts on their own, never on a "your turn" tip
        if repeats_speech(obj, getattr(self, "speech_phrase", "")):
            return "speech_repeat"            # the speech card is already on screen
        return self._role_block(obj, trigger, span, meta)

    def _role_block(self, obj, trigger, span, meta):
        if meeting_role(meta) == "observer" and not span.get("meeting"):
            return "role_observer"            # after the answer: nothing (no add_fact, no fix_owner_date)
        if (meeting_role(meta) == "interviewer" and trigger == "add_fact" and not span.get("to_pm")
                and obj.get("phrase") and "?" not in obj["phrase"]):
            return "interviewer_answer"       # a statement for the PM would answer for the interviewee
        if meta.get("call_type") == "presentation" and pacing_tip(obj, trigger):
            return "presentation_timing"      # the recorder owns the time line
        return None

    def presenting(self, now: float) -> bool:
        """The skill's live mode (read_delta detect_mode): presenting when the PM has more than 65% of
        the talk (characters) over the last 120 s, back to discussion below 55%. A presentation call is
        presenting whenever the PM leads the talk (above 55%). Only red tips pass while presenting."""
        meta = getattr(self.prompt, "meta", {}) or {}
        if meta.get("call_type") == "interview":
            return False
        with self.lock:
            recent = [h for h in self.history if h.t_s >= now - 120 - 30]
        if not spans_enough(recent):
            return False
        was = getattr(self, "_presenting", False)
        self._presenting = pm_leads(pm_share(recent), was, meta.get("call_type") == "presentation")
        return self._presenting

    # ---------- the PM's speech from the brief, at the start ----------
    def correct_context(self, text: str) -> None:
        """rules/live_prep.yaml > correction: the PM's correction wins over the old prep in every later request.
        It goes into the cached brief block (not into each request), old in-flight answers are dropped, the old
        agenda is put aside until the new prep lands (restore_agenda brings it back when the prep fails)."""
        text = text.strip()[:CORRECTION_MAX]
        if not text:
            return
        with self.lock:
            self.context_correction = text
            self.context_revision += 1
            self.situation = None
            if not getattr(self, "_agenda_backup", None):
                self._agenda_backup = self._agenda_snapshot()
            self._agenda_previous = None
        self._apply_correction_to_prompt()
        try:
            self.correction_path.write_text(text, encoding="utf-8")
        except OSError:
            self.out_timing.write({"outcome": "correction_persistence_failed"})
        self.set_agenda_items("", remember=False)
        self.out_tips.write({"kind": "context_reset"})

    def restore_agenda(self) -> None:
        """The prep after a correction failed or was cancelled: the agenda put aside comes back with its states."""
        with self.lock:
            b, self._agenda_backup = getattr(self, "_agenda_backup", None), None
            if not b:
                return
            self.agenda_items, self.agenda_full, self.agenda_done, self.agenda_now, self.agenda_manual, self.agenda_obtain, self.agenda_ids = b
        self._emit_agenda()

    def _apply_correction_to_prompt(self) -> None:
        if hasattr(self.prompt, "set_correction"):
            self.prompt.set_correction(self.correction_block().strip())

    def correction_block(self) -> str:
        if not self.context_correction:
            return ""
        return "\nLATEST EXPLICIT PM CORRECTION FOR THIS CALL (supersedes conflicting earlier context; do not use obsolete participants or checklist):\n" + self.context_correction

    def reload_prep(self) -> bool:
        """A preparation that landed after the start: reload the brief and the facts, show the speech
        and a short notice in the window (2026-10-27, owner)."""
        if not hasattr(self.prompt, "refresh_brief"):
            return False
        had = bool(getattr(self.prompt, "_brief", ""))
        try:
            changed = self.prompt.refresh_brief()
        except Exception:  # noqa: BLE001
            return False
        if not changed:
            return False
        with self.lock:
            self.context_revision += 1
            self._agenda_backup = None        # the new brief owns the agenda now
        if hasattr(self.prompt, "refresh_facts"):
            self.prompt.refresh_facts()
        t = s_to_hms(self.clock())
        self.out_tips.write({"schema_version": 1, "engine": "app", "kind": "notice", "level": "info", "t": t, "at": t,
                             "gist": ("Preparation updated: the tips use the corrected text" if had else
                                      "Preparation ready: the brief, the facts and the cards are loaded")})
        if self.speech_item is None and self.cfg.get("speech_card", True):
            self.speech_card(self.prompt._brief)
        self.set_agenda_items(self.prompt._brief)
        return True

    def _ui_uk(self) -> bool:
        """2026-10-27 (owner): labels and gists follow the window language (tips_lang); a phrase to say follows the call."""
        return (self.cfg.get("tips_lang") or self.meta().get("tips_lang", "uk")) == "uk"

    def tips_off(self) -> bool:
        """rules/meeting.yaml > tips: off by the switch, or a Transcript call; asks typed by the PM still answer."""
        if self.tips_set is not None:
            return not self.tips_set
        return (self.meta().get("tips") == "off") or (self.meta().get("call_type") == "transcript")

    def speech_card(self, brief_text: str) -> Optional[dict]:
        """The skill shows "Твій спіч" from the brief as the first card (no model call). The brief carries
        it as a ready item under "## speech.json"; without one, the "спіч / speech" section is used."""
        if not brief_text or self.tips_off() or self._restore_speech():
            return None
        default = "🟢 Твій спіч" if self._ui_uk() else "🟢 Your speech"
        item = speech_from_brief(brief_text, default)
        if not item:
            return None
        out = speech_out(item, self.clock(), default, item.get("note", "бриф" if self._ui_uk() else "brief"))
        self._remember_speech(out)
        self.out_tips.write(out)
        return out

    def _remember_speech(self, it: dict) -> None:
        self.speech_phrase = it.get("phrase", "")
        self.speech_items = [point_text(x) for x in (it.get("items") or [])]
        self.speech_item = it

    def _restore_speech(self) -> bool:
        """An engine restart must not show the speech twice: the card already in the tips file comes back."""
        try:
            prev = self.out_tips.path.read_text(encoding="utf-8", errors="replace")
            if '"kind": "speech"' not in prev and '"kind":"speech"' not in prev:
                return False
            for it in speech_cards(prev):
                self._remember_speech(it)
            return True
        except (OSError, AttributeError):
            return False

    # ---------- requests from the tips window (asks, HELP NOW) ----------
    def on_request(self, kind: str, text: str = "") -> None:
        """kind: "ask" (a question typed in the window), "find" (search the project folder, then answer)
        or "sos" (HELP NOW). Never rate-limited."""
        if kind == "sos":            # 0.8.7 (M): the event only, never the text
            usage.log("help_now")
        elif kind != "wrap":
            usage.log("ask_typed")
        if self._budget_stops():
            return
        now = self.clock()
        with self.lock:
            last = self.history[-1] if self.history else None
        line = last or Line(-1, s_to_hms(now), "them", "", None, "en", "")
        span = {"line_id": line.line_id, "src": s_to_hms(now), "request": kind, "available_at": now}
        self.futures.append(self.pool.submit(self._run_request, kind, text, line, span))

    # ---------- "Search the project" from the tips window (2026-10-26) ----------
    FIND_QUERIES = ("You turn a question asked during a call into search queries for a project folder "
                    "(notes, transcripts, specs, Notion and Jira exports). Return JSON only: "
                    "{\"queries\": [\"...\", \"...\", \"...\"]}: 2-4 short keyword queries (2-6 words), mixing "
                    "Ukrainian and English when the folder may hold both, names and ticket keys kept as written.")

    def _find_queries(self, text: str) -> List[str]:
        qs = [text]
        try:
            c = self._bill(self.provider.complete(model=self.models["classify"], system=[{"text": self.FIND_QUERIES}],
                                                  user="Question: " + text, max_tokens=150, cache_ttl=None,
                                                  extra=(self.cfg.get("request_extra") or {}).get("classify")))
            add_queries(qs, first_json(c.text) if not c.error else None)
        except Exception:  # noqa: BLE001  (the question itself is still searched)
            pass
        return qs[:5]

    @staticmethod
    def _hit_text(h: dict, width: int = 1800) -> str:
        """The text around a search hit: a window of the file for text files, the preview otherwise."""
        prev = (h.get("preview") or "").strip()
        path = h.get("path") or ""
        if path and Path(path).suffix.lower() in (".md", ".txt", ".csv", ".json", ".yaml", ".yml", ".html", ".eml"):
            try:
                raw = Path(path).read_text(encoding="utf-8", errors="replace")
                key = re.sub(r"\s+", " ", prev.strip("…. "))[:50]
                flat = re.sub(r"\s+", " ", raw)
                i = flat.find(key) if key else -1
                if i < 0:
                    i = 0
                a = max(0, i - width // 3)
                return flat[a:a + width]
            except OSError:
                pass
        return prev

    def _search_roots(self) -> List[str]:
        """The project folder and every folder added to the call (2026-11-06: the added ones were searched only by
        the Claude Code lookup, so a typed question never saw them)."""
        roots = []
        for d in [self.cfg.get("project_root")] + list(self.cfg.get("extra_dirs") or []):
            if isinstance(d, str) and d and d not in roots and Path(d).is_dir():
                roots.append(d)
        return roots

    def _project_snippets(self, text: str, budget_chars: int = 14000, k: int = 6) -> List[dict]:
        roots, lt = self._search_roots(), self.cfg.get("lt_cmd")
        if not roots or not lt:
            return []
        from .context import index_snippets
        from concurrent.futures import ThreadPoolExecutor as _TP
        qs = self._find_queries(text)
        jobs = [(q, r) for r in roots[:4] for q in qs]
        with _TP(max_workers=min(12, len(jobs)) or 1) as ex:      # parallel, one overall wait (QA: up to 100 s in a row)
            results = list(ex.map(lambda j: index_snippets(lt, Path(j[1]), j[0], k=k, timeout=15.0), jobs))
        return fit_snippets(merge_hits(results), budget_chars, self._hit_text)

    # ---------- the preparation's model for questions and the deep lookup (2026-11-06, owner) ----------
    FAST_PREP_ROUTES = ("api", "openai", "gemini")

    def _prep_route(self) -> str:
        routes = (self.cfg.get("ai") or {}).get("routes") or {}
        return routes.get("prep") or ""

    def _prep_provider(self):
        """The provider of the preparation job (Settings > AI), built once; None when the app did not send it."""
        if not hasattr(self, "_prepp"):
            self._prepp = None
            if self._prep_route():
                try:
                    from .routing import provider_from_cfg
                    from .secret_store import load_secret
                    self._prepp = provider_from_cfg(self.cfg, lambda n: load_secret(n, self.cfg.get("secrets_file")),
                                                    job="prep", env_route=False)
                except Exception:  # noqa: BLE001  (questions then stay on the tips model)
                    self._prepp = None
        return self._prepp

    def _deep_model(self) -> str:
        return self.cfg.get("deep_model_id") or "claude-sonnet-5-5"

    def _economy(self) -> bool:
        """0.9.6 Б1: economy mode (the state/economy file, switched by hand, read on every question)."""
        from .agent import economy_on
        return economy_on(self.cfg)

    def _ask_on_prep(self) -> bool:
        """A typed question is answered by the preparation's model when that way answers in seconds (never in economy
        mode: the tips model then)."""
        return bool(self.cfg.get("ask_on_prep_model", True)) and self._prep_route() in self.FAST_PREP_ROUTES \
            and not self._economy() and self._prep_provider() is not None

    def _deep_via_claude_code(self) -> bool:
        """Claude Code reads the folders itself when the preparation runs on Claude (account or key); with no
        preparation way known (an older app, the skill) it follows the tips way as before."""
        from . import deep
        route = self._prep_route() or ((self.cfg.get("ai") or {}).get("routes") or {}).get("tips") or "api"
        return route in ("code", "api") and bool(deep.claude_path(self.cfg))

    def _open_question(self, line: Optional[Line]) -> str:
        """HELP NOW has no text: the last question of the other side (or the last line) is what to look up."""
        with self.lock:
            hist = list(self.history)[-6:]
        for h in reversed(hist):
            if h.speaker != "me" and "?" in (h.text or ""):
                return h.text
        return (hist[-1].text if hist else (line.text if line else "")) or ""

    def _run_find(self, text: str, line: Line, span: dict) -> None:
        span["tip_start"] = self.clock()
        snips = self._project_snippets(text)
        c = self._call("tip", line, find_event(text, snips))
        done = self.clock()
        obj = first_json(c.text) if not c.error else None
        if not obj or obj.get("skip"):
            obj = {"gist": "Nothing found in the project folder" if not c.error else "Search failed: " + c.error[:80]}
        if not snips or "Nothing found" in str(obj.get("gist", "")):
            self._start_deep(text, "ask")
        item = find_item(obj, unique_sources(snips), text, span["src"], done)
        with self.lock:
            self.tips.append(item)
        self.out_tips.write(item)
        span.update({"outcome": "emitted", "emit_at": done, "tip_ms": c.ms(c.t_done), "error": c.error,
                     "find_snippets": len(snips)})
        self.out_timing.write(span)

    # Rewrite only on an edit verb next to the speech; show on "where / show (me) my speech ..." (QA 26.10).
    SPEECH_ASK = re.compile(r"(додай|добав|прибери|видали|зміни|переп[иі]ши|онови|скороти|встав|допиши|add|remove|change|rewrite|update|shorten|put)\b.{0,60}(спіч|speech|апдейт|update)"
                            r"|(спіч|speech|апдейт)\w*.{0,40}\b(додай|прибери|зміни|переп[иі]ши|онови|скороти|add|remove|change|rewrite|shorten)", re.I)
    SPEECH_SHOW = re.compile(r"^\W*(де|покажи|show|where|дай|відкрий|open)\b.{0,40}(спіч|speech|мій апдейт|my update)", re.I)

    def _emit_speech(self, obj: dict, note: str = "") -> dict:
        out = speech_out(obj, self.clock(), "🟢 Твій спіч" if self._ui_uk() else "🟢 Your speech", note or obj.get("note", ""))
        changed = [point_text(x) for x in (out.get("items") or [])] != self.speech_items
        self._remember_speech(out)
        if changed and self.situation:
            with self.lock:
                self.situation["speech_done"] = []      # numbers of the old points mean nothing now (QA 26.10)
        self.out_tips.write(out)
        return out

    def _run_speech_request(self, text: str, line: Line, span: dict) -> bool:
        """2026-10-26: "де мій спіч?" shows the speech; "додай X у спіч" rewrites it in place (one card)."""
        if self.speech_item and self.SPEECH_SHOW.search(text):
            self._emit_speech(self.speech_item)
            span.update({"outcome": "speech_shown"})
            self.out_timing.write(span)
            return True
        cur = self.speech_item or {}
        event = ("The PM asks about the speech (the PM's own update for this call): " + text + ". CURRENT SPEECH: " +
                 json.dumps({"gist": cur.get("gist", ""), "phrase": cur.get("phrase", ""), "items": cur.get("items", [])},
                            ensure_ascii=False) + ". Return the FULL updated speech as JSON {\"gist\": \"🟢 ...\", "
                 "\"phrase\": \"<opening sentence>\", \"items\": [{\"text\": \"<point, max 8 words>\", \"full\": \"<the full text to read aloud, "
                 "1-4 sentences>\"}, ...up to 12; a group name is a plain string], \"note\": \"<what changed>\"}: "
                 "apply the request, keep every point that was not asked to change, use only the brief, the fact book, "
                 "the cards, the project current state and the call. With no speech yet, build it from the brief.")
        c = self._call("tip", line, event)
        obj = first_json(c.text) if not c.error else None
        if not obj or not (obj.get("items") or obj.get("phrase")):
            return False
        self._emit_speech(obj, note=obj.get("note", ""))
        span.update({"outcome": "speech_updated", "tip_ms": c.ms(c.t_done)})
        self.out_timing.write(span)
        self.ask_log.append({"q": text, "a": "speech updated: " + str(obj.get("note", ""))[:120]})
        return True

    FIND_ASK = re.compile(r"\b(знайди|пошукай|шукай|де лежить|в якому файлі|у файлі|в папці|у папці|файл\w*|документ\w*|специфікац\w*|"
                          r"find|search|look up|which file|in the files?|in the folder|docs?|documents?|spec\w*)\b", re.I)

    def _run_request(self, kind: str, text: str, line: Line, span: dict) -> None:
        if kind == "ask" and self._about_speech(text):
            span["tip_start"] = self.clock()
            if self._run_speech_request(text, line, span):
                return
        # 2026-10-27 (owner): no separate folder button; a question about files or "find/search" goes to the folder search.
        if kind == "ask" and self.FIND_ASK.search(text):
            kind = "find"
        if kind == "find":
            self._run_find(text, line, span)
            return
        if kind == "ask" and WRAP_ASK.search(text) and (self.agenda_items or self.agenda_obtain):
            kind = "wrap"
        if kind == "wrap":
            self._run_wrap(line, span)
            return
        event = SOS_EVENT if kind == "sos" else self._ask_event(text)
        if kind == "sos":            # 2026-11-06 (owner): HELP NOW also gets the folders' passages for the open question
            q = self._open_question(line)
            snips = self._project_snippets(q, budget_chars=6000) if q.strip() else []
            if snips:
                event += "\n\nPASSAGES FROM THE PROJECT FOLDERS (search for the open question; newest facts win):\n" + passages(snips)
        event = self._sales_cards_first(kind, text) + event   # 0.8.7 (H4.5): answer cards first in sales mode
        span["tip_start"] = self.clock()
        strong = kind == "ask" and self._ask_on_prep()
        c = self._call("tip", line, event, provider=self._prep_provider(), model=self._deep_model()) if strong \
            else self._call("tip", line, event)
        if strong and c.error:       # the preparation's way is out: the tips model answers as before
            c = self._call("tip", line, event)
        if strong and not c.error:
            span["ask_model"] = "prep"
        done = self.clock()
        obj = self._request_answer(c, kind, text, line)
        item = request_item(obj, kind, text, span["src"], done)
        if kind == "ask":
            self._log_ask(text, obj)
        with self.lock:
            self.tips.append(item)
        self.out_tips.write(item)
        span.update({"outcome": "emitted", "emit_at": done, "tip_ms": c.ms(c.t_done), "error": c.error})
        self.out_timing.write(span)

    def wrap_event(self) -> str:
        st = agenda_mod.states(self.agenda_items, self.agenda_done, self.agenda_now, self.agenda_manual)
        full = self.agenda_full or [t for t, _ in self.agenda_items]
        ag = "\n".join("{}. [{}] {}".format(i, s, t) for i, (t, s) in enumerate(zip(full, st))) or "(none)"
        with self.lock:
            hist = list(self.history)
        lines = ["[{}] {}: {}".format(h.t, self.speakers.who(h), h.text) for h in hist if not is_backchannel(h.text)]
        text, cap = "\n".join(lines), int(self.cfg.get("wrap_transcript_chars", 60000))
        if len(text) > cap:
            text = "…\n" + text[-cap:]
        return (WRAP_EVENT + "\n\nAGENDA (number. [state] item):\n" + ag + "\n\nDECISIONS TO OBTAIN:\n"
                + (self.agenda_obtain or "(none in the brief)") + "\n\nWHOLE CALL TRANSCRIPT:\n" + text)

    def _run_wrap(self, line: Line, span: dict) -> None:
        with self.lock:
            self.last_wrap_at = self.clock()
        span["tip_start"] = self.clock()
        c = self._call("tip", line, self.wrap_event())
        done = self.clock()
        obj = first_json(c.text) if not c.error else None
        if not obj or obj.get("skip") or not obj.get("gist"):
            return
        item = request_item(obj, "wrap", "", span["src"], done)
        item.update(kind="tip", level="red", trigger="timer_checkpoint", uid="wrap" + span["src"].replace(":", ""))
        with self.lock:
            self.tips.append(item)
        self.out_tips.write(item)
        span.update({"outcome": "emitted", "emit_at": done, "route": "wrap", "error": c.error})
        self.out_timing.write(span)

    def _wrap_due(self, line: Line) -> bool:
        """Someone asks whether there is anything else, or the PM says he is done (once per WRAP_GAP_S)."""
        if not (self.agenda_items or self.agenda_obtain):
            return False
        rx = ANY_ELSE if line.speaker == "them" else WRAP_SAY
        if not rx.search(line.text or ""):
            return False
        with self.lock:
            first = self.history[0].t_s if self.history else line.t_s
        if line.t_s - first < WRAP_MIN_S:        # "anything else I'm forgetting?" 4 min in is about the item, not the end
            return False
        last = getattr(self, "last_wrap_at", None)
        return last is None or self.clock() - last >= WRAP_GAP_S

    def _sales_cards_first(self, kind: str, text: str) -> str:
        """0.8.7 (H4.5, rules/sales.yaml > ask_order): in sales mode an ask or HELP NOW sees the matching answer
        cards before the brief and the project memory; HELP NOW matches the last lines of the call."""
        sales = getattr(self, "sales", None)
        if sales is None or not sales.cards or kind not in ("ask", "sos"):
            return ""
        from .sales import cards_block
        q = text
        if kind == "sos" or not q.strip():
            with self.lock:
                q = " ".join(ln.text for ln in list(self.history)[-6:])
        return cards_block(q, sales.cards)

    def _about_speech(self, text: str) -> bool:
        return bool(self.SPEECH_ASK.search(text) or (self.speech_item and self.SPEECH_SHOW.search(text)))

    def _ask_event(self, text: str) -> str:
        hist = ""
        if self.ask_log:
            hist = " Earlier asks in this call (the PM may refer to them, e.g. 'more detail', 'and the other one'): " + \
                   " | ".join("Q: {} A: {}".format(x["q"], x["a"]) for x in self.ask_log[-5:]) + "."
        event = "The PM typed a question in the tips window: " + text + "." + hist + " Answer it like a short chat reply (gist = the answer in a few words, items = details when asked for detail). Everything in the brief counts (the PM's speech, open questions, blocks), as do the fact book, the cards, the project current state, the call situation and the transcript. Never answer 'no answer' to a follow-up of an earlier answer: build on it. Skip only if nothing in the context answers it, then say so in the gist."
        # 2026-10-27 (owner): without a preparation the brief is empty; the project folder still holds the answer.
        snips = self._project_snippets(text, budget_chars=9000)
        if snips:
            event += "\n\nPASSAGES FROM THE PROJECT FOLDER (search for this question; newest facts win):\n" + passages(snips)
        return event + ASK_TAIL

    def _request_answer(self, c, kind: str, text: str, line: Line) -> dict:
        """The model's answer to an ask or HELP NOW; never empty: a bridge phrase and a deeper search when it has none."""
        obj = first_json(c.text) if not c.error else None
        unanswered = not_answered(obj) or (kind == "ask" and obj.get("answered") is not True)   # 2026-11-06: a typed question without "answered": true digs
        uk = self._ui_uk()
        if not obj or obj.get("skip"):
            obj = no_ready_answer(kind, uk, self.cfg.get("deep_lookup", True) and bool(self._search_roots()))
        if unanswered and kind in ("ask", "sos") and self.cfg.get("deep_lookup", True) and self._search_roots():
            self._start_deep(text or (line.text if line else ""), kind)
            obj["note"] = with_deep_note(obj.get("note"), uk, fast=self.agent_fast())
        return obj

    # ---------- deep lookup with Claude Code (2026-10-27) ----------
    def _start_deep(self, question: str, kind: str) -> None:
        if not self.cfg.get("deep_lookup", True) or not question.strip():
            return
        with self.lock:
            running = getattr(self, "deep_running", 0)
            done = getattr(self, "deep_count", 0)
            if running >= 2 or done >= int(self.cfg.get("deep_max_per_call", 12)):
                return
            self.deep_running = running + 1
            self.deep_count = done + 1
            tail = ["{}: {}".format(h.speaker, h.text) for h in list(self.history)[-8:]]
        threading.Thread(target=self._run_deep, args=(question, kind, tail), daemon=True).start()

    def _run_deep(self, question: str, kind: str, tail: List[str]) -> None:
        from . import deep
        uk = self._ui_uk()
        t0 = self.clock()
        lang = "Ukrainian" if uk else "English"
        try:
            res = None
            agent = self._call_agent()       # 0.9.6 (owner): one agent session for the call, behind a flag
            if agent is not None:
                res = agent.ask(question, tail, lang)
                if res.get("error"):         # the agent failed: the 0.9.5.4 lookup answers, the agent's spend still counts
                    if self.budget and res.get("cost_usd"):
                        self.budget.add(float(res["cost_usd"]))
                    self.out_llm.write({"at": s_to_hms(self.clock()), "role": "call_agent_error", "error": res.get("error"),
                                        "cost_usd": res.get("cost_usd")})
                    res = None
                else:
                    res["via"] = "agent"
            economy = self._economy()
            if res is not None:
                pass
            elif economy:
                # 0.9.6 Б1: Claude Code on the PM's Claude account (no key in the child); signed out or failed: the
                # folders are searched here and the tips model answers
                res = deep.lookup(self.cfg, question, tail, lang, economy=True) if deep.claude_path(self.cfg) else {"error": "no Claude Code"}
                if res.get("error"):
                    self.out_llm.write({"at": s_to_hms(self.clock()), "role": "deep_account_error", "error": res.get("error"),
                                        "economy": True})
                    res = deep.local_lookup(self.provider, self.models["tip"], question, tail, lang,
                                            self._project_snippets(question, budget_chars=36000, k=10), passages)
            elif self._deep_via_claude_code():
                res = deep.lookup(self.cfg, question, tail, lang)
            else:     # 2026-11-06 (owner): every other way searches the folders here and asks the preparation's model
                prov = self._prep_provider() or self.provider
                res = deep.local_lookup(prov, self._deep_model(), question, tail, lang,
                                        self._project_snippets(question, budget_chars=36000, k=10), passages)
        finally:
            with self.lock:
                self.deep_running = max(0, getattr(self, "deep_running", 1) - 1)
        if self.budget and res.get("cost_usd"):
            self.budget.add(float(res["cost_usd"]))
        done = self.clock()
        row = {"at": s_to_hms(done), "role": "deep_lookup", "q": question[:200], "secs": round(done - t0, 1),
               "answered": res.get("answered"), "error": res.get("error"), "cost_usd": res.get("cost_usd")}
        if res.get("via") == "agent":         # 0.9.6: the call agent answered (the golden rows stay as they were)
            row.update(via="agent", turns=res.get("turns"))
        if economy:
            row["economy"] = True
        self.out_llm.write(row)
        out = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": s_to_hms(t0), "kind": "answer",
               "q": question, "at": s_to_hms(done), **deep_item(res, uk)}
        out = {k: v for k, v in out.items() if v not in ("", [], None)}
        if kind == "ask":
            self._log_ask(question, out)
        with self.lock:
            self.tips.append(out)
        self.out_tips.write(out)

    # ---------- the call agent (0.9.6, owner 2026-11-06; livetips_m0.agent) ----------
    def _agent_caps(self):
        if not hasattr(self, "_acaps"):
            from .cost import ProviderCaps
            self._acaps = ProviderCaps.from_cfg(self.cfg)
        return self._acaps

    def _agent_key(self) -> str:
        try:
            from .secret_store import load_secret
            return load_secret(self.cfg.get("api_key_env", "CLAUDE_API"), self.cfg.get("secrets_file"))
        except KeyError:
            return ""

    def _call_agent(self):
        """The call's agent when it may answer now (flag on, not economy, SDK, key, Claude under its limit, the call's
        agent budget left, a folder to search); None sends the question to the 0.9.5.4 lookup. Built on first use."""
        from . import agent as agent_mod
        if not (self.cfg.get("agent") or {}).get("enabled") or not self._search_roots():
            return None
        why = agent_mod.why_not(self.cfg, "key" if getattr(self, "_agent_obj", None) else self._agent_key(), self._agent_caps())
        if why:
            if why != getattr(self, "_agent_why", None):
                self._agent_why = why
                self.out_llm.write({"at": s_to_hms(self.clock()), "role": "call_agent_off", "why": why})
            return None
        with self.lock:
            a = getattr(self, "_agent_obj", None)
            if a is None:
                state = (self.cfg.get("ai") or {}).get("state")
                a = agent_mod.CallAgent(self.cfg, self._agent_key(), AgentContext(self),
                                        state_dir=str(Path(state).parent) if state else None)
                self._agent_obj = a
        if a.refresh() or getattr(self, "_agent_eco", None) is None:     # 0.9.6 Б1: economy on or off, live
            if bool(a.a.get("economy")) != getattr(self, "_agent_eco", False):
                self.out_llm.write({"at": s_to_hms(self.clock()), "role": "call_agent_profile", "economy": bool(a.a.get("economy")),
                                    "model": a.a.get("model")})
            self._agent_eco = bool(a.a.get("economy"))
        if not a.call_budget_left():
            if getattr(self, "_agent_why", None) != "call_budget":
                self._agent_why = "call_budget"
                self.out_llm.write({"at": s_to_hms(self.clock()), "role": "call_agent_off", "why": "call_budget",
                                    "spent": round(a.spent, 4)})
            return None
        return a

    def agent_fast(self) -> bool:
        """The card's note promises seconds, not a minute, when the agent will answer."""
        try:
            return self._call_agent() is not None
        except Exception:  # noqa: BLE001
            return False

    # ---------- background searches of the call agent (0.9.6 point 2, owner 2026-11-06) ----------
    def _maybe_proactive(self, question: str, who: str = "") -> bool:
        """The other side asked the PM something the brief does not cover: a low-priority search by the call agent
        (flag agent.proactive). Skipped in economy mode, while a deep lookup runs, within proactive_gap_s of the last
        one, for a question already searched, and when the background share of the call is spent."""
        ac = (self.cfg.get("agent") or {})
        q = " ".join((question or "").split())
        if not ac.get("proactive") or not q or not self.cfg.get("deep_lookup", True):
            return False
        if self._economy():                   # 0.9.6 Б1: economy mode stops the background searches
            self.out_llm.write({"at": s_to_hms(self.clock()), "role": "proactive_skip", "why": "economy", "q": q[:120]})
            return False
        agent = self._call_agent()
        if agent is None:
            return False
        from .agent import agent_cfg
        a = agent_cfg(self.cfg)
        now = self.clock()

        def skip(why):
            self.out_llm.write({"at": s_to_hms(now), "role": "proactive_skip", "why": why, "q": q[:120]})
            return False
        key = q.lower()[:80]
        with self.lock:
            seen = self.__dict__.setdefault("_bg_seen", set())
            if key in seen:
                return False
            seen.add(key)
            if getattr(self, "deep_running", 0) > 0 or getattr(self, "_bg_running", False):
                return skip("busy")
            last = getattr(self, "_bg_last_at", None)
            if last is not None and now - last < float(a.get("proactive_gap_s") or 0):
                return skip("gap")
        if not agent.bg_budget_left():
            return skip("budget")
        if brief_covers(q, AgentContext(self).brief()):
            return skip("in_brief")
        with self.lock:
            self._bg_running = True
            self._bg_last_at = now
            tail = ["{}: {}".format(h.speaker, h.text) for h in list(self.history)[-8:]]
        threading.Thread(target=self._run_proactive, args=(agent, q, who, tail), daemon=True).start()
        return True

    def _run_proactive(self, agent, question: str, who: str, tail: List[str]) -> None:
        try:
            self._proactive_round(agent, question, who, tail)
        finally:
            with self.lock:
                self._bg_running = False

    def _proactive_round(self, agent, question: str, who: str, tail: List[str]) -> None:
        uk = self._ui_uk()
        t0 = self.clock()
        try:
            res = agent.ask(question, tail, "Ukrainian" if uk else "English", background=True, who=who)
        except Exception as e:  # noqa: BLE001
            res = {"error": "the call agent failed: " + type(e).__name__, "cost_usd": 0.0}
        if self.budget and res.get("cost_usd"):
            self.budget.add(float(res["cost_usd"]))
        done = self.clock()
        self.out_llm.write({"at": s_to_hms(done), "role": "proactive_lookup", "q": question[:200], "secs": round(done - t0, 1),
                            "answered": res.get("answered"), "error": res.get("error"), "skipped": res.get("skipped"),
                            "cost_usd": res.get("cost_usd"), "turns": res.get("turns")})
        # Quiet: a card only when the sources hold the answer (no "not found" noise during the call).
        if res.get("error") or res.get("skipped") or res.get("answered") is not True:
            return
        out = {"schema_version": 1, "engine": "app", "t": s_to_hms(done), "src": s_to_hms(t0), "kind": "answer",
               "q": question, "who": who, "at": s_to_hms(done), "auto": True, **deep_item(res, uk)}
        out = {k: v for k, v in out.items() if v not in ("", [], None)}
        with self.lock:
            self.tips.append(out)
        self.out_tips.write(out)

    def _log_ask(self, question: str, answer: dict) -> None:
        """Earlier asks go into the next ask's prompt ("more detail", "and the other one")."""
        self.ask_log.append({"q": question, "a": (str(answer.get("gist", "")) + " " + str(answer.get("phrase", "")))[:200]})

    # ---------- situation tracker (2026-10-26) ----------
    def _maybe_situation(self, line: Line, sig, now: float) -> None:
        if not self.sit_enabled:
            return
        # Backchannels remain in history for the next substantive update. Never suppress yes/no decisions.
        if line.text.strip().lower().strip(".,! …") in {"mhm", "mm-hmm", "uh-huh", "угу", "мгм", "ага"}:
            return
        strong = strong_line(line, sig)
        since = None if self.sit_last_at is None else now - self.sit_last_at
        if not situation_due(since, self.sit_interval, strong):
            return
        with self.lock:
            if self.sit_busy:
                self.sit_pending = True
                return
            self.sit_busy = True
            self.sit_last_at = now
        self.futures.append(self.pool.submit(self._run_situation))

    def _run_situation(self) -> None:
        try:
            self._situation_round()
        except Exception as e:  # noqa: BLE001  (the state is a helper; tips go on without it)
            self.out_timing.write({"outcome": "situation_error", "error": repr(e)[:200]})
        finally:
            self._situation_done()

    def _situation_done(self) -> None:
        with self.lock:
            self.sit_busy = False
            again = self.sit_pending
            self.sit_pending = False
        if again:
            with self.lock:
                self.sit_busy = True
                self.sit_last_at = self.clock()
            self.futures.append(self.pool.submit(self._run_situation))

    def _situation_round(self) -> None:
        with self.lock:
            hist = list(self.history)
            last_done = self.sit_last_line
            revision = self.context_revision
        new = [h for h in hist if h.line_id > last_done]
        if not new:
            return
        obj = self._situation_ask([h for h in hist if h.line_id <= last_done][-12:], new)
        if revision != self.context_revision:
            return
        if not isinstance(obj, dict):
            return
        pm_words = sum(len(h.text.split()) for h in new if h.speaker == "me")
        self._apply_situation(obj, hist, new, pm_words, revision)

    def _apply_situation(self, obj, hist, new, pm_words, revision):
        # Revision check and every derived local write form one transaction. No model/network wait here.
        with self.lock:
            if revision != self.context_revision:
                return
            sit = next_situation(obj, self.situation or {}, pm_words, new[-1].t_s, self.cfg.get("ask_ttl_s", 360))
            self._publish_situation(sit, new[-1].line_id)
            self._asks_to_tips(sit, hist)
            self._agenda_from_model(obj)
            self._commitments_done(obj)
            self._risk_cards(sit)
            self._conflict_cards(obj)

    def _situation_ask(self, ctx: List[Line], new: List[Line]):
        """One model call for the picture of the call; returns its JSON (or None) and logs what it cost."""
        c = self._bill(self.provider.complete(model=self.models["classify"], system=[{"text": self._situation_system()}],
                                              user=self._situation_user(ctx, new),
                                              max_tokens=self.cfg.get("situation_max_tokens", 900), cache_ttl=None,
                                              extra=(self.cfg.get("request_extra") or {}).get("classify")))
        self.out_llm.write({"at": s_to_hms(self.clock()), "role": "situation", "model": c.model, "line_id": new[-1].line_id,
                            "total_ms": c.ms(c.t_done), "input": c.input_tokens, "output": c.output_tokens,
                            "usd": c.usd, "error": c.error, "route": getattr(c, "route", None),
                            "incomplete": c.incomplete, "text_head": None if c.error else c.text[:160]})
        return first_json(c.text) if not c.error else None

    def _situation_system(self) -> str:
        import datetime as _dt
        meta = self.meta()
        lang = "Ukrainian" if (self.cfg.get("tips_lang") or meta.get("tips_lang", "uk")) == "uk" else "English"
        sysmsg = SITUATION_SYS.format(me=meta.get("me_label", "Me"), aliases=", ".join(meta.get("name_aliases", [])) or "-",
                                      projects=", ".join(meta.get("pm_projects") or [meta.get("project", "")]) or "-",
                                      people=", ".join(meta.get("participants") or []) or "unknown",
                                      today=_dt.date.today().strftime("%A %Y-%m-%d"), lang=lang)
        return sysmsg + self._situation_extra_rules() + self.correction_block()

    def _situation_user(self, ctx: List[Line], new: List[Line]) -> str:
        fmt = lambda h: "[{}] {}: {}".format(h.t, self.speakers.who(h), h.text[:400])  # noqa: E731
        speech = "\n".join("{}. {}".format(i, x) for i, x in enumerate(self.speech_items)) or "(none)"
        user = "PREVIOUS STATE: {}\n\nPM SPEECH POINTS:\n{}\n\nEARLIER LINES (context):\n{}\n\nNEW LINES:\n{}".format(
            json.dumps(self.situation or {}, ensure_ascii=False), speech, "\n".join(fmt(h) for h in ctx) or "-",
            "\n".join(fmt(h) for h in new[-60:]))
        return self._situation_extra_input() + user

    def add_mine(self, raw: str, from_id: str = "", from_text: str = "") -> None:
        """0.8.6: "Mine" on a transcript line, a tip or an "on them" item. Shown at once with the raw text; the call
        picture words it as a short action and marks it from = "mine<n>"."""
        raw = re.sub(r"\s+", " ", str(raw or "")).strip()[:240]
        if raw:
            typed = from_text == "@typed"         # typed by the PM in the On me tab: his words stay as they are
            self.onme_mine.append({"n": len(self.onme_mine) + 1, "raw": raw, "from_id": from_id,
                                   "from_text": "" if typed else from_text, "typed": typed})

    def fix_onme(self, sit: dict) -> dict:
        """The PM's On me corrections win over the model: "not mine" lines go, reworded ones keep his words."""
        mine = getattr(self, "onme_mine", None) or []
        if mine:
            acts = list(sit.get("actions") or [])
            for m in mine:
                if m.get("typed"):
                    acts = [a for a in acts if str(a.get("from", "")).strip().lower() != "mine{}".format(m["n"])]
                if m.get("typed") or not any(str(a.get("from", "")).strip().lower() == "mine{}".format(m["n"]) for a in acts):
                    acts.append({"id": "mine{}".format(m["n"]), "what": m["raw"][:120], "due": "", "from": "mine{}".format(m["n"])})
            gone = {re.sub(r"\W+", " ", m["from_text"]).strip().lower() for m in mine if m.get("from_text")}
            theirs = [t for t in (sit.get("theirs") or []) if re.sub(r"\W+", " ", str(t.get("what", ""))).strip().lower() not in gone]
            sit = dict(sit, actions=acts, theirs=theirs)
        if not self.onme_fixed or not sit.get("actions"):
            return sit
        from .commitments import norm_text
        out = []
        for a in sit.get("actions") or []:
            k = norm_text(a.get("what", ""))
            if k in self.onme_fixed:
                if not self.onme_fixed[k]:
                    continue
                a = dict(a, what=self.onme_fixed[k])
            out.append(a)
        return dict(sit, actions=out)

    def _publish_situation(self, sit: dict, line_id: int) -> None:
        sit = self.fix_onme(sit)
        with self.lock:
            self.sit_last_line = line_id
            changed = sit != self.situation
            self.situation = sit
        if changed:
            now = self.clock()
            self.out_tips.write(dict(sit, schema_version=1, engine="app", kind="situation", t=s_to_hms(now), at=s_to_hms(now)))
            if getattr(self, "sales", None) is not None:
                self._sales_step(sit, now)

    def _sales_step(self, sit: dict, now: float) -> None:
        """0.8.7 (rules/sales.yaml): the Deal tab's state and the sales tips (each once; the same limits as other tips)."""
        self.sales.update(sit)
        from .sales import observed_seller
        self.sales.observed = observed_seller(self.meta())   # 0.8.7 (H2): the role can change in the window
        hms = s_to_hms(now)
        self.out_tips.write(dict(self.sales.item(), schema_version=1, engine="app", t=hms, at=hms))
        recent = " ".join(str(a.get("what", "")) for a in (sit.get("objections") or []))
        for tip in self.sales.tips(sit, max(0.0, now - self.t_started), recent):
            if self.paused or self.tips_off():
                break
            self.out_tips.write(dict(tip, schema_version=1, engine="app", t=hms, at=hms))

    def sales_fix(self, key: str, state: str, what: str = "") -> None:
        if getattr(self, "sales", None) is not None:
            self.sales.fix(key, state, what)
            hms = s_to_hms(self.clock())
            self.out_tips.write(dict(self.sales.item(), schema_version=1, engine="app", t=hms, at=hms))

    def _asks_to_tips(self, sit: dict, hist: List[Line]) -> None:
        """A new open question or request to the PM that no tip covered yet (a third-person request, an
        implicit question) gets one red "answer" tip, once per ask."""
        for a in sit.get("asks") or []:
            line = self._ask_line(a, hist)
            if line is None:
                continue
            self._submit_tip(line, "direct_question", ask_span(line, a, self.clock()))
            # 2026-10-27 (owner): with no preparation, a question to the PM also starts a search of the project
            # folder at once, so the answer may be there before the PM has to ask for it.
            if a.get("type") == "question" and (getattr(self.prompt, "_brief", "") or "(no brief)").strip() == "(no brief)":
                self._start_deep(a.get("what", ""), "ask")
            elif a.get("type") == "question":
                self._maybe_proactive(a.get("what", ""), a.get("who") or self.speakers.who(line))   # 0.9.6 point 2

    def _ask_line(self, a: dict, hist: List[Line]) -> Optional[Line]:
        """The other side's line an ask came from, when it still needs a tip (each ask is looked at once)."""
        key = (a.get("t"), (a.get("what") or "")[:40])
        if a.get("type") == "update" or key in self.sit_asks_tipped:
            return None
        self.sit_asks_tipped.add(key)
        line = next((h for h in reversed(hist) if h.t == a.get("t")), None)
        if line is None or line.speaker != "them":
            return None
        with self.lock:
            if line.line_id in self.tipped_lines:
                return None
        return None if self.stale(line, "direct_question") else line

    # ---------- agenda and commitments register (Pacenote 0.8, F5) ----------
    def _situation_extra_rules(self) -> str:
        ag, cm = getattr(self.rules, "agenda", {}) or {}, getattr(self.rules, "commitments", {}) or {}
        keys = ['"theirs": [{"who": "<name>", "what": "<what they promised, max 12 words, in the call\'s language>", "due": "<day or date, or empty>", "t": "<HH:MM:SS>"}]']
        rules = ["- " + cm.get("model_rule_theirs", "theirs = promises other people made to the PM's side on this call.")]
        if cm.get("model_rule_not_commitments"):      # 0.8.7: reports of done work are not commitments
            rules.append("- " + cm["model_rule_not_commitments"])
        if getattr(self, "sales", None) is not None:  # 0.8.7: the qualification tracker (rules/sales.yaml > call_picture)
            k, r = self.sales.extra()
            if k:
                keys.append(k)
                rules.append("- " + r)
        if getattr(self, "active_decisions", None):     # 0.8.8 (rules/decisions.yaml > model_rule)
            dc = getattr(self.rules, "decisions", {}) or {}
            keys.append('"conflicts": [{"n": <number of the ACTIVE DECISION>, "who": "<name>", "t": "<HH:MM:SS>", '
                        '"remind": "<one short sentence the PM can say to remind them, in the call\'s language>"}]')
            rules.append("- " + " ".join(str(dc.get("model_rule", "conflicts = someone contradicts an ACTIVE DECISION.")).split()))
        rk = getattr(self.rules, "risks", {}) or {}
        keys.append('"risks": [{"what": "<what may go wrong and on what it depends, max 16 words, in the call\'s language>", "who": "<name>", "t": "<HH:MM:SS>"}]')
        rules.append("- " + rk.get("model_rule", "risks = conditional threats said on this call."))
        if self.agenda_items:
            keys += ['"agenda_now": <number or -1>', '"agenda_done": [<numbers>]']
            rules.append("- " + ag.get("model_rule", "agenda_now = the AGENDA item discussed now; agenda_done = items discussed."))
        if self.open_commitments:
            keys.append('"done_commitments": ["<id>"]')
            rules.append("- " + cm.get("model_rule_done", "done_commitments = ids of OPEN COMMITMENTS said to be done."))
        return "\nAlso return these keys in the same JSON object: {}.\n{}".format(", ".join(keys), "\n".join(rules))

    def rate_tip(self, value) -> None:
        """tip_feedback from the window: 'verdict|card|t|gist[|r=a,b][|c=comment]' (skill/references/window.md)."""
        v = str(value or "")
        verdict, sep, rest = v.partition("|")
        if not sep or verdict not in ("used", "partly", "not_useful"):
            return
        comment, reasons = "", []
        i = rest.rfind("|c=")
        if i >= 0:
            comment, rest = rest[i + 3:].strip(), rest[:i]
        i = rest.rfind("|r=")
        if i >= 0:
            reasons, rest = [r for r in rest[i + 3:].split(",") if r.strip()], rest[:i]
        gist = rest.split("|", 2)[-1]
        with self.lock:
            self.tip_ratings.pop(rest, None)
            self.tip_ratings[rest] = {"verdict": verdict, "reasons": reasons, "comment": comment[:300], "tip": gist[:120]}

    def _situation_extra_input(self) -> str:
        parts = []
        if self.agenda_items:
            full = getattr(self, "agenda_full", None) or [t for t, _ in self.agenda_items]
            parts.append("AGENDA:\n" + "\n".join("{}. {}".format(i, t) for i, t in enumerate(full)))
        left = [c for c in self.open_commitments if c["id"] not in self.commit_proposed]
        if left:
            parts.append("OPEN COMMITMENTS (from earlier calls; id | owner | what):\n" + "\n".join(
                "{} | {} | {}{}".format(c["id"], c.get("owner") or "me", c.get("text", ""), " | due " + c["due"] if c.get("due") else "")
                for c in left))
        if getattr(self, "active_decisions", None):     # 0.8.8: the register's active decisions of this project (the snapshot)
            parts.append("ACTIVE DECISIONS OF THE PROJECT (number | date | decision | stated by):\n" + "\n".join(
                "{} | {} | {} | {}".format(i, d.get("date", ""), d.get("title", ""), d.get("stated_by", ""))
                for i, d in enumerate(self.active_decisions)))
        if self.onme_fixed:          # 0.8.5: the PM's own On me corrections in this call
            parts.append("THE PM CORRECTED HIS ON-ME LIST (never put lines like the removed ones on him again; use his wording):\n" + "\n".join(
                ("removed: " + k) if not v else ("reworded: {} -> {}".format(k, v)) for k, v in list(self.onme_fixed.items())[-12:]))
        if getattr(self, "onme_mine", None):           # 0.8.6: the PM made these his ("Mine"): add each to actions, worded short
            parts.append("THE PM MADE THESE HIS (add each to actions as a short action in the call language, with the due date "
                         "when one was said, and set its from to the given tag):\n" + "\n".join(
                             "mine{} | {}".format(m["n"], m["raw"]) for m in self.onme_mine[-12:] if not m.get("typed")))
        return "\n\n".join(parts) + ("\n\n" if parts else "")

    def _agenda_snapshot(self):
        return (list(self.agenda_items), list(self.agenda_full), set(self.agenda_done),
                self.agenda_now, dict(self.agenda_manual), self.agenda_obtain, list(self.agenda_ids))

    def undo_agenda_refresh(self) -> None:
        with self.lock:
            previous = getattr(self, "_agenda_previous", None)
            if not previous:
                return
            self._agenda_previous = None
            self.context_revision += 1
            self.situation = None
            self.agenda_items, self.agenda_full, self.agenda_done, self.agenda_now, self.agenda_manual, self.agenda_obtain, self.agenda_ids = previous
        self.agenda_sent = None
        self._emit_agenda()

    def _inherit_agenda(self, previous, old_manual):
        self.agenda_done = {i for i, old in previous.items() if old["state"] == "done"}
        self.agenda_now = next((i for i, old in previous.items() if old["state"] == "now"), -1)
        self.agenda_manual = {i: old_manual[old["id"]] for i, old in previous.items() if old["id"] in old_manual}

    def set_agenda_items(self, brief_text: str, remember: bool = True) -> None:
        """Retain same-call identities and states; ambiguous legacy matches stay open."""
        ag = getattr(self.rules, "agenda", {}) or {}
        full = agenda_mod.full_items(brief_text, int(ag.get("max_items", 20)))
        with self.lock:
            if full == list(zip(self.agenda_full, [d for _, d in self.agenda_items])):
                self.agenda_obtain = agenda_mod.to_obtain(brief_text)
                return
            if remember and self.agenda_items:
                self._agenda_previous = self._agenda_snapshot()
            old_strip = self.agenda_strip()
            old_manual = {self.agenda_ids[i]: state for i, state in self.agenda_manual.items()}
            previous = agenda_mod.match_identities(old_strip, brief_text, full)
            self.agenda_ids = agenda_mod.assign_ids(previous, len(full))
            self.agenda_items = [(agenda_mod.shorten(t, int(ag.get("max_chars", 60))), d) for t, d in full]
            self.agenda_full = [t for t, _ in full]
            self.agenda_obtain = agenda_mod.to_obtain(brief_text)
            self._inherit_agenda(previous, old_manual)
        self._emit_agenda()

    def agenda_strip(self) -> List[dict]:
        with self.lock:
            st = agenda_mod.states(self.agenda_items, self.agenda_done, self.agenda_now, self.agenda_manual)
            full = getattr(self, "agenda_full", None) or [t for t, _ in self.agenda_items]
            return [dict({"id": identity, "text": t, "done": s == "done", "cur": s == "now", "state": s}, **({"full": f} if f != t else {}))
                    for (t, _), s, f, identity in zip(self.agenda_items, st, full, self.agenda_ids)]

    def _emit_agenda(self, final: bool = False) -> None:
        with self.lock:
            if not self.agenda_items and not self.agenda_sent:
                return
            strip = self.agenda_strip()
            if strip == self.agenda_sent and not final:
                return
            self.agenda_sent = strip
            t = s_to_hms(self.clock())
            out = {"schema_version": 1, "engine": "app", "kind": "agenda", "t": t, "at": t,
                   "gist": "Агенда" if self._ui_uk() else "Agenda", "items": strip,
                   "can_undo": bool(getattr(self, "_agenda_previous", None))}
            if final:
                out["final"] = True
            self.out_tips.write(out)

    def _agenda_from_model(self, obj: dict) -> None:
        if not self.agenda_items:
            return
        n = len(self.agenda_items)
        done = {int(i) for i in (obj.get("agenda_done") or []) if str(i).lstrip("-").isdigit() and 0 <= int(i) < n}
        # 0.9.2 (rules/agenda.yaml > model_rule, audit 04.11: "agree the Sales priority" ticked with no yes from anyone):
        # an item to agree or decide is done only when the call picture holds a decision on its subject.
        decisions = [str(x) for x in (obj.get("decisions") or []) + list((self.situation or {}).get("decisions") or [])]
        full = getattr(self, "agenda_full", None) or []
        texts = [str(full[i]) if i < len(full) else str(self.agenda_items[i][0]) for i in range(n)]
        done = {i for i in done if not DECIDE_ITEM.search(texts[i]) or decided_on(texts[i], decisions)}
        try:
            now = int(obj.get("agenda_now", -1))
        except (TypeError, ValueError):
            now = -1
        with self.lock:
            self.agenda_done |= done
            self.agenda_now = now if 0 <= now < n and now not in self.agenda_done else -1
        self._emit_agenda()

    def set_agenda_state(self, value: str) -> None:
        """Stable ID (legacy index accepted) and state from the window; resolve under the refresh lock."""
        with self.lock:
            try:
                idx, state = str(value).split("|", 1)
                i = self.agenda_ids.index(idx) if idx in self.agenda_ids else int(str(idx).lstrip("ab"))
            except ValueError:
                return
            if state not in ("todo", "now", "done", "skip") or not 0 <= i < len(self.agenda_items):
                return
            if state == "now":
                self.agenda_manual = {k: v for k, v in self.agenda_manual.items() if v != "now"}
            self.agenda_manual[i] = state
        self._emit_agenda()

    def _commitments_done(self, obj: dict) -> None:
        """An open commitment said to be done: a quiet card "Done? <item>"; only the PM's click closes it."""
        ids = {c["id"]: c for c in self.open_commitments}
        for cid in obj.get("done_commitments") or []:
            c = ids.get(str(cid))
            if not c or c["id"] in self.commit_proposed:
                continue
            self.commit_proposed.add(c["id"])
            self.out_tips.write(commitment_card(c, s_to_hms(self.clock()), self._ui_uk()))

    def _risk_cards(self, sit: dict) -> None:
        """A new risk: one quiet card in Earlier (rules/risks.yaml > during_call), never red. 0.9.6 (owner, 05.11):
        a risk the PM said himself is not shown, he just said it; it stays in the call picture and the wrap-up."""
        for r in sit.get("risks") or []:
            key = r.get("what", "")[:60].lower()
            if key in self.risks_shown:
                continue
            self.risks_shown.add(key)
            if self._is_pm(r.get("who", "")):
                continue
            t = s_to_hms(self.clock())
            self.out_tips.write({"schema_version": 1, "engine": "app", "kind": "risk", "level": "info", "t": t, "at": t,
                                 "src": r.get("t") or t, "who": r.get("who", ""),
                                 "gist": ("Ризик: " if self._ui_uk() else "Risk: ") + r.get("what", "")})

    def _is_pm(self, who: str) -> bool:
        """The call picture names the PM "PM", by the "me" label or by one of the PM's names."""
        w = " ".join(str(who or "").lower().replace(".", " ").split())
        if not w:
            return False
        meta = self.meta()
        names = {"pm", "me", "я", str(meta.get("me_label", "")).lower()} | {str(a).lower() for a in (meta.get("name_aliases") or []) + list(self.cfg.get("name_aliases") or [])}
        names = {" ".join(n.replace(".", " ").split()) for n in names if n.strip()}
        return w in names

    def _conflict_cards(self, obj: dict) -> None:
        """0.8.8 (rules/decisions.yaml > during_call): someone contradicts an active decision: one quiet card, each
        decision once a call, never the main card, never red."""
        for c in obj.get("conflicts") or [] if getattr(self, "active_decisions", None) else []:
            if not isinstance(c, dict):
                continue
            try:
                d = self.active_decisions[int(c.get("n"))]
            except (TypeError, ValueError, IndexError):
                continue
            key = d.get("title", "")[:60].lower()
            if not key or key in self.conflicts_shown:
                continue
            self.conflicts_shown.add(key)
            t = s_to_hms(self.clock())
            self.out_tips.write(decision_conflict_card(d, c, t, self._ui_uk()))

    def commitment_closed(self, cid: str) -> None:
        self.commit_proposed.add(str(cid))

    def write_register(self) -> List[dict]:
        if not (self.cfg.get("commitments", True) and self.register_dir and self.cfg.get("call_file")):
            return []
        sit = self.fix_onme(self.situation or {})
        m = self.meta()
        return register.record_call(self.register_dir, call=self.cfg["call_file"], project=m.get("project", ""),
                                    title=self.cfg.get("title") or m.get("title", ""), actions=sit.get("actions") or [],
                                    theirs=sit.get("theirs") or [], ticked=self.onme_ticked, by="app",
                                    replaces={"mine{}".format(m["n"]): m["from_id"] for m in getattr(self, "onme_mine", []) if m.get("from_id")})

    def final_wrapup(self) -> Optional[dict]:
        """P2 (26.10): at the end, the window gets what the call picture holds: decisions, what is on the PM,
        open asks and the speech points never said. No model call."""
        sit = self.situation or {}
        self._emit_agenda(final=True)
        if getattr(self, "sales", None) is not None and self.cfg.get("call_md"):
            try:                     # 0.8.7: the Sales section and the scorecard of the call page (<stem>.sales.json)
                md = Path(self.cfg["call_md"])
                asks = [a for a in (sit.get("asks") or []) if a.get("type") != "update"]
                self.sales.write(md.with_name(md.name[:-3] + ".sales.json" if md.name.endswith(".md") else md.name + ".sales.json"),
                                 open_questions=len(asks))
            except Exception as e:  # noqa: BLE001
                self.out_timing.write({"outcome": "sales_error", "error": repr(e)[:200]})
        try:
            self.write_register()
        except Exception as e:  # noqa: BLE001
            self.out_timing.write({"outcome": "register_error", "error": repr(e)[:200]})
        uk = self._ui_uk()
        L = (lambda u, e: u if uk else e)  # noqa: E731
        items = picture_items(sit, uk) + missed_speech(self.speech_items, sit.get("speech_done"), uk)
        if not items:
            return None
        now = self.clock()
        out = {"schema_version": 1, "engine": "app", "uid": "call-picture", "t": s_to_hms(now), "src": s_to_hms(now),
               "kind": "wrapup", "level": "info", "gist": L("📋 Підсумок дзвінка", "📋 Call summary"),
               "items": items[:24], "note": L("з картини дзвінка, без перевірки", "from the call picture, unchecked"),
               "at": s_to_hms(now)}
        self.out_tips.write(out)
        return out

    def drain(self, timeout: float = 60.0) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            pending = [f for f in self.futures if not f.done()]
            if not pending:
                break
            time.sleep(0.2)
        self.pool.shutdown(wait=False)
        a = getattr(self, "_agent_obj", None)
        if a is not None:                      # 0.9.6: the call agent's session ends with the call
            a.close()


class AgentContext:
    """The call agent's own tools (livetips_m0.agent): what the engine already knows, read on demand. Since 0.9.6 Б2
    the data comes from pn_tools (the same functions the preparation gets through pn_mcp); brief() stays here, as
    brief_covers() decides the background searches on its text."""

    def __init__(self, engine):
        self.e = engine

    def search(self, query: str) -> str:
        from . import pn_tools
        return pn_tools.search(self.e._search_roots(), query, self.e.cfg.get("lt_cmd"))

    def transcript(self, query: str, last: int = 40) -> str:
        from . import pn_tools
        with self.e.lock:
            hist = list(self.e.history)
        return pn_tools.transcript(hist, query, last)

    def brief(self) -> str:
        p = self.e.prompt
        return (getattr(p, "_brief", "") or "(no brief)") + "\n\n" + (p.blocks[2]["text"] if len(p.blocks) > 2 else "")

    def past_calls(self, query: str) -> str:
        root = self.e.cfg.get("project_root")
        if not root:
            return ""
        from . import pn_tools
        lt = self.e.cfg.get("lt_cmd")
        return pn_tools.past_calls(root, 3, query, lt if isinstance(lt, list) else None)

    def commitments(self, open_only: bool = True) -> str:
        from . import pn_tools
        return pn_tools.commitments(self.e.cfg.get("project_root"), open_only)

    def decisions(self, area=None) -> str:
        from . import pn_tools
        return pn_tools.decisions(self.e.cfg.get("project_root"), area)

    def project_state(self) -> str:
        from . import pn_tools
        return pn_tools.project_state(self.e.cfg.get("project_root"))


class SpeakerNames:
    """Display names for the other side's lines, as in the skill (@@SPEAKERS): the PM names a voice in
    the tips window, the recorder writes <stem>.speakers.json (clusters, merges, per-line fixes), and
    the prompt shows "Name" instead of "Them [S2]". Re-read when the file changes. Unnamed voices keep
    the label and tag ("Them [S3]"); the PM's own lines keep the PM label."""

    def __init__(self, path):
        self.path = Path(path) if path else None
        self.mtime = None
        self.clusters, self.merged, self.overrides = {}, {}, {}

    def _load(self):
        if not self.path:
            return
        try:
            m = self.path.stat().st_mtime
        except OSError:
            return
        if m == self.mtime:
            return
        try:
            d = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        self.mtime = m
        g = lambda k: d.get(k) if isinstance(d.get(k), dict) else {}
        self.clusters, self.merged, self.overrides = g("clusters"), g("merged"), g("overrides")

    def name(self, t, sid):
        self._load()
        s, seen = self.overrides.get(t) or sid, set()
        while s in self.merged and s not in seen:
            seen.add(s)
            s = self.merged[s]
        if isinstance(s, str) and s.startswith("name:"):
            return s[5:]
        c = self.clusters.get(s) if s else None
        return c.get("name") if isinstance(c, dict) and c.get("name") else None

    def who(self, line) -> str:
        if line.speaker == "me":
            return line.label
        n = self.name(line.t, line.stag)
        if n:
            return n
        return "{} [{}]".format(line.label, line.stag) if line.stag else line.label
