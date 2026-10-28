import json
from types import SimpleNamespace as S

from livetips_m0.engine import asks_the_pm, route_when_off


def sig(**kw):
    base = dict(name_vocative=False, question=False, second_person=False, third_person=False, name_mention=False, trigger_hint="")
    return S(**dict(base, **kw))


def test_asks_the_pm():
    assert asks_the_pm(sig(name_vocative=True))
    assert asks_the_pm(sig(question=True, second_person=True))
    assert not asks_the_pm(sig(question=True))
    assert not asks_the_pm(sig(second_person=True))
    assert not asks_the_pm(sig(name_vocative=True, third_person=True))


def test_route_when_off():
    assert route_when_off(sig(question=True, trigger_hint="question")) == "classify"
    assert route_when_off(sig(name_mention=True)) == "classify"
    assert route_when_off(sig(question=True, trigger_hint="pm_commitment")) is None
    assert route_when_off(sig(question=True, trigger_hint="new_requirement")) is None
    assert route_when_off(sig()) is None


def test_similar_topic_and_same_tip():
    from livetips_m0.engine import same_tip, similar_topic
    assert similar_topic("release date", ["the release date"], 0.6)
    assert not similar_topic("", ["x"], 0.0) and not similar_topic("a", [], 0.0)
    assert same_tip({"gist": "g"}, {"gist": "g"}, 0.9)
    assert not same_tip({"gist": "g", "topic": ""}, {"gist": "h", "topic": ""}, 0.0)


def test_speech_from_brief():
    from livetips_m0.engine import speech_from_brief
    assert speech_from_brief('## speech.json\n{"gist": "G", "items": ["a"]}\n', "D") == {"gist": "G", "items": ["a"]}
    brief = "# Brief\n## 2. Your speech\n**Status**\n\"We ship Friday.\"\n- tests green\n- one risk\n## Next\nx\n"
    assert speech_from_brief(brief, "D") == {"gist": "Status", "phrase": "We ship Friday.", "items": ["tests green", "one risk"]}
    assert speech_from_brief("## Your speech\n- only\n", "D") == {"gist": "D", "phrase": "", "items": ["only"]}
    assert speech_from_brief("## speech.json\n{bad}\n", "D") is None
    assert speech_from_brief("nothing", "D") is None


def test_speech_cards():
    from livetips_m0.engine import speech_cards
    text = '{"kind": "speech", "phrase": "p"}\n{"kind": "tip", "gist": "speech"}\nnot json "speech"\n{"kind":"tip"}'
    assert speech_cards(text) == [{"kind": "speech", "phrase": "p"}]


def test_request_item_and_no_answer():
    from livetips_m0.engine import no_ready_answer, request_item
    sos = request_item(no_ready_answer("sos", False), "sos", "", "00:00:01", 2.0)
    assert sos["kind"] == "tip" and sos["level"] == "red" and sos["gist"].endswith("searching the project folder")
    ask = request_item({"gist": "A", "level": "orange"}, "ask", "why?", "00:00:01", 2.0)
    assert ask["kind"] == "answer" and ask["q"] == "why?" and ask["level"] == "orange" and "phrase" not in ask
    assert no_ready_answer("ask", True)["topic"] == "ask" and not no_ready_answer("ask", True)["gist"].startswith("\U0001f198")


def _l(i, who, text):
    from livetips_m0.transcript import Line
    return Line(line_id=i, t="00:00:%02d" % i, speaker=who, label="", stag=None, lang="en", text=text)


def test_stale_rules():
    from livetips_m0.engine import numbers_said, owner_or_date_said, turn_resolved
    assert turn_resolved("your_turn", [_l(1, "me", "a"), _l(2, "me", "b")]) == "pm_answered"
    assert turn_resolved("direct_question", [_l(1, "me", "x" * 81)]) == "pm_answered"
    assert turn_resolved("direct_question", [_l(i, "them", "x") for i in range(3)]) == "talk_moved_on"
    assert turn_resolved("direct_question", [_l(1, "them", "x"), _l(2, "them", "y"), _l(3, "me", "ok")]) is None
    assert turn_resolved("add_fact", [_l(1, "me", "a"), _l(2, "me", "b")]) is None
    assert owner_or_date_said("fix_owner_date", [_l(1, "them", "I'll do it by Friday")]) == "owner_or_date_said"
    assert owner_or_date_said("fix_owner_date", [_l(1, "them", "maybe later")]) is None
    assert owner_or_date_said("your_turn", [_l(1, "them", "I'll do it")]) is None
    assert numbers_said({"topic": "t", "phrase": "42 users", "items": ["7 days"]}, [_l(1, "them", "42 users in 7 days")]) == "numbers_already_said"
    assert numbers_said({"topic": "t", "phrase": "42 users"}, [_l(1, "them", "users")]) is None
    assert numbers_said({"topic": "t", "phrase": "no numbers"}, [_l(1, "them", "x")]) is None
    assert numbers_said({"phrase": "42"}, [_l(1, "them", "42")]) is None and numbers_said(None, []) is None


def test_meeting_helpers():
    from livetips_m0.engine import last_question_and_answer, mentions_money
    q, ans = last_question_and_answer([_l(1, "me", "q?"), _l(2, "them", "a"), _l(3, "them", "b")])
    assert q.line_id == 1 and [h.line_id for h in ans] == [3, 2]
    assert last_question_and_answer([_l(1, "them", "a")])[0] is None
    assert not mentions_money("let us talk about the weather")


def test_reload_prep(tmp_path):
    from test_engine import _meeting_engine
    from types import SimpleNamespace
    eng, _ = _meeting_engine(tmp_path, lambda m, u: "{}", speech_card=True)
    eng.reload_prep()                                  # the demo prompt: whatever it returns, it must not fail
    calls = []

    class Prompt(SimpleNamespace):
        def refresh_brief(self):
            calls.append("brief")
            if self.boom:
                raise RuntimeError("x")
            return self.changed

        def refresh_facts(self):
            calls.append("facts")
            return False

    real = eng.prompt
    eng.prompt = Prompt(_brief="", boom=True, changed=True, meta=real.meta)
    assert eng.reload_prep() is False
    eng.prompt = Prompt(_brief="old", boom=False, changed=False, meta=real.meta)
    assert eng.reload_prep() is False
    eng.speech_item = None
    eng.prompt = Prompt(_brief="## Your speech\n- point one\n", boom=False, changed=True, meta=real.meta)
    assert eng.reload_prep() is True and "facts" in calls
    tips = [json.loads(l) for l in eng.out_tips.path.read_text().splitlines()]
    assert any(t.get("kind") == "notice" and t["gist"].startswith("Preparation updated") for t in tips)
    assert any(t.get("kind") == "speech" and t["items"] == ["point one"] for t in tips)
    eng.prompt = object()
    assert eng.reload_prep() is False
