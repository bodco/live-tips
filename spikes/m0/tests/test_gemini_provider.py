"""Gemini transport contract, cost, and the opt-in plan B; no network or real credentials."""
import io
import json
import urllib.error

import pytest

from livetips_m0.cost import cost_usd, price_for
from livetips_m0.gemini_provider import GeminiProvider, MODEL, job_model, thinking_level
from livetips_m0.providers import Completion
from livetips_m0.routing import RouteState, RoutedProvider, out_reason


def sse(*chunks):
    return io.BytesIO(b"".join(b"data: " + json.dumps(c).encode() + b"\r\n\r\n" for c in chunks))


def text(piece, reason=None, usage=None, thought=False):
    part = {"text": piece}
    if thought:
        part["thought"] = True
    cand = {"content": {"role": "model", "parts": [part]}}
    if reason:
        cand["finishReason"] = reason
    chunk = {"candidates": [cand]}
    if usage:
        chunk["usageMetadata"] = usage
    return chunk


USAGE = {"promptTokenCount": 100, "cachedContentTokenCount": 40, "candidatesTokenCount": 20, "thoughtsTokenCount": 10}


def complete(provider, callback=None, max_tokens=60):
    return provider.complete(model="claude-haiku-5-5", system=[{"text": "rules", "cache": True}],
                             user=[{"text": "question"}], max_tokens=max_tokens, cache_ttl="1h",
                             extra={"thinking": {"type": "disabled"}}, on_text=callback)


def http_error(code, body):
    return urllib.error.HTTPError("https://x", code, "err", {}, io.BytesIO(json.dumps(body).encode()))


def test_stream_request_usage_and_cost(monkeypatch):
    seen = {}

    def send(request, timeout):
        seen.update(body=json.loads(request.data), url=request.full_url, headers=dict(request.header_items()), timeout=timeout)
        return sse(text('{"gist":'), text('"Ready"}', "STOP", USAGE))

    monkeypatch.setattr("urllib.request.urlopen", send)
    chunks = []
    c = complete(GeminiProvider("test-key", timeout=7), chunks.append)
    assert c.error is None and c.text == '{"gist":"Ready"}' and c.model == MODEL and c.route == "gemini"
    assert chunks == ['{"gist":', '{"gist":"Ready"}'] and c.t_gist and c.t_first_token and c.t_done
    # the prompt count includes the cached part; thinking is billed as output
    assert (c.input_tokens, c.cache_read, c.output_tokens, c.reasoning_tokens) == (60, 40, 30, 10)
    assert cost_usd(c.model, c.input_tokens, 0, 0, c.cache_read, c.output_tokens) == pytest.approx(
        (60 * 0.30 + 40 * 0.03 + 30 * 2.50) / 1e6)
    assert seen["url"] == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:streamGenerateContent?alt=sse"
    assert "test-key" not in seen["url"] and seen["headers"]["X-goog-api-key"] == "test-key" and seen["timeout"] == 7
    assert seen["body"] == {"systemInstruction": {"parts": [{"text": "rules"}]},
                            "contents": [{"role": "user", "parts": [{"text": "question"}]}],
                            "generationConfig": {"maxOutputTokens": 60 + 128, "thinkingConfig": {"thinkingLevel": "minimal"}}}


def test_usage_is_cumulative_in_a_stream_not_added_per_chunk(monkeypatch):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse(
        text("a", usage={"promptTokenCount": 50, "candidatesTokenCount": 1}),
        text("b", "STOP", {"promptTokenCount": 50, "candidatesTokenCount": 7})))
    c = complete(GeminiProvider("k"))
    assert (c.input_tokens, c.output_tokens) == (50, 7)


def test_thought_parts_are_never_part_of_the_answer(monkeypatch):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse(
        text("secret reasoning", thought=True), text('{"gist":"ok"}', "STOP", USAGE)))
    assert complete(GeminiProvider("k")).text == '{"gist":"ok"}'


def test_job_models_and_thinking_levels():
    assert job_model("tips") == "gemini-3.5-flash-lite" and job_model("after") == "gemini-3.8-flash"
    assert job_model("prep") == "gemini-3.8-flash" and job_model("tips", "gemini-4-argon") == "gemini-4-argon"
    assert job_model("after", "claude-sonnet-5-5") == "gemini-3.8-flash"     # a Claude or GPT id never reaches Gemini
    assert thinking_level("gemini-3.5-flash-lite") == "minimal"
    assert thinking_level("gemini-3.8-flash") == thinking_level("gemini-4-argon") == "low"


def test_provider_uses_its_job_model_not_the_claude_id(monkeypatch):
    seen = []
    monkeypatch.setattr("urllib.request.urlopen", lambda r, timeout: (seen.append(r.full_url), sse(text("x", "STOP", USAGE)))[1])
    p = GeminiProvider("k", model="gemini-3.8-flash")
    p.complete(model="claude-sonnet-5-5", system=[{"text": "s"}], user="u", max_tokens=30, cache_ttl=None)
    p.complete(model="gemini-4-argon", system=[{"text": "s"}], user="u", max_tokens=30, cache_ttl=None)
    assert "models/gemini-3.8-flash:" in seen[0] and "models/gemini-4-argon:" in seen[1]


def test_prices_and_announced_rises():
    assert price_for("gemini-4-argon", "2026-11-30") == (2.0, 0.0, 0.0, 0.10, 10.0)
    assert price_for("gemini-4-argon", "2026-12-01") == (4.0, 0.0, 0.0, 0.20, 20.0)
    assert price_for("gemini-3.8-flash", "2026-12-31")[0] == 0.75 and price_for("gemini-3.8-flash", "2027-01-01")[0] == 1.50
    assert price_for("gemini-3.5-flash-lite", "2027-06-01")[4] == 2.50          # no rise announced


@pytest.mark.parametrize("reason,done", [("SAFETY", "Gemini: SAFETY"), ("RECITATION", "Gemini: RECITATION")])
def test_a_blocked_or_odd_finish_is_never_a_good_answer(monkeypatch, reason, done):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse(text("partial", reason, USAGE)))
    assert complete(GeminiProvider("k")).error == done


def test_stream_without_a_finish_or_a_prompt_block_is_an_error(monkeypatch):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse(text("cut off")))
    assert complete(GeminiProvider("k")).error == "Gemini: incomplete or empty stream"
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse({"promptFeedback": {"blockReason": "OTHER"}}))
    assert complete(GeminiProvider("k")).error == "Gemini: blocked OTHER"
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse({"error": {"status": "UNAVAILABLE", "message": "secret prompt"}}))
    c = complete(GeminiProvider("k"))
    assert c.error == "Gemini: UNAVAILABLE" and "secret" not in c.error


def test_no_key_and_transport_errors_never_leak(monkeypatch):
    assert complete(GeminiProvider("")).error == "Gemini: no API key"

    def fail(*a, **k):
        raise TimeoutError("test-key secret prompt")
    monkeypatch.setattr("urllib.request.urlopen", fail)
    assert complete(GeminiProvider("test-key")).error == "Gemini: TimeoutError"
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: io.BytesIO(b"data: invalid\n"))
    assert complete(GeminiProvider("test-key")).error == "Gemini: JSONDecodeError"


def test_http_errors_say_status_and_code_only(monkeypatch):
    def quota(*a, **k):
        raise http_error(429, {"error": {"code": "quota_exceeded", "message": "key test-key prompt secret"}})
    monkeypatch.setattr("urllib.request.urlopen", quota)
    c = complete(GeminiProvider("test-key"))
    assert c.error == "Gemini: HTTP 429 (quota_exceeded)" and "secret" not in c.error and "test-key" not in c.error
    assert out_reason("gemini", c.error) == "credit"

    def plain(*a, **k):
        raise http_error(429, {"error": {"code": "rate_limit_exceeded"}})
    monkeypatch.setattr("urllib.request.urlopen", plain)
    assert out_reason("gemini", complete(GeminiProvider("k")).error) is None       # a passing error, not an outage


@pytest.mark.parametrize("code,reason", [(401, "auth"), (403, "auth"), (402, "credit")])
def test_outage_reasons(monkeypatch, code, reason):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: (_ for _ in ()).throw(http_error(code, {"error": {}})))
    assert out_reason("gemini", complete(GeminiProvider("k")).error) == reason


def test_thinking_setting_rejected_is_retried_once_without_it(monkeypatch):
    bodies = []

    def send(request, timeout):
        body = json.loads(request.data)
        bodies.append(body)
        if "thinkingConfig" in body["generationConfig"]:
            raise http_error(400, {"error": {"status": "INVALID_ARGUMENT", "message": "echo of the prompt"}})
        return sse(text("ok", "STOP", USAGE))

    monkeypatch.setattr("urllib.request.urlopen", send)
    c = complete(GeminiProvider("k"))
    assert c.error is None and c.text == "ok" and len(bodies) == 2


def test_an_answer_cut_by_the_limit_keeps_a_whole_json_object_or_is_asked_again(monkeypatch):
    monkeypatch.setattr("urllib.request.urlopen", lambda *a, **k: sse(text('{"gist":"Ready"} and on', "MAX_TOKENS", USAGE)))
    c = complete(GeminiProvider("k"))
    assert c.error is None and c.text == '{"gist":"Ready"}' and c.tail > 0

    seen = []

    def send(request, timeout):
        seen.append(json.loads(request.data)["generationConfig"]["maxOutputTokens"])
        return sse(text('{"gist":', "MAX_TOKENS", USAGE)) if len(seen) == 1 else sse(text('{"gist":"Ready"}', "STOP", USAGE))

    monkeypatch.setattr("urllib.request.urlopen", send)
    c = complete(GeminiProvider("k"), max_tokens=60)
    assert c.error is None and c.retried == "longer" and seen == [188, 564]      # the answer limit plus room to think
    assert c.input_tokens == 120 and c.output_tokens == 60       # both requests are billed


class Leg:
    """A provider that answers or is out, to see where a job goes."""
    def __init__(self, route, error=None):
        self.route, self.error, self.calls = route, error, 0

    def complete(self, **kw):
        self.calls += 1
        return Completion(model=self.route, text="" if self.error else "answer", error=self.error)


def routed(preferred, legs, tmp_path, fallback=True, **kw):
    return RoutedProvider("after", preferred, legs, state=RouteState(str(tmp_path / "r.json")), gemini_fallback=fallback, **kw)


def ask(rp):
    return rp.complete(model="claude-sonnet-5-5", system=[{"text": "s"}], user="u", max_tokens=30, cache_ttl=None)


@pytest.mark.parametrize("preferred,error", [("openai", "OpenAI: HTTP 401"), ("openai", "OpenAI: insufficient_quota"),
                                              ("api", "AuthenticationError: invalid x-api-key")])
def test_plan_b_takes_the_job_when_the_chosen_way_is_out(tmp_path, preferred, error):
    chosen, gem = Leg(preferred, error), Leg("gemini")
    legs = {preferred: chosen, "gemini": gem, "code": None}
    rp = routed(preferred, legs, tmp_path)
    c = ask(rp)
    assert c.error is None and c.route == "gemini" and c.switched_from == preferred and rp.last_route == "gemini"
    # the next job goes to Gemini at once, without asking the out way again
    n = chosen.calls
    c = ask(rp)
    assert c.route == "gemini" and chosen.calls == n


def test_plan_b_is_off_by_default_and_never_used_for_a_passing_error(tmp_path):
    out, gem = Leg("openai", "OpenAI: HTTP 401"), Leg("gemini")
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    c = ask(routed("openai", {"openai": out, "gemini": gem}, tmp_path / "a", fallback=False))
    assert c.error and gem.calls == 0
    slow = Leg("openai", "OpenAI: TimeoutError")
    c = ask(routed("openai", {"openai": slow, "gemini": gem}, tmp_path / "b"))
    assert c.error and gem.calls == 0 and c.route == "openai"


def test_plan_b_without_a_gemini_key_changes_nothing(tmp_path):
    c = ask(routed("openai", {"openai": Leg("openai", "OpenAI: HTTP 401"), "gemini": None}, tmp_path))
    assert c.error == "OpenAI: HTTP 401"


def test_chosen_gemini_has_no_plan_b_and_does_not_fall_back_to_claude(tmp_path):
    forbidden = Leg("api")
    rp = routed("gemini", {"gemini": Leg("gemini", "Gemini: HTTP 401"), "api": forbidden, "code": forbidden}, tmp_path)
    c = ask(rp)
    assert c.error == "Gemini: HTTP 401" and forbidden.calls == 0


def test_when_the_chosen_way_answers_again_the_job_goes_back(tmp_path):
    chosen, gem = Leg("openai", "OpenAI: HTTP 401"), Leg("gemini")
    rp = routed("openai", {"openai": chosen, "gemini": gem}, tmp_path, probe_every=0.0)
    ask(rp)
    chosen.error = None                      # the PM paid the bill
    c = ask(rp)
    assert c.route == "openai" and c.error is None
