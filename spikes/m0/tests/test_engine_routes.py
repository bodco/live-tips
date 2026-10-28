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
