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


def test_hedge_delays_and_tip_tokens():
    from livetips_m0.engine import hedge_delays, raise_tip_tokens
    assert hedge_delays({"classify": "m", "tip": "m", "x": "y", "deep": ""}, None) == {"m": 2.0}
    assert hedge_delays({"classify": "a", "tip": "b"}, {"tip": 1.0}) == {"a": 2.0, "b": 1.0}
    cfg = {"max_tokens": {"tip": 300}}
    raise_tip_tokens(cfg)
    assert cfg["max_tokens"]["tip"] == 700
    cfg = {}
    raise_tip_tokens(cfg)
    assert cfg == {"max_tokens": {}}


def test_wrapup_lines():
    from livetips_m0.engine import missed_speech, picture_items
    sit = {"decisions": ["go"], "actions": [{"what": "send", "due": "Fri"}], "theirs": [{"who": "Ann", "what": "deck"}],
           "risks": [{"what": "late"}], "asks": [{"what": "q", "who": "Bo"}, {"what": "u", "type": "update"}]}
    assert picture_items(sit, False) == ["Decision: go", "On me: send (Fri)", "On them: Ann: deck", "Risk: late", "Unanswered: q · Bo"]
    assert picture_items({}, True) == []
    assert missed_speech(["a", "b", "c"], [0], False) == ["Not said from the speech: b", "Not said from the speech: c"]
    assert missed_speech(["a", "b"], [], False) == [] and missed_speech(["a"], [0], True) == [] and missed_speech([], None, True) == []


def test_find_parts():
    from livetips_m0.engine import find_event, find_item, passages, unique_sources
    snips = [{"src": "a.md", "date": "2026-10-01", "text": "A"}, {"src": "a.md", "date": "", "text": "B"}, {"src": "b.md", "date": "", "text": "C"}]
    assert passages(snips[:2]) == "[a.md, 2026-10-01]\nA\n\n[a.md]\nB"
    assert unique_sources(snips) == ["a.md", "b.md"]
    assert find_event("pilot", snips).endswith("PASSAGES FROM THE PROJECT FOLDER:\n" + passages(snips))
    assert "found nothing" in find_event("pilot", [])
    it = find_item({"gist": "🔎 42 users"}, ["a.md"], "pilot", "00:00:01", 3.0)
    assert it["gist"] == "🔎 42 users" and it["note"] == "Sources: a.md" and it["q"] == "find: pilot" and it["sources"] == ["a.md"]
    assert find_item({"gist": "x", "note": "mine"}, ["a.md"], "q", "s", 1.0)["note"] == "mine"
    assert "note" not in find_item({"gist": "x"}, [], "q", "s", 1.0)


def test_ask_span():
    from livetips_m0.engine import ask_span
    s = ask_span(_l(4, "them", "x"), {"type": "request", "who": "Ann", "what": "the deck"}, 9.0)
    assert s["route"] == "situation" and s["force_level"] == "red" and s["available_at"] == 9.0
    assert s["event"].startswith("Open request to the PM from Ann: the deck.")
    assert ask_span(_l(4, "them", "x"), {}, 1.0)["event"].startswith("Open question to the PM from someone: .")


def test_hits_and_snippets():
    from livetips_m0.engine import fit_snippets, merge_hits
    hits = merge_hits([[{"path": "/p/a", "preview": "x", "score": 1}], [{"path": "/p/a", "preview": "x", "score": 9},
                                                                       {"path": "/p/b", "preview": "y", "score": 5}]])
    assert [h["path"] for h in hits] == ["/p/b", "/p/a"]
    out = fit_snippets([{"path": "/p/a", "date": "d"}, {"path": "/p/b"}, {"rel": "r/c"}], 5, lambda h: {"/p/a": "abc", "/p/b": "toolong"}.get(h.get("path"), "z"))
    assert out == [{"src": "a", "date": "d", "text": "abc"}, {"src": "r/c", "date": "", "text": "z"}]
    many = fit_snippets([{"path": "/p/%d" % i} for i in range(20)], 10 ** 6, lambda h: "t")
    assert len(many) == 10 and fit_snippets([{"path": "/p"}], 10, lambda h: "") == []


def test_pacing_tip():
    from livetips_m0.engine import pacing_tip
    assert pacing_tip({"gist": "5 minutes left"}, "x")
    assert pacing_tip({"gist": "g"}, "timer_checkpoint") and pacing_tip({"gist": "g", "trigger": "timer_checkpoint"}, "x")
    assert not pacing_tip({"gist": "5 minutes left", "level": "red"}, "x") and not pacing_tip({"gist": "hello"}, "x")


def test_deep_item():
    from livetips_m0.engine import deep_item
    assert deep_item({"error": "timeout"}, False) == {"gist": "🔎 The folder search failed: timeout", "level": "info"}
    it = deep_item({"gist": "🔎 42", "items": [1, 2, 3, 4, 5], "sources": ["a.md", "b.md"]}, False)
    assert it["gist"] == "🔎 42" and it["items"] == ["1", "2", "3", "4"] and it["note"] == "Sources: a.md, b.md"
    assert deep_item({"gist": "x"}, True)["note"] == "" and deep_item({"gist": "x", "sources": ["s"]}, True)["note"].endswith("s")


def test_numbers_check():
    from livetips_m0.engine import check_numbers, numbers_seen
    assert numbers_seen("42 users, 7 days", "we have 42 users") and not numbers_seen("43 users", "42 users")
    assert numbers_seen("", "") and numbers_seen("1.5.", "1.5")
    obj = check_numbers({"items": ["42 users", "99 bugs"], "phrase": "77 days"}, "42 users")
    assert obj["items"] == ["42 users"] and obj["_dropped_items"] == 1 and obj["_unseen_number_in_phrase"]
    assert check_numbers({"items": [], "phrase": "ok"}, "") == {"items": [], "phrase": "ok"}


def test_situation_due():
    from livetips_m0.engine import situation_due
    assert situation_due(None, 10, False) and situation_due(10, 10, False) and situation_due(3, 10, True)
    assert not situation_due(9.9, 10, False) and not situation_due(2.9, 10, True)


def test_commitment_and_speech_cards():
    from livetips_m0.engine import commitment_card, speech_out
    c = commitment_card({"id": "c1", "text": "send deck", "owner": "Ann"}, "00:01:00", False)
    assert c["gist"] == "On them · Done? send deck" and c["owner"] == "Ann"
    assert commitment_card({"id": "c2", "text": "x"}, "t", True)["gist"].startswith("На мені")
    s = speech_out({"items": list(range(20))}, 5.0, "D", "")
    assert s["gist"] == "D" and len(s["items"]) == 14 and "note" not in s and s["uid"] == "speech"


def test_add_queries():
    from livetips_m0.engine import add_queries
    qs = ["Pilot"]
    add_queries(qs, {"queries": ["pilot", " start date ", "", 3, "Start date"]})
    assert qs == ["Pilot", "start date"]
    add_queries(qs, None)
    assert qs == ["Pilot", "start date"]


def test_pm_share_and_leads():
    from livetips_m0.engine import pm_leads, pm_share
    assert pm_share([_l(1, "me", "aaa"), _l(2, "them", "a")]) == 0.75 and pm_share([]) == 0
    assert pm_leads(0.66, False, False) and not pm_leads(0.65, False, False)
    assert pm_leads(0.56, False, True) and pm_leads(0.55, True, False) and not pm_leads(0.54, True, True)
