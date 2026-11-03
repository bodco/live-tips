"""2026-11-02 reviews of two real calls (a discovery interview and a client monthly review)."""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

from livetips_m0 import agenda
from livetips_m0.engine import ANY_ELSE, WRAP_ASK, WRAP_SAY, is_backchannel, last_question_and_answer
from test_engine import _feed, _meeting_engine, _no_tip_classify, _out
from test_engine_routes import _l

BRIEF = """# Brief

## Checklist
""" + "\n".join("- [ ] {}. A long open interview question number {} about how the lead moves to a call with sales".format(i, i)
                for i in range(1, 14)) + """
- [ ] RAIL: walk the open items below
- Decisions to obtain: a date for access; who unblocks the accounts; the next step with a date
"""


def test_agenda_keeps_all_items_full_text_and_skips_pointer_lines():
    full = agenda.full_items(BRIEF)
    assert len(full) == 13 and full[12][0].startswith("13. A long open interview question")
    short = agenda.from_brief(BRIEF)
    assert len(short) == 13 and short[0][0].endswith("…") and len(short[0][0]) <= 60
    assert agenda.to_obtain(BRIEF).startswith("a date for access")
    assert agenda.to_obtain("Рішення і результати, які треба отримати: (а) приклад; (б) історії").startswith("(а) приклад")


def test_backchannel_is_not_the_question():
    for t in ("Мхм.", "Ну да.", "Ok.", "Та, норм.", "100%", "Т.е.", "Yeah."):
        assert is_backchannel(t), t
    for t in ("Як ти дізнаєшся, чим закінчився дзвінок?", "q?", "And how do you check the data then"):
        assert not is_backchannel(t), t
    q, ans = last_question_and_answer([_l(1, "me", "Як ви формуєте тон повідомлень для ліда"), _l(2, "them", "a"),
                                       _l(3, "me", "Мхм."), _l(4, "them", "b")])
    assert q.line_id == 1 and [h.line_id for h in ans] == [4, 2]


def test_wrap_phrases():
    assert ANY_ELSE.search("What else? Anything else you wanted to go over today?")
    assert ANY_ELSE.search("Є ще питання до мене?")
    assert WRAP_SAY.search("Nope, my list is closed") and WRAP_SAY.search("Ніби по всьому пройшлись, що ми хотіли")
    assert WRAP_ASK.search("що я там ще забув?") and not WRAP_ASK.search("скільки коштує підписка")


def test_interviewer_clarifies_after_mhm_and_again_on_a_long_story(tmp_path):
    def resp(model, user):
        if "ROLE classify" in user:
            return _no_tip_classify(model, user)
        if "role interviewer: the other person" in user:
            return json.dumps({"gist": "🟠 Clarify: last case " + str(len(user)), "level": "orange", "topic": "c" + str(len(user)),
                               "phrase": "Розкажи про останній такий випадок?"})
        return json.dumps({"skip": True, "reason": "x"})
    eng, clock = _meeting_engine(tmp_path, resp, call_type="interview", hiring_role="interviewer")
    words = " ".join(["ми шукаємо лідів через sales navigator і фільтруємо за ICP"] * 3)    # 27 words
    _feed(eng, clock, "[10:00:00] Me (uk): Розкажи як лід проходить шлях до дзвінка з сейлом", 1, 36001)
    _feed(eng, clock, "[10:00:05] Other (uk): " + words, 2, 36006)
    _feed(eng, clock, "[10:00:10] Me (uk): Мхм.", 3, 36011)
    _feed(eng, clock, "[10:00:15] Other (uk): " + words, 4, 36016)          # 54 words after the question: clarify
    for i in range(4):                                                       # the story goes on: +120 words, no more yet
        _feed(eng, clock, "[10:00:{}] Other (uk): ".format(20 + i) + words, 5 + i, 36021 + i)
    _feed(eng, clock, "[10:00:30] Other (uk): " + words, 10, 36031)        # +150 words since the first clarify: one more
    tips, _ = _out(tmp_path)
    full = [t for t in tips if not t.get("partial") and t.get("kind") == "tip"]
    assert [t["src"] for t in full] == ["10:00:15", "10:00:30"]


def test_wrap_check_on_anything_else(tmp_path):
    seen = {}

    def resp(model, user):
        if "WRAP CHECK" in user:
            seen["user"] = user
            return json.dumps({"gist": "🎯 Not covered yet: 2", "level": "red", "items": ["VPN block", "MSA copy"],
                               "phrase": "One more thing before we go: the VPN block."})
        if "ROLE classify" in user:
            return _no_tip_classify(model, user)
        return json.dumps({"skip": True, "reason": "x"})
    eng, clock = _meeting_engine(tmp_path, resp)
    eng.set_agenda_items(BRIEF)
    _feed(eng, clock, "[10:00:00] Me (en): Phase two started, only the tool access is open.", 1, 36001)
    _feed(eng, clock, "[10:04:00] Other (en): Was there anything else I'm forgetting there?", 2, 36241)   # 4 min in: no
    _feed(eng, clock, "[10:16:10] Other (en): What else? Anything else you wanted to go over today?", 3, 36971)
    _feed(eng, clock, "[10:16:40] Other (en): Anything else at all?", 4, 37001)         # within 5 min: once
    tips, _ = _out(tmp_path)
    wraps = [t for t in tips if t.get("trigger") == "timer_checkpoint"]
    assert len(wraps) == 1 and wraps[0]["level"] == "red" and wraps[0]["items"] == ["VPN block", "MSA copy"]
    u = seen["user"]
    assert "DECISIONS TO OBTAIN:\na date for access" in u and "13. A long open interview question" in u
    assert "Phase two started" in u


def test_wrap_check_from_a_typed_ask(tmp_path):
    def resp(model, user):
        if "WRAP CHECK" in user:
            return json.dumps({"gist": "🎯 Ще не покрито: 1", "level": "red", "items": ["Питання 7"]})
        return json.dumps({"skip": True, "reason": "x"})
    eng, clock = _meeting_engine(tmp_path, resp)
    eng.set_agenda_items(BRIEF)
    clock["t"] = 36100
    eng.on_request("ask", "що я там ще забув?")
    for f in eng.futures:
        f.result(timeout=5)
    tips, _ = _out(tmp_path)
    assert any(t.get("gist") == "🎯 Ще не покрито: 1" and t.get("kind") == "tip" for t in tips)


@pytest.fixture(scope="module")
def T():
    src = Path(__file__).resolve().parents[3] / "recorder/src/transcriber.py"
    spec = importlib.util.spec_from_file_location("lt_transcriber_1102", src)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber_1102"] = mod
    spec.loader.exec_module(mod)
    return mod


def test_sos_project_snippet_only_when_nothing_else_and_without_page_ids(T):
    docs = [{"rel": "Notion/2026-10-02 Interview Debrief [" + "ab12" * 8 + "].md", "preview": "x", "score": 0.6},
            {"rel": "b.md", "preview": "y", "score": 0.5}]
    facts = [{"id": "qa-start", "title": "QA replacement start", "text": "starts 11-03", "keywords": ["qa", "replacement", "start"]}]
    got = T.sos_pick(["the qa replacement start is tomorrow"], facts, [], sem={"facts": {}, "cards": {}, "docs": docs})
    assert [g["kind"] for g in got] == ["fact"]
    got = T.sos_pick(["nothing matches here"], facts, [], sem={"facts": {}, "cards": {}, "docs": docs})
    assert len(got) == 1 and "[ab12" not in got[0]["gist"]


def test_agenda_skip_state_from_the_window(tmp_path):
    eng, clock = _meeting_engine(tmp_path, lambda m, u: json.dumps({"skip": True, "reason": "x"}))
    eng.set_agenda_items(BRIEF)
    eng.set_agenda_state("a2|skip")
    eng._agenda_from_model({"agenda_done": [2], "agenda_now": 2})        # the model cannot undo the PM's skip
    strip = eng.agenda_strip()
    assert strip[2]["state"] == "skip" and not strip[2]["done"]
    assert agenda.status_label(strip[2], True) == "пропущено"
    assert "2. [skip]" in eng.wrap_event()
