import json
import time

from conftest import FIX
from livetips_m0.providers import FakeProvider, gist_closed
from livetips_m0.replay import replay

CFG = {"variant": "test", "models": {"classify": "fake-haiku", "tip": "fake-sonnet"}, "cache_ttl": "1h",
       "me_label": "Me", "them_label": "Other", "name_aliases": ["Alex"], "langs": ["en"], "tips_lang": "en",
       "active_rate_seconds": 45, "periodic_classify_s": 999,
       "budget": {"ledger": "", "call_soft_usd": 1, "call_hard_usd": 2, "monthly_hard_usd": 100}}


def responder(model, user):
    if "ROLE classify" in user:
        return json.dumps({"need_tip": True, "level": "orange", "trigger": "add_fact", "topic": "release date", "reason": "fact"})
    if "pm_commitment" in user:
        return 'not json at all'
    if "new_requirement" in user:
        return json.dumps({"gist": "🔴 New requirement", "level": "red", "phrase": "Good idea. I will write it down.", "topic": "csv download"})
    if "your_turn" in user or "direct_question" in user:
        return json.dumps({"gist": "🎯 Payment retries status", "level": "red", "phrase": "Retries ship in 2.4.", "topic": "payment retries", "fact_ids": ["F1"]})
    return json.dumps({"skip": True, "reason": "nothing"})


def run(tmp_path, cfg=CFG, prov=None):
    cfg = dict(cfg, budget=dict(cfg["budget"], ledger=str(tmp_path / "spend.json")))
    prov = prov or FakeProvider(responder, ttft=0.01, total=0.02)
    eng = replay(cfg, FIX / "demo-call.md", tmp_path / "out", speed=40, provider=prov, verbose=False)
    tf = tmp_path / "out" / "demo-call.app.timing.jsonl"
    timing = [json.loads(l) for l in tf.read_text().splitlines()] if tf.exists() else []
    tips = [json.loads(l) for l in (tmp_path / "out" / "demo-call.app.tips.jsonl").read_text().splitlines()] \
        if (tmp_path / "out" / "demo-call.app.tips.jsonl").exists() else []
    return eng, timing, tips, prov


def test_direct_route_emits_red_without_classify(tmp_path):
    eng, timing, tips, prov = run(tmp_path)
    red = [t for t in tips if t["level"] == "red"]
    assert {t["src"] for t in red} == {"10:00:12", "10:00:24"}
    span = next(s for s in timing if s["src"] == "10:00:12")
    assert span["route"] == "direct" and "classify_ms" not in span and span["outcome"] == "emitted"
    assert span["e2e_s"] > 0


def test_invalid_model_output_is_not_shown(tmp_path):
    eng, timing, tips, prov = run(tmp_path)
    span = next(s for s in timing if s["src"] == "10:00:31")
    assert span["outcome"] == "tip_invalid"
    assert all(t["src"] != "10:00:31" for t in tips)


def test_classified_question_goes_to_tip(tmp_path):
    eng, timing, tips, prov = run(tmp_path)
    spans = [s for s in timing if s["src"] == "10:00:47"]
    cls = next(s for s in spans if "classify" in s)
    assert cls["route"] in ("classify", "parallel") and cls["classify"]["need_tip"] is True
    tip = [s for s in spans if str(s.get("outcome", "")).startswith(("skip", "emitted", "diet_", "stale_", "classify_vetoed"))]
    assert tip, spans


def test_tip_items_match_window_schema(tmp_path):
    import jsonschema
    from livetips_m0.rules import Rules
    eng, timing, tips, prov = run(tmp_path)
    v = jsonschema.Draft202012Validator(Rules().tip_schema)
    for t in tips:
        assert not list(v.iter_errors(t)), t
    assert any(t.get("uid") for t in tips)


def test_budget_hard_stop(tmp_path):
    cfg = dict(CFG, budget=dict(CFG["budget"], call_hard_usd=0.0))
    eng, timing, tips, prov = run(tmp_path, cfg)
    assert prov.calls == [] and tips == []


def test_diet_rate_blocks_second_orange(tmp_path):
    def resp(model, user):
        if "ROLE classify" in user:
            return json.dumps({"need_tip": True, "level": "orange", "trigger": "add_fact", "topic": "x"})
        return json.dumps({"gist": "🟠 Add a fact " + str(time.monotonic()), "level": "orange", "topic": "topic " + str(time.monotonic())})
    cfg = dict(CFG, direct_route=False, periodic_classify_s=0)
    eng, timing, tips, prov = run(tmp_path, cfg, FakeProvider(resp, 0.0, 0.0))
    assert len([t for t in tips if t.get("level") == "orange" and not t.get("partial")]) == 1
    assert any(s.get("outcome") in ("diet_rate", "diet_pm_speaking") for s in timing)


def test_gist_closed_streaming():
    assert not gist_closed('{"gist": "🔴 New req')
    assert gist_closed('{"gist": "🔴 New \\"req\\"", "lev')


def test_speaker_names_from_speakers_json(tmp_path):
    from livetips_m0.engine import SpeakerNames
    from livetips_m0.transcript import parse_line
    p = tmp_path / "call.speakers.json"
    p.write_text(json.dumps({"clusters": {"S2": {"name": "Emily Carter"}, "S3": {}},
                             "merged": {"S4": "S2"}, "overrides": {"10:00:09": "S2"}}), encoding="utf-8")
    sp = SpeakerNames(p)
    named = parse_line("[10:00:05] Other [S4] (en): Can we ship on Friday?", 1, "Me")
    unnamed = parse_line("[10:00:07] Other [S3] (en): And the price?", 2, "Me")
    fixed = parse_line("[10:00:09] Other [S3] (en): Thanks.", 3, "Me")
    me = parse_line("[10:00:08] Me (en): Yes, on Friday.", 4, "Me")
    assert sp.who(named) == "Emily Carter"
    assert sp.who(unnamed) == "Other [S3]"
    assert sp.who(fixed) == "Emily Carter"
    assert sp.who(me) == "Me"
    assert SpeakerNames(None).who(unnamed) == "Other [S3]"


def test_hedged_provider_second_request_wins_when_first_is_slow():
    from livetips_m0.providers import Completion, HedgedProvider, Provider

    class Slow(Provider):
        def __init__(self):
            self.n = 0

        def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
            self.n += 1
            slow = self.n == 1
            c = Completion(model=model, t_start=time.monotonic())
            time.sleep(0.6 if slow else 0.05)
            c.t_first_token = c.t_done = time.monotonic()
            c.text = "slow" if slow else "fast"
            c.input_tokens, c.output_tokens = 10, 2
            return c

    extra = []
    hp = HedgedProvider(Slow(), {"m": 0.15}, on_extra=extra.append)
    c = hp.complete(model="m", system=[], user="u", max_tokens=10, cache_ttl=None)
    assert c.text == "fast" and c.hedge == "hedge"
    time.sleep(0.7)
    assert [x.text for x in extra] == ["slow"]
    assert hp.stats == {"calls": 1, "hedged": 1, "hedge_won": 1}
    # fast enough: one request, no hedge
    hp2 = HedgedProvider(Slow(), {"m": 2.0})
    c2 = hp2.complete(model="m", system=[], user="u", max_tokens=10, cache_ttl=None)
    assert c2.text == "slow" and c2.hedge is None and hp2.stats["hedged"] == 0


def test_hedged_provider_retries_a_fast_failure():
    from livetips_m0.providers import Completion, HedgedProvider, Provider

    class Flaky(Provider):
        def __init__(self):
            self.n = 0

        def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
            self.n += 1
            c = Completion(model=model, t_start=time.monotonic(), t_done=time.monotonic())
            if self.n == 1:
                c.error = "OverloadedError: 529"
            else:
                c.text, c.t_first_token = "ok", time.monotonic()
            return c

    c = HedgedProvider(Flaky(), {"m": 1.0}).complete(model="m", system=[], user="u", max_tokens=10, cache_ttl=None)
    assert c.text == "ok" and c.error is None and c.hedge == "hedge"


def test_streamed_gist_then_full_tip_with_same_uid(tmp_path):
    eng, timing, tips, prov = run(tmp_path)
    parts = [t for t in tips if t.get("partial")]
    assert parts, "the gist is shown before the full tip"
    for p in parts:
        full = [t for t in tips if t.get("uid") == p["uid"] and not t.get("partial")]
        retracted = [t for t in tips if t.get("kind") == "retract" and t.get("uid") == p["uid"]]
        assert full or retracted
        if full:
            assert full[0]["gist"] == p["gist"]
    span = next(s for s in timing if s["src"] == "10:00:12")
    assert span.get("e2e_shown_s") is not None and span["e2e_shown_s"] <= span["e2e_s"]


def test_partial_head_needs_gist_level_and_topic():
    from livetips_m0.engine import partial_head
    assert partial_head('{"gist": "🟠 Додай: ціна", "level": "orange"') is None
    assert partial_head('{"gist": "🟠 Додай: ціна", "level": "orange", "topic": "ціна"')["topic"] == "ціна"
    assert partial_head('{"gist": "🔴 Тебе питають", "level": "red"')["level"] == "red"
    assert partial_head('{"skip": true, "reason": "x"}') is None


def test_interview_switches_off_project_triggers():
    from livetips_m0.prompt import disabled_triggers, render_rules
    from livetips_m0.rules import Rules
    off = disabled_triggers({"call_type": "interview", "hiring_role": "observer"})
    assert {"new_requirement", "pm_commitment", "your_turn"} <= off
    assert "pm_factual_error" in disabled_triggers({"audience": "team"})
    assert disabled_triggers({"audience": "client"}) == set()
    txt = render_rules(Rules(), meta={"call_type": "interview", "hiring_role": "coach"})
    assert "new_requirement" not in txt and "your_turn" in txt


def test_stale_question_after_pm_answered(tmp_path):
    from livetips_m0.replay import build_engine
    from livetips_m0.transcript import parse_line
    cfg = dict(CFG, budget=dict(CFG["budget"], ledger=str(tmp_path / "s.json")))
    eng, _ = build_engine(cfg, FIX / "demo-call.md", tmp_path / "o", lambda: 0.0, FakeProvider(responder))
    q = parse_line("[10:00:00] Other (en): Alex, when is the release?", 1, "Me")
    eng.history.append(q)
    assert eng.stale(q, "direct_question") is None
    eng.history.append(parse_line("[10:00:04] Me (en): The release is on Friday, after the QA round.", 2, "Me"))
    eng.history.append(parse_line("[10:00:09] Me (en): We also fixed the login issue yesterday.", 3, "Me"))
    assert eng.stale(q, "direct_question") == "pm_answered"
    assert eng.stale(q, "add_fact", {"topic": "release", "phrase": "Friday", "items": ["QA round 2 days"]}) is None
    eng.history.append(parse_line("[10:00:12] Other (en): So Friday, with 2 days of QA.", 4, "Me"))
    assert eng.stale(q, "add_fact", {"topic": "release", "phrase": "2 days", "items": []}) == "numbers_already_said"


def test_invented_numbers_are_dropped(tmp_path):
    from livetips_m0.replay import build_engine
    from livetips_m0.transcript import parse_line
    cfg = dict(CFG, budget=dict(CFG["budget"], ledger=str(tmp_path / "s.json")))
    eng, _ = build_engine(cfg, FIX / "demo-call.md", tmp_path / "o", lambda: 0.0, FakeProvider(responder))
    ln = parse_line("[10:00:00] Other (en): We shipped 14 fixes this week.", 1, "Me")
    eng.history.append(ln)
    obj = eng.validate_facts({"gist": "x", "items": ["14 fixes shipped", "Budget left 4200 USD"], "phrase": "We shipped 14 fixes."}, ln)
    assert obj["items"] == ["14 fixes shipped"] and obj["_dropped_items"] == 1 and "_unseen_number_in_phrase" not in obj
    obj = eng.validate_facts({"gist": "x", "items": [], "phrase": "The estimate is 37 hours."}, ln)
    assert obj.get("_unseen_number_in_phrase") is True


# ---------- meeting concept in code (2026-10-23) ----------
def _meeting_engine(tmp_path, resp, **extra):
    from livetips_m0.replay import build_engine
    cfg = dict(CFG, budget=dict(CFG["budget"], ledger=str(tmp_path / "s.json")), **extra)
    clock = {"t": 36000.0}
    eng, _ = build_engine(cfg, FIX / "demo-call.md", tmp_path / "o", lambda: clock["t"], FakeProvider(resp, 0.0, 0.0))
    return eng, clock


def _feed(eng, clock, raw, n, at):
    from livetips_m0.transcript import parse_line
    clock["t"] = at
    eng.on_line(parse_line(raw, n, "Me"))
    end = time.monotonic() + 5
    while time.monotonic() < end and any(not f.done() for f in eng.futures):
        time.sleep(0.01)


def _out(tmp_path):
    def rd(name):
        p = tmp_path / "o" / ("demo-call.app." + name + ".jsonl")
        return [json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
    return rd("tips"), rd("timing")


def _no_tip_classify(model, user):
    return json.dumps({"need_tip": False, "level": "none", "trigger": "none", "topic": "x"})


def test_observer_question_tip_is_orange_rate_exempt_and_nothing_after(tmp_path):
    n = {"i": 0}

    def resp(model, user):
        if "ROLE classify" in user:
            return _no_tip_classify(model, user)
        n["i"] += 1
        if "role observer: the other side asked" in user:
            return json.dumps({"gist": "🟠 Question {}".format(n["i"]), "level": "red", "topic": "question {}".format(n["i"]),
                               "phrase": "A strong answer names the tool, the role and the result."})
        return json.dumps({"gist": "🟠 Add fact", "level": "orange", "topic": "fact"})
    eng, clock = _meeting_engine(tmp_path, resp)
    assert eng.set_meeting({"call_type": "interview", "hiring_role": "observer"})     # window menu change
    _feed(eng, clock, "[10:00:00] Other [S1] (en): How do you design API tests?", 1, 36001)
    _feed(eng, clock, "[10:00:05] Other [S1] (en): And what about flaky tests?", 2, 36006)
    _feed(eng, clock, "[10:00:10] Other [S1] (en): How do you report bugs?", 3, 36011)
    _feed(eng, clock, "[10:00:15] Other [S2] (en): I usually start with the contract and then add negative cases, by Friday.", 4, 36016)
    _feed(eng, clock, "[10:00:20] Other [S1] (en): Alex, do you have questions?", 5, 36021)
    tips, timing = _out(tmp_path)
    full = [t for t in tips if not t.get("partial") and t.get("kind") == "tip"]
    assert [t["level"] for t in full] == ["orange", "orange"]               # forced orange, 2 per minute
    assert any(s.get("outcome") == "diet_meeting_rate" and s["src"] == "10:00:10" for s in timing)
    assert not any(s["src"] in ("10:00:15", "10:00:20") and s.get("route") for s in timing)   # nothing after the answer
    assert all("role observer: the other side asked" in c["user"] for c in eng.provider.inner.calls if "ROLE tip" in c["user"])


def test_observer_blocks_model_tips_without_meeting_route(tmp_path):
    eng, clock = _meeting_engine(tmp_path, responder, call_type="interview", hiring_role="observer")
    assert eng.meeting_block({"gist": "🟠 Add fact", "level": "orange", "topic": "x"}, "add_fact", {}) == "role_observer"
    assert eng.meeting_block({"gist": "🟠 Q", "level": "orange", "topic": "x"}, "direct_question", {"meeting": "observer_question"}) is None


def test_interviewer_one_clarify_per_long_answer_without_rate(tmp_path):
    def resp(model, user):
        if "ROLE classify" in user:
            return _no_tip_classify(model, user)
        if "role interviewer: the candidate just gave" in user:
            return json.dumps({"gist": "🟠 Уточни: own role " + str(len(user)), "level": "orange", "topic": "clarify " + str(len(user)),
                               "phrase": "What exactly was your part?"})
        return json.dumps({"skip": True, "reason": "x"})
    eng, clock = _meeting_engine(tmp_path, resp, call_type="interview", hiring_role="interviewer")
    long_a = " ".join(["we built the service together with the team and it worked well"] * 2)    # 24 words
    _feed(eng, clock, "[10:00:00] Me (en): Can you describe your last project?", 1, 36001)
    _feed(eng, clock, "[10:00:05] Other (en): " + long_a, 2, 36006)
    _feed(eng, clock, "[10:00:15] Other (en): " + long_a, 3, 36016)          # 48 words: clarify
    _feed(eng, clock, "[10:00:25] Other (en): " + long_a, 4, 36026)          # same answer: no second one
    _feed(eng, clock, "[10:00:30] Me (en): How did you test it?", 5, 36031)
    _feed(eng, clock, "[10:00:35] Other (en): " + long_a + " " + long_a, 6, 36036)   # 10 s later, no rate limit
    tips, timing = _out(tmp_path)
    full = [t for t in tips if not t.get("partial") and t.get("kind") == "tip"]
    assert [t["src"] for t in full] == ["10:00:15", "10:00:35"]
    assert all(t["gist"].startswith("🟠 Уточни") for t in full)


def test_coach_question_red_and_money_without_numbers(tmp_path):
    def resp(model, user):
        if "ROLE classify" in user:
            return _no_tip_classify(model, user)
        if "money, dates or scope" in user:
            return json.dumps({"gist": "🔴 Без цифр зараз", "level": "orange", "topic": "salary",
                               "phrase": "I would like to understand the scope first."})
        if "role coach: the PM is being asked" in user:
            return json.dumps({"gist": "🔴 Hard project story", "level": "orange", "topic": "hard project"})
        return json.dumps({"skip": True, "reason": "x"})
    eng, clock = _meeting_engine(tmp_path, resp, call_type="interview", hiring_role="coach")
    _feed(eng, clock, "[10:00:00] Other (en): What salary do you expect", 1, 36001)
    _feed(eng, clock, "[10:00:05] Other (en): Tell me about a hard project?", 2, 36006)
    _feed(eng, clock, "[10:00:10] Other (uk): Яка ваша дата старту і ставка?", 3, 36011)
    tips, timing = _out(tmp_path)
    full = [t for t in tips if not t.get("partial") and t.get("kind") == "tip"]
    assert {t["src"]: t["level"] for t in full} == {"10:00:00": "red", "10:00:05": "red"}   # 3rd: red_repeat of the money gist
    assert next(s for s in timing if s["src"] == "10:00:10")["meeting"] == "coach_money"
    from livetips_m0.transcript import parse_line
    ln = parse_line("[10:00:20] Other (uk): Ми цінуємо командну роботу.", 9, "Me")
    assert eng.meeting_hint(ln, eng.detector.detect(ln), 36021) is None


def test_team_audience_drops_info_and_caps_tips_per_hour(tmp_path):
    eng, clock = _meeting_engine(tmp_path, responder, audience="team")
    assert eng._diet({"gist": "🟢 x", "level": "info", "topic": "x"}, 40000) == "team_info"
    for i in range(12):
        eng.tips.append({"uid": "u%d" % i, "level": "orange", "topic": "t%d" % i, "_at": 38000 + i})
    assert eng._diet({"gist": "🟠 y", "level": "orange", "topic": "new topic"}, 40000) == "team_hour_cap"
    assert eng._diet({"gist": "🔴 z", "level": "red", "topic": "red one"}, 40000) is None
    assert eng._diet({"gist": "🟠 y", "level": "orange", "topic": "new topic"}, 38000 + 3700) is None   # an hour later
    eng.set_meeting({"audience": "client"})
    assert eng._diet({"gist": "🟢 x", "level": "info", "topic": "info topic"}, 40000) is None


def test_client_header_restricted_numbers_line_and_meeting_switch(tmp_path):
    eng, clock = _meeting_engine(tmp_path, responder)
    head = lambda: eng.prompt.blocks[1]["text"].split("BRIEF:")[0]
    assert "never stated" not in head() and "role observer" not in head()            # default unchanged
    eng.set_meeting({"audience": "client"})
    assert "restricted internal facts may shape a tip, but numbers from them are never stated" in head()
    eng.set_meeting({"call_type": "interview", "hiring_role": "observer"})
    assert "role observer" in head()
    eng.set_meeting({"call_type": "auto"})                  # hiring_role stays in meta; the note must go
    assert "role observer" not in head()
    from livetips_m0.transcript import parse_line
    ln = parse_line("[10:00:00] Other (en): How do you design API tests?", 1, "Me")
    assert eng.meeting_hint(ln, eng.detector.detect(ln), 36001) is None


def test_presentation_blocks_pacing_and_routes_qa_question(tmp_path):
    from livetips_m0.transcript import parse_line
    eng, clock = _meeting_engine(tmp_path, responder, call_type="presentation")
    pacing = {"gist": "🟠 5 minutes left, skip slides", "level": "orange", "topic": "time"}
    assert eng.meeting_block(pacing, "add_fact", {}) == "presentation_timing"
    assert eng.meeting_block({"gist": "🟠 Price 120", "level": "orange", "topic": "price"}, "add_fact", {}) is None
    for i in range(10):                                      # the PM presents for 100 s
        eng.history.append(parse_line("[10:0{}:{}0] Me (en): {}".format(i // 6, i % 6, "slide text " * 20), i + 1, "Me"))
    q = parse_line("[10:01:45] Other (en): How does the pricing work?", 20, "Me")
    assert eng.meeting_hint(q, eng.detector.detect(q), 36105) is None                # still presenting
    for i, t in enumerate(["10:02:00", "10:02:15", "10:02:30", "10:02:45"]):
        eng.history.append(parse_line("[{}] Other (en): {}".format(t, "a long audience remark " * 8), 30 + i, "Me"))
    q2 = parse_line("[10:02:50] Other (en): How does the pricing work?", 40, "Me")
    eng.history.append(q2)
    mh = eng.meeting_hint(q2, eng.detector.detect(q2), 36170)
    assert mh and mh["kind"] == "presentation_qa" and mh["trigger"] == "direct_question"
    eng.set_meeting({"call_type": "auto"})
    assert eng.meeting_block(pacing, "add_fact", {}) is None
    assert eng.meeting_hint(q2, eng.detector.detect(q2), 36170) is None
