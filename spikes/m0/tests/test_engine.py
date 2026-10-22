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
    span = next(s for s in timing if s["src"] == "10:00:47")
    assert span["route"] == "classify" and span["classify"]["need_tip"] is True
    assert span["outcome"] in ("skip", "emitted", "diet_rate", "diet_pm_speaking", "diet_same_topic")


def test_tip_items_match_window_schema(tmp_path):
    import jsonschema
    from livetips_m0.rules import Rules
    eng, timing, tips, prov = run(tmp_path)
    v = jsonschema.Draft202012Validator(Rules().tip_schema)
    for t in tips:
        assert not list(v.iter_errors(t)), t


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
    assert len([t for t in tips if t["level"] == "orange"]) == 1
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
