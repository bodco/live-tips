"""0.9.2: lessons of the 04.11 call audit (item 1): an honest route in run.json, OpenAI answers cut by the output
limit, garbled tips. No network or real credentials."""
import io
import json

import pytest

from livetips_m0.engine import first_json, garbled
from livetips_m0.openai_provider import OpenAIProvider, json_prefix
from livetips_m0.providers import FakeProvider, HedgedProvider
from livetips_m0.replay import finish_run_info, observed_models, planned_models, run_info
from livetips_m0.routing import RouteState, RoutedProvider, provider_from_cfg


def stream(*events):
    return io.BytesIO(b"".join(b"data: " + json.dumps(e).encode() + b"\n\n" for e in events))


def delta(t):
    return {"type": "response.output_text.delta", "delta": t}


def end(kind="response.completed", reason=None, out=20, reasoning=0):
    r = {"usage": {"input_tokens": 100, "output_tokens": out, "input_tokens_details": {"cached_tokens": 40},
                   "output_tokens_details": {"reasoning_tokens": reasoning}}}
    if reason:
        r["incomplete_details"] = {"reason": reason}
    return {"type": kind, "response": r}


def ask(p, max_tokens=60, cb=None):
    return p.complete(model="claude-haiku-5-5", system=[{"text": "rules"}], user="q", max_tokens=max_tokens,
                      cache_ttl=None, on_text=cb)


def serve(monkeypatch, *answers):
    sent = []

    def send(req, timeout=None):
        sent.append(json.loads(req.data)["max_output_tokens"])
        return stream(*answers[len(sent) - 1])
    monkeypatch.setattr("urllib.request.urlopen", send)
    return sent


def test_json_prefix():
    assert json_prefix('{"a": 1}{"a": 2}') == ('{"a": 1}', 8)
    assert json_prefix('  {"a": "}"} \n ેણ') == ('{"a": "}"}', 2)
    assert json_prefix('{"a": 1') == (None, 0) and json_prefix("text {}") == (None, 0)


def test_whole_json_cut_by_the_limit_is_the_answer(monkeypatch):
    """Luna closed the JSON and ran on to the limit: the answer was thrown away (14 of 98 classify)."""
    sent = serve(monkeypatch, [delta('{"need_tip":true,"level":"red","topic":"Price"}'), delta('{"need_tip":tr'),
                               end("response.incomplete", "max_output_tokens", out=60)])
    c = ask(OpenAIProvider("test-key"))
    assert c.error is None and c.text == '{"need_tip":true,"level":"red","topic":"Price"}'
    assert c.stop_reason == "json_prefix" and c.tail > 0 and c.incomplete == "max_output_tokens" and sent == [60]
    assert c.output_tokens == 60 and c.retried is None


def test_cut_without_a_whole_json_is_asked_once_more_with_a_larger_limit(monkeypatch):
    sent = serve(monkeypatch, [delta('{"gist":"Half'), end("response.incomplete", "max_output_tokens", out=700, reasoning=650)],
                 [delta('{"gist":"Whole"}'), end(out=30)])
    seen = []
    c = ask(OpenAIProvider("test-key"), max_tokens=700, cb=seen.append)
    assert c.error is None and c.text == '{"gist":"Whole"}' and c.retried == "longer"
    assert sent == [700, 2100]
    assert (c.output_tokens, c.input_tokens, c.cache_read, c.reasoning_tokens) == (730, 120, 80, 650)   # both billed
    assert seen[-1] == '{"gist":"Whole"}'


def test_a_second_cut_is_an_error_and_there_is_no_third_request(monkeypatch):
    cut = [delta('{"gist":"Ha'), end("response.incomplete", "max_output_tokens")]
    sent = serve(monkeypatch, cut, cut, cut)
    c = ask(OpenAIProvider("test-key"), max_tokens=1000)
    assert c.error and sent == [1000, 2400]


@pytest.mark.parametrize("reason", [None, "content_filter"])
def test_other_incomplete_reasons_stay_errors(monkeypatch, reason):
    sent = serve(monkeypatch, [delta('{"gist":"Fine"}'), end("response.incomplete", reason)])
    assert ask(OpenAIProvider("test-key")).error and sent == [60]


def test_completed_answer_notes_the_tail(monkeypatch):
    serve(monkeypatch, [delta('{"skip":true,"reason":"x"} \n_REALTYPE\n'), end()])
    c = ask(OpenAIProvider("test-key"))
    assert c.error is None and c.tail > 0 and first_json(c.text) == {"skip": True, "reason": "x"}


def test_classify_takes_the_first_json_of_two():
    """13:13:39: two JSON objects in one classify answer; the first is the verdict."""
    assert first_json('{"need_tip":true,"topic":"A"}{"need_tip":false,"topic":"B"}') == {"need_tip": True, "topic": "A"}


def test_garbled_tip_text():
    assert garbled({"gist": "🟠 Ask for the date ેણ", "phrase": "x"}) == "foreign script"
    assert garbled({"gist": "Ask for _REALTYPE now"}) == "token"
    assert garbled({"gist": "🔴 Дата без оцінки", "phrase": "Let's confirm by Friday, ok?", "items": ["Mike: 16 h"]}) is None
    assert garbled({"gist": "Dé un plazo", "note": "file_name.md, API_KEY_ENV"}) is None
    assert garbled({"gist": "Обʼєм і пам\u02bcять, наголо\u0301с"}) is None     # Ukrainian apostrophe, stress mark


def test_run_json_names_the_route_and_model_that_really_run(tmp_path):
    """run.json said claude-haiku-5-5 while all 305 requests went to gpt-6-luna."""
    rp = provider_from_cfg({"ai": {"routes": {"tips": "openai"}, "openai_models": {"tips": "gpt-6-luna"},
                                   "state": str(tmp_path / "s.json")}}, lambda k: "")
    rp.legs["openai"] = OpenAIProvider("test-key", model="gpt-6-luna")
    models = {"tip": "claude-haiku-5-5", "classify": "claude-haiku-5-5"}
    hp = HedgedProvider(rp, {})
    assert planned_models(hp, models) == {r: {"route": "openai", "model": "gpt-6-luna", "available": True} for r in models}
    info = run_info(hp, {"models": models}, md="call.md")
    assert info["models"] == {"tip": "gpt-6-luna", "classify": "gpt-6-luna"} and info["routes"]["tip"] == "openai"
    assert info["config_models"] == models
    api = RoutedProvider("tips", "api", {"api": FakeProvider(lambda *a: "{}")}, state=RouteState(str(tmp_path / "a.json")))
    assert planned_models(api, models)["tip"] == {"route": "api", "model": "claude-haiku-5-5", "available": True}
    code = RoutedProvider("tips", "code", {"code": None}, state=RouteState(str(tmp_path / "c.json")))
    assert planned_models(code, {"tip": "claude-haiku-5-5"})["tip"]["route"] == "code"
    (tmp_path / "call.app.run.json").write_text(json.dumps(info))
    rows = [{"role": "tip", "route": "openai", "model": "gpt-6-luna"}, {"role": "classify", "route": "openai", "model": "gpt-6-luna"},
            {"role": "situation", "route": "openai", "model": "gpt-6-luna"}, {"role": "hedge_extra", "model": "x"}]
    (tmp_path / "call.app.llm.jsonl").write_text("\n".join(json.dumps(r) for r in rows))
    assert observed_models(tmp_path / "call.app.llm.jsonl")["tip"] == {"openai gpt-6-luna": 1}
    done = finish_run_info(tmp_path, "call")
    assert done["models_match"] is True and "hedge_extra" not in done["observed"]
    rows.append({"role": "tip", "route": "api", "model": "claude-haiku-5-5"})
    (tmp_path / "call.app.llm.jsonl").write_text("\n".join(json.dumps(r) for r in rows))
    assert finish_run_info(tmp_path, "call")["models_match"] is False


def test_the_api_route_never_goes_to_openai(monkeypatch, tmp_path):
    """Why the 04.11 tips went to OpenAI: the route chosen for tips was openai then; with "api" the engine never picks
    OpenAI by itself, also when the key is out (auto-switch goes to Claude Code only)."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    rp = provider_from_cfg({"ai": {"routes": {"tips": "api"}, "auto": True, "state": str(tmp_path / "s.json")}}, lambda k: "")
    assert isinstance(rp.legs["openai"], OpenAIProvider)            # the leg exists, but nothing picks it
    calls = []
    rp.legs["openai"] = FakeProvider(lambda *a: pytest.fail("OpenAI must not be asked"))
    rp.legs["api"] = FakeProvider(lambda *a: calls.append("api") or "{}")
    rp.legs["code"] = None
    assert rp.describe("claude-haiku-5-5")["route"] == "api"
    ask(rp)
    rp.state.mark_down("api", "credit")
    ask(rp)
    assert calls and rp.last_route == "api"


# ---------------------------------------------------------------- item 4: card hygiene (recorder and lt prep-check)

import importlib.machinery  # noqa: E402
import importlib.util  # noqa: E402
import sys  # noqa: E402
from pathlib import Path  # noqa: E402

APP = Path(__file__).resolve().parents[3]


@pytest.fixture(scope="module")
def T():
    spec = importlib.util.spec_from_file_location("lt_transcriber_092", APP / "recorder/src/transcriber.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber_092"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def LT():
    loader = importlib.machinery.SourceFileLoader("lt_cli_092", str(APP / "recorder/bin/lt"))
    spec = importlib.util.spec_from_loader("lt_cli_092", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _cards(T, tmp_path, cards, names=()):
    (tmp_path / "c.cards.json").write_text(json.dumps(cards), encoding="utf-8")
    cs = T.Cards(tmp_path / "c.md", tmp_path / "tips.jsonl")
    cs.names = list(names)
    return cs


def _tips(tmp_path):
    p = tmp_path / "tips.jsonl"
    return [json.loads(x) for x in p.read_text(encoding="utf-8").splitlines()] if p.exists() else []


def test_regex_only_card_never_fires_by_meaning(T):
    promise = {"id": "my-estimate", "on": "me", "gist": "🔴 Date without an estimate",
               "triggers": ["re:(we will|i will) deliver by (monday|friday|\\d)"]}
    assert T.card_sem_texts(promise) == []
    assert T.card_sem_texts(dict(promise, semantic=True)) == ["Date without an estimate"]
    plain = {"id": "cr", "gist": "🔴 New request", "triggers": ["could you also", "re:x"], "words": ["scope"]}
    assert T.card_sem_texts(plain) == ["New request. could you also. scope", "could you also"]


def test_your_turn_card_is_held_not_shown(T, tmp_path):
    clock = [1000.0]
    T.now = lambda: clock[0]
    turn = {"id": "your-turn", "on": "them", "gist": "🔴 Your turn", "triggers": ["re:(mike\\w*)\\W+.{0,40}(update|your turn)"]}
    cr = {"id": "cr", "on": "them", "gist": "🔴 New request", "triggers": ["could you also"]}
    cs = _cards(T, tmp_path, [turn, cr], names=["Mike"])
    cs.check(T.Line("them", 1000.0, "en", "Mike, can you give us your update?"))
    cs.check(T.Line("them", 1001.0, "en", "Could you also add the export?"))
    assert [t["card"] for t in _tips(tmp_path)] == ["cr"]
    fired = [json.loads(x) for x in (tmp_path / "c.cards-fired.jsonl").read_text().splitlines()]
    assert fired[0] == {"id": "your-turn", "t": T.hhmmss(1000.0), "ch": "them", "line": "Mike, can you give us your update?",
                        "held": "address"}
    assert cs.is_address({"id": "x", "address": True, "triggers": ["anything"]})
    assert not _cards(T, tmp_path, [turn]).is_address(turn)      # no aliases set: only "address": true counts
    assert cs.fire_semantic("your-turn", T.Line("them", 1100.0, "en", "x"), 0.9) == "address"


def test_a_card_shows_by_meaning_once_per_call(T, tmp_path):
    clock = [1000.0]
    T.now = lambda: clock[0]
    hub = {"id": "hubspot", "on": "them", "gist": "🟠 HubSpot on Starter", "triggers": ["sales hub"], "cooldown_s": 600}
    cs = _cards(T, tmp_path, [hub])
    cs.snapshot()
    line = T.Line("them", 1000.0, "en", "what about the CRM we pay for")
    assert cs.fire_semantic("hubspot", line, 0.7) is None
    clock[0] += 300
    assert cs.fire_semantic("hubspot", line, 0.7) == "cooldown"
    clock[0] += 1300                                                # 21 minutes later, as on 04.11
    assert cs.fire_semantic("hubspot", line, 0.7) == "shown before"
    cs.check(T.Line("them", clock[0], "en", "And the Sales Hub seats?"))     # its trigger still shows it
    assert [t["card"] for t in _tips(tmp_path)] == ["hubspot", "hubspot"]


def test_card_with_only_words_still_loads(T):
    assert [c["id"] for c in T.parse_cards([{"id": "w", "gist": "g", "triggers": [], "words": ["gdpr"]},
                                            {"id": "none", "gist": "g", "triggers": []}])] == ["w"]


def test_prep_check_finds_and_fixes_ignored_one_word_triggers(LT, T, tmp_path, capsys):
    cards = [{"id": "hub", "gist": "g", "triggers": ["hubspot", "sales hub", "intelligence", "міні-crm", "re:\\bgdpr\\b", "v2"]},
             {"id": "law", "gist": "g", "triggers": ["gdpr", "bipa"]}]
    for t in ("hubspot", "sales hub", "intelligence", "міні-crm", "re:\\bgdpr\\b", "v2", "gdpr"):
        plain = " " + T.norm(t + " here") + " "
        assert LT.dead_trigger(t) == (not t.startswith("re:") and not T.Cards._hit(t, t.lower(), plain)), t
    base = tmp_path / "call"
    (tmp_path / "call.cards.json").write_text(json.dumps(cards), encoding="utf-8")
    (tmp_path / "call.facts.json").write_text(json.dumps([{"id": "f", "title": "t", "text": "x", "keywords": ["k"]}]))
    (tmp_path / "call.brief.md").write_text("# Live Brief: Call\n")
    LT.cmd_prep_check([str(base) + ".md"])
    res = json.loads(capsys.readouterr().out)
    assert res["verdict"] == "OK" and res["warnings"][0].startswith("4 triggers the recorder ignores")
    assert "hub: hubspot" in res["warnings"][0] and "law: bipa" in res["warnings"][0]
    LT.cmd_prep_check([str(base) + ".md", "--fix"])
    res = json.loads(capsys.readouterr().out)
    assert "warnings" not in res and res["fixed"][0].startswith("4 one-word triggers moved")
    got = json.loads((tmp_path / "call.cards.json").read_text())
    assert got[0]["triggers"] == ["sales hub", "intelligence", "re:\\bgdpr\\b", "v2"] and got[0]["words"] == ["hubspot", "міні-crm"]
    assert got[1]["triggers"] == [] and got[1]["words"] == ["gdpr", "bipa"]
    assert [c["id"] for c in T.parse_cards(got)] == ["hub", "law"]


# ---------------------------------------------------------------- item 2: a statement the prepared material answers

def test_answer_in_primary_is_a_classify_trigger_and_off_for_interviews():
    from livetips_m0.prompt import CLASSIFY_ANY, disabled_triggers
    from livetips_m0.rules import Rules
    r = Rules()
    t = next(x for x in r.triggers["triggers"] if x["id"] == "answer_in_primary")
    assert t["route"] == "classify" and t["level"] == "orange"
    assert "answer_in_primary" in r.classify_schema["properties"]["trigger"]["enum"]
    assert r.diet["answer_in_primary"] == {"per_10_min": 2, "once_per_topic": True}
    assert "answer_in_primary" in CLASSIFY_ANY
    assert "answer_in_primary" in disabled_triggers({"call_type": "interview"})
    assert "answer_in_primary" not in disabled_triggers({"call_type": "auto", "proactive": False})


def test_answer_in_primary_tips_are_limited(tmp_path):
    import time as _t
    from test_engine import _feed, _meeting_engine, _out
    asked = []

    def resp(model, user):
        if "ROLE classify" in user:
            topic = ["Немає структури", "Немає структури процесу", "Недовіра до sheet", "Обов'язкові питання"][len(asked) % 4]
            asked.append(topic)
            return json.dumps({"need_tip": True, "level": "orange", "trigger": "answer_in_primary", "topic": topic})
        assert "The other side stated something" in user
        n = len(asked)
        return json.dumps({"gist": "🟠 Відповідь " + str(n), "level": "orange", "topic": asked[-1],
                           "phrase": "У нас уже є чек-лист " + str(n), "trigger": "answer_in_primary",
                           "fact_ids": ["fact:a" + str(n)]})
    eng, clock = _meeting_engine(tmp_path, resp, proactive=True, periodic_classify_s=20)
    for i, (hms, at) in enumerate((("10:00:00", 36000), ("10:01:40", 36100), ("10:03:20", 36200), ("10:05:00", 36300))):
        text = ["Мені здається, у нас взагалі немає ніякої структури процесу продажів",
                "Ну от і виходить, що структури в процесі в нас так і немає досі",
                "Я не довіряю тим даним, що в meeting sheet, там багато вигадок",
                "Обов'язкових питань до інтерв'ю в нас теж ніхто не затверджував"][i]
        _feed(eng, clock, "[{}] Other (uk): {}".format(hms, text), i + 1, at)
    tips, timing = _out(tmp_path)
    shown = [t for t in tips if t.get("trigger") == "answer_in_primary" and not t.get("partial")]
    outs = [s.get("outcome") for s in timing if s.get("classify", {}).get("trigger") == "answer_in_primary"]
    assert outs == ["emitted", "aip_same_topic", "emitted", "aip_rate"]     # 2 in 10 minutes, one per topic
    assert len(shown) == 2


def test_answer_in_primary_on_used_facts_is_a_repeat():
    from livetips_m0.engine import Engine, TipRun
    eng = Engine.__new__(Engine)
    import threading
    eng.lock = threading.RLock()
    eng.tips = [{"trigger": "answer_in_primary", "fact_ids": ["fact:checklist"], "partial": False}]
    run = TipRun(None, "answer_in_primary", {}, None, "u")
    run.obj = {"fact_ids": ["fact:checklist", "fact:cwh"]}
    assert eng._tip_aip_repeat(run) == "aip_same_facts"
    run.obj = {"fact_ids": ["fact:other"]}
    assert eng._tip_aip_repeat(run) is None


def test_an_agenda_item_to_agree_needs_a_decision():
    from livetips_m0.engine import DECIDE_ITEM, decided_on
    item = "Погодити з Emily головний висновок: пріоритет Sales"
    assert DECIDE_ITEM.search(item) and DECIDE_ITEM.search("Agree on the release date") and not DECIDE_ITEM.search("Show the checklist")
    assert not decided_on(item, ["Fireflies trial starts on Monday"])
    assert decided_on(item, ["Пріоритет: Sales, головний висновок прийнято"])
