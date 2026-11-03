"""OpenAI transport contract, route isolation and budget accounting; no network or real credentials."""
import io
import json
import urllib.error

import pytest

from livetips_m0.cost import cost_usd
from livetips_m0.openai_provider import MODEL, OpenAIProvider
from livetips_m0.providers import Completion, FakeProvider
from livetips_m0.routing import RouteState, RoutedProvider, provider_from_cfg, provider_from_env


def stream(*events):
    return io.BytesIO(b"".join(b"data: " + json.dumps(e).encode() + b"\n\n" for e in events))


def terminal(kind="response.completed"):
    return {"type": kind, "response": {"usage": {"input_tokens": 100, "output_tokens": 20,
                                                "input_tokens_details": {"cached_tokens": 40}}}}


def complete(provider, callback=None):
    return provider.complete(model="claude-haiku-5-5", system=[{"text": "rules", "cache": True}],
                             user=[{"text": "question"}], max_tokens=60, cache_ttl="1h",
                             extra={"thinking": {"type": "disabled"}}, on_text=callback)


def test_stream_request_usage_and_cost(monkeypatch):
    seen = {}

    def send(request, timeout):
        seen.update(body=json.loads(request.data), url=request.full_url, headers=dict(request.header_items()), timeout=timeout)
        return stream({"type": "response.output_text.delta", "delta": '{"gist":'},
                      {"type": "response.output_text.delta", "delta": '"Ready"}'}, terminal())

    monkeypatch.setattr("urllib.request.urlopen", send)
    chunks = []
    c = complete(OpenAIProvider("test-key", timeout=7), chunks.append)
    assert c.error is None and c.text == '{"gist":"Ready"}' and c.model == MODEL
    assert chunks == ['{"gist":', '{"gist":"Ready"}'] and c.t_gist and c.t_first_token and c.t_done
    assert (c.input_tokens, c.cache_read, c.output_tokens) == (60, 40, 20)
    assert cost_usd(c.model, c.input_tokens, 0, 0, c.cache_read, c.output_tokens) == pytest.approx(0.000138)
    assert seen["url"] == "https://api.openai.com/v1/responses" and seen["timeout"] == 7
    assert seen["headers"]["Authorization"] == "Bearer test-key"
    assert seen["body"] == {"model": MODEL, "instructions": "rules", "input": "question", "max_output_tokens": 60,
                            "reasoning": {"effort": "none"}, "stream": True, "store": False}


@pytest.mark.parametrize("events", [[], [{"type": "response.output_text.delta", "delta": "partial"}],
                                   [terminal()], [terminal("response.incomplete")], [terminal("response.failed")],
                                   [{"type": "error", "code": "server_error"}],
                                   [{"type": "response.refusal.delta"}, terminal()]])
def test_failure_is_never_a_good_answer(monkeypatch, events):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **kw: stream(*events))
    assert complete(OpenAIProvider("test-key")).error


def test_http_errors_do_not_expose_credentials(monkeypatch):
    def send(*a, **kw):
        raise urllib.error.HTTPError("https://api.openai.com", 401, "test-key secret prompt", {}, io.BytesIO(b"secret"))
    monkeypatch.setattr("urllib.request.urlopen", send)
    assert complete(OpenAIProvider("test-key")).error == "OpenAI: HTTP 401"
    assert complete(OpenAIProvider("")).error == "OpenAI: no API key"


def test_route_does_not_fall_back_to_claude_or_local(monkeypatch, tmp_path):
    monkeypatch.setenv("LT_LOCAL_FALLBACK", "1")
    forbidden = FakeProvider(lambda *a: pytest.fail("unexpected provider switch"))
    st = RouteState(str(tmp_path / "routes.json"))
    rp = RoutedProvider("after", "openai", {"openai": None, "api": forbidden, "code": forbidden, "local": forbidden}, state=st)
    assert complete(rp).error and not rp.can_run_without_api()
    assert st.is_down("openai")


def test_factories_and_spending_guard(monkeypatch, tmp_path):
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    monkeypatch.setenv("LT_AI_ROUTE", "openai")
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "routes.json"))
    assert isinstance(provider_from_env().legs["openai"], OpenAIProvider)
    rp = provider_from_cfg({"ai": {"routes": {"tips": "openai"}, "state": str(tmp_path / "s.json")}}, lambda k: "")
    assert rp.preferred == "openai" and not rp.auto and isinstance(rp.legs["openai"], OpenAIProvider)
    rp.api_blocked = lambda: True
    assert not rp.usable("openai") and not rp.can_run_without_api()


def test_success_written_to_spend_ledger(monkeypatch, tmp_path):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **kw: stream(
        {"type": "response.output_text.delta", "delta": "OK"}, terminal()))
    rp = RoutedProvider("after", "openai", {"openai": OpenAIProvider("test-key")}, state=RouteState(str(tmp_path / "s.json")))
    assert complete(rp).error is None
    row = json.loads((tmp_path / "spend-ledger.jsonl").read_text())
    assert row["route"] == "openai" and row["usd"] == pytest.approx(0.000138)


def test_transport_and_malformed_stream_errors(monkeypatch):
    def fail(*a, **kw):
        raise TimeoutError("test-key secret prompt")
    monkeypatch.setattr("urllib.request.urlopen", fail)
    assert complete(OpenAIProvider("test-key")).error == "OpenAI: TimeoutError"
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **kw: io.BytesIO(b"data: invalid\n"))
    assert complete(OpenAIProvider("test-key")).error == "OpenAI: JSONDecodeError"


def test_disabled_deep_search_does_not_promise_a_search():
    from livetips_m0.engine import Engine
    from livetips_m0.providers import Completion
    eng = Engine.__new__(Engine)
    eng.cfg = {"deep_lookup": False}
    eng._ui_uk = lambda: False
    eng._start_deep = lambda *a: pytest.fail("Claude Code must not run")
    result = eng._request_answer(Completion(error="OpenAI: HTTP 401"), "ask", "when?", None)
    assert result["gist"] == "No ready answer" and "note" not in result


def test_openai_budget_hard_stop(tmp_path):
    from livetips_m0.cost import BudgetGuard
    from livetips_m0.engine import Engine
    eng = Engine.__new__(Engine)
    eng.provider = RoutedProvider("tips", "openai", {"openai": OpenAIProvider("test-key")},
                                  state=RouteState(str(tmp_path / "s.json")))
    eng.budget = BudgetGuard(str(tmp_path / "spend.json"), 1, 0.0001, 100)
    assert not eng._budget_stops()
    eng._bill(Completion(model=MODEL, input_tokens=60, cache_read=40, output_tokens=20))
    assert eng._budget_stops()
