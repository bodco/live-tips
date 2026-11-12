"""0.10.0 co-driver (owner 2026-11-12): every question of anyone is answered or searched with a "heard" card,
reflections get a paraphrase or a counter-question, and new topics get a prompter card (livetips_m0.codriver)."""
import json

from livetips_m0 import codriver
from livetips_m0.prompt import PromptBuilder
from livetips_m0.rules import Rules
from test_engine import _feed, _meeting_engine, _out


def _resp(tip):
    def resp(model, user):
        if "ROLE classify" in user:
            return json.dumps({"need_tip": True, "level": "orange", "trigger": "question_any", "topic": "3DS pricing"})
        return json.dumps(tip)
    return resp


def test_classify_prompt_has_codriver_by_default_and_not_when_off():
    meta = {"answer_any": True, "me_label": "Me", "them_label": "Other"}
    on = PromptBuilder(Rules(), dict(meta)).user("classify", "", [], {})
    off = PromptBuilder(Rules(), dict(meta, codriver=False)).user("classify", "", [], {})
    assert "Co-driver mode" in on and "question_any" in on
    assert "Co-driver mode" not in off


def test_question_of_anyone_without_answer_shows_heard_and_searches(tmp_path):
    eng, clock = _meeting_engine(tmp_path, _resp({"skip": True, "reason": "not in context", "heard": "When does 3DS start?",
                                                  "who": "Mike", "search": "3DS start date, Pomelo sandbox"}),
                                 deep_lookup=True, answer_any=True)
    started = []
    eng._start_deep = lambda q, kind: started.append((q, kind))
    _feed(eng, clock, "[10:00:00] Other [S1] (en): Emily, when do we start the 3DS work?", 1, 36001)
    tips, timing = _out(tmp_path)
    heard = [t for t in tips if t.get("trigger") == "heard"]
    assert len(heard) == 1 and heard[0]["kind"] == "answer" and heard[0]["pending"] is True
    assert heard[0]["gist"].startswith("🔎 Mike asks: When does 3DS start?")
    assert started == [("When does 3DS start? | 3DS start date, Pomelo sandbox", "heard")]


def test_the_same_question_is_heard_once(tmp_path):
    eng, clock = _meeting_engine(tmp_path, _resp({"skip": True, "heard": "When does 3DS start?", "who": "Mike"}),
                                 deep_lookup=True, answer_any=True)
    eng._start_deep = lambda q, kind: None
    _feed(eng, clock, "[10:00:00] Other [S1] (en): When do we start the 3DS work?", 1, 36001)
    _feed(eng, clock, "[10:00:30] Other [S1] (en): So when does the 3DS start, roughly?", 2, 36031)
    tips, _ = _out(tmp_path)
    assert len([t for t in tips if t.get("trigger") == "heard"]) == 1


def test_codriver_off_keeps_the_plain_skip(tmp_path):
    eng, clock = _meeting_engine(tmp_path, _resp({"skip": True, "heard": "When does 3DS start?", "who": "Mike"}),
                                 deep_lookup=True, answer_any=True, codriver=False)
    eng._start_deep = lambda q, kind: None
    _feed(eng, clock, "[10:00:00] Other [S1] (en): When do we start the 3DS work?", 1, 36001)
    tips, _ = _out(tmp_path)
    assert not [t for t in tips if t.get("trigger") == "heard"]


def test_answer_from_context_is_an_orange_tip(tmp_path):
    eng, clock = _meeting_engine(tmp_path, _resp({"gist": "🟠 Mike asks when 3DS starts: it waits for the sandbox",
                                                  "level": "orange", "topic": "3DS start",
                                                  "phrase": "It starts once we have sandbox access."}), answer_any=True)
    _feed(eng, clock, "[10:00:00] Other [S1] (en): Mike here. When does the 3DS work start?", 1, 36001)
    tips, _ = _out(tmp_path)
    shown = [t for t in tips if t.get("kind") == "tip" and not t.get("partial")]
    assert shown and shown[0].get("trigger") == "question_any" and shown[0]["level"] == "orange", tips


def test_cards_and_gates():
    c = codriver.heard_card({"heard": "When?", "who": "Mike"}, "h1", "10:00:00", "10:00:02", uk=True, fast=True)
    assert c["gist"] == "🔎 Mike питає: When?" and c["uid"] == "h1" and "шукаю" in c["note"]
    nf = codriver.not_found_card({"gist": "🔎 3DS waits for the sandbox"}, uk=False)
    assert nf["gist"].startswith("🔎 No direct answer") and "sandbox" in nf["gist"] and nf["phrase"]
    assert codriver.same_question("When does 3DS start?", "when does the 3DS start")
    sim = lambda a, b: a.lower() == b.lower()  # noqa: E731
    assert codriver.primer_due("3DS pricing", [], None, 100.0, 45, sim)
    assert not codriver.primer_due("3DS pricing", ["3ds pricing"], None, 100.0, 45, sim)
    assert not codriver.primer_due("Audit logs", [], 80.0, 100.0, 45, sim)
    assert chr(0x2014) not in "".join([codriver.CLASSIFY_CODRIVER, codriver.ADDRESS_CODRIVER, codriver.QUESTION_ANY_EVENT,
                                       codriver.REFLECT_EVENT, codriver.TOPIC_PRIMER_EVENT])


def test_heard_text_drops_who_asks():
    assert codriver.heard_text("Mike asks if we will be over 10,000 transactions") == "whether we will be over 10,000 transactions"
    assert codriver.heard_text("Emily питає: коли старт?") == "коли старт?"
    assert codriver.heard_text("When does 3DS start?") == "When does 3DS start?"
