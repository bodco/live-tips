"""0.10.0 co-driver mode (owner, 2026-11-12): the two jobs live tips exist for.

1. Prompter: whatever the PM forgot 10 seconds before the call, the window keeps telling him what to say now.
   A topic card ("topic_primer") on every new stable topic: what the PM knows about it and one line to say or ask.
2. Questions from anyone: a question asked by anyone on the call (not only to the PM) gets an answer from the
   prepared context; when the context does not hold it, a card says at once that the question was heard and the
   project is being searched ("heard"), and the answer card follows. A reflection or proposal of the other side
   (no question) gets a paraphrase to check understanding or a counter-question ("reflect"), sparingly.

Switch: cfg "codriver" (default true). With it off the engine behaves as in 0.9.7.
Diagnosis behind it: research/pacenote-live-tips-regression-2026-11-12.md (40 of 40 classify said no tip, 6 of 6
tips skipped "not asking Bohdan", while the answer was in the context).
"""
import re
from typing import List, Optional

TRIGGERS = ("question_any", "reflect", "topic_primer")

CLASSIFY_CODRIVER = (
    "Co-driver mode: the PM wants help on every real question and every substantive point of the others. "
    "need_tip is true, trigger question_any, level orange, for ANY real question someone other than the PM asks "
    "(to the PM, to another person or to the room), whether or not the context holds the answer: the tip step "
    "answers it or starts a search. Not for small talk, a rhetorical question, a question the same speaker answers "
    "at once, or one already answered aloud. A question to the PM by name or 'you' stays direct_question, red. "
    "need_tip is true, trigger reflect, level orange, when someone other than the PM finishes a substantive point "
    "(a proposal, a doubt, a problem, a plan, a decision forming) that the PM should react to; not for a status "
    "line, a filler, or a point the PM already reacted to. Otherwise the table above decides.")

ADDRESS_CODRIVER = (
    "- Co-driver mode (owner 2026-11-12), it overrides the skip in the line above: the PM is a listener who may have "
    "forgotten everything about this call. A real question of anyone with no answer in the context is never a plain "
    "skip: it becomes a search (event question_any). Who was addressed does not matter, the PM may answer, add or steer.")

QUESTION_ANY_EVENT = (
    "question_any. {who} asked a question on the call (to the PM, to someone else or to the room). "
    "If the brief, the fact book, the cards, the project state, PROJECT PASSAGES below or the earlier transcript "
    "answer it, give ONE orange tip: gist exactly '🟠 <who> asks: <the question>' (the window shows who and the "
    "question from it); why = what the sources say; "
    "phrase = the answer the PM can say or add, short answer first; note = the source. "
    "If nothing here answers it, do NOT invent and do NOT plain-skip: return "
    "{{\"skip\": true, \"reason\": \"not in context\", \"heard\": \"<the question itself in one short sentence, tips language, without who asks>\", "
    "\"who\": \"<who asked>\", \"search\": \"<what to find in the project: earlier calls, notes, tickets>\"}}. "
    "Plain skip only when it was already answered aloud, is small talk, or the speaker answered it himself.")

REFLECT_EVENT = (
    "reflect. {who} made a substantive point (a proposal, a doubt, a problem, a plan). Give ONE orange tip that "
    "helps the PM react smartly, or skip if the PM already reacted, the point is trivial, or it repeats tips_given. "
    "gist = '💬 ' + what {who} means, in one plain sentence. phrase = ONE of: a short paraphrase to check "
    "understanding ('So if I got it right, ... Is that correct?'), or ONE counter-question that moves the call goal "
    "(scope, owner, date, risk, what it means for us), or a fact from the context that confirms or contradicts it "
    "(then note = the source). Prefer the fact when there is one. Never agree to scope, dates or estimates for the PM.")

TOPIC_PRIMER_EVENT = (
    "topic_primer. The talk has moved to a new topic: \"{topic}\". The PM may remember nothing about it. "
    "Give ONE info tip that works like a prompter: gist '📌 ' + the topic and where it stands BY THE SOURCES (not a "
    "retelling of what was just said aloud), one plain sentence; items = up to 3 short lines the PM knows about it from "
    "the brief, the fact book, the cards, the project state or PROJECT PASSAGES (status, numbers, owners, dates, what "
    "was agreed before, what is open), each with no invented number; phrase = one thing the PM can say or ask now "
    "about it. Skip when nothing in the context is about this topic beyond what was said aloud, or tips_given "
    "already covers it.")


def event_for(trigger: str, who: str = "", topic: str = "", passages: str = "") -> str:
    who = who or "someone"
    if trigger == "question_any":
        ev = QUESTION_ANY_EVENT.format(who=who)
    elif trigger == "reflect":
        ev = REFLECT_EVENT.format(who=who)
    elif trigger == "topic_primer":
        ev = TOPIC_PRIMER_EVENT.format(topic=topic.replace('"', "'"))
    else:
        return trigger
    if passages:
        ev += "\n\nPROJECT PASSAGES (searched just now, newest first; facts only from here, the brief or the transcript):\n" + passages
    return ev


def passages_text(snips: List[dict], limit: int = 6000) -> str:
    out, used = [], 0
    for s in snips or []:
        t = " ".join(str(s.get("text") or "").split())
        if not t:
            continue
        row = "[{}{}] {}".format(s.get("src") or "?", (", " + s["date"]) if s.get("date") else "", t[:900])
        if used + len(row) > limit:
            break
        out.append(row)
        used += len(row)
    return "\n".join(out)


WHO_ASKS = re.compile(r"^\s*(\S+(\s\S\.?)?\s+)?(asks|is asking|wants to know|питає|запитує|цікавиться)\s*[:,]?\s*", re.I)


def heard_text(q: str) -> str:
    """The question without a leading "Santiago asks" the model may add ("if we..." stays: "whether we...")."""
    q = " ".join(str(q or "").split())
    if not WHO_ASKS.match(q):
        return q
    out = WHO_ASKS.sub("", q, count=1)
    out = re.sub(r"^if\b", "whether", out, flags=re.I)
    return out or q


def heard_card(obj: dict, uid: str, src: str, at: str, uk: bool, fast: bool) -> dict:
    """The card shown at once for a question the context does not answer: heard, searching."""
    q = heard_text(obj.get("heard"))
    who = str(obj.get("who") or "").strip()
    if uk:
        gist = "🔎 " + ((who + " питає: ") if who else "Питання: ") + q
        note = "чую питання, шукаю в проєкті" + (", кілька секунд" if fast else ", до хвилини")
    else:
        gist = "🔎 " + ((who + " asks: ") if who else "Question: ") + q
        note = "heard the question, searching the project" + (", a few seconds" if fast else ", up to a minute")
    return {k: v for k, v in {"schema_version": 1, "engine": "app", "uid": uid, "t": at, "src": src, "kind": "answer",
                              "level": "orange", "gist": gist[:160], "q": q, "who": who, "note": note, "trigger": "heard",
                              "pending": True, "at": at}.items() if v not in ("", None)}


def not_found_card(res: dict, uk: bool) -> dict:
    """The answer card for a heard question the project search did not answer: say so, nearest known, a bridge."""
    near = str(res.get("gist") or "").lstrip("🔎 ").strip()
    if uk:
        gist = "🔎 У проєкті прямої відповіді нема" + ((": найближче, " + near) if near else "")
        phrase = res.get("phrase") or "Хороше питання, я уточню і повернусь з відповіддю сьогодні."
    else:
        gist = "🔎 No direct answer in the project" + ((". Nearest: " + near) if near else "")
        phrase = res.get("phrase") or "Good question. Let me check and come back to you today."
    return {"gist": gist[:160], "phrase": phrase, "level": "info",
            "items": [str(x) for x in (res.get("items") or [])][:3]}


def same_question(a: str, b: str) -> bool:
    wa = {w for w in re.findall(r"\w{3,}", (a or "").lower())}
    wb = {w for w in re.findall(r"\w{3,}", (b or "").lower())}
    if not wa or not wb:
        return False
    return len(wa & wb) / max(1, len(wa | wb)) >= 0.5


def primer_due(topic: str, last_topics: List[str], last_at: Optional[float], now: float, gap_s: float,
               sim) -> bool:
    """A new topic card when the topic is new versus the last primers and the gap since the last one has passed."""
    t = (topic or "").strip()
    if len(t) < 3:
        return False
    if last_at is not None and now - last_at < gap_s:
        return False
    return not any(sim(t, x) for x in last_topics[-6:])
