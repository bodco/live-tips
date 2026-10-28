"""0.8.2: AI routes (the key or Claude Code) and the automatic switch."""
import json
import os
import stat
import sys
import time

from livetips_m0.providers import Completion, FakeProvider, Provider
from livetips_m0.routing import (ClaudeCodeProvider, RouteState, RoutedProvider, cc_model, other, out_reason,
                                 provider_from_cfg)


class Failing(Provider):
    def __init__(self, error):
        self.error = error
        self.calls = 0

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        self.calls += 1
        return Completion(model=model, t_start=time.monotonic(), t_done=time.monotonic(), error=self.error)


def ok(text="{}"):
    return FakeProvider(lambda m, u: text)


def test_names_and_reasons():
    assert other("api") == "code" and other("code") == "api"
    assert cc_model("claude-haiku-5-5") == "haiku" and cc_model("claude-opus-5-5") == "opus"
    assert out_reason("api", "BadRequestError: Your credit balance is too low to access the API") == "credit"
    assert out_reason("api", "AuthenticationError: invalid x-api-key") == "auth"
    assert out_reason("api", "APITimeoutError: Request timed out.") is None          # passing: no switch
    assert out_reason("api", "RateLimitError: 429") is None
    assert out_reason("code", "ClaudeCode: Claude usage limit reached. Your limit will reset at 5pm") == "limit"
    assert out_reason("code", "ClaudeCode: Invalid API key · Please run /login") == "auth"
    assert out_reason("code", "NoRoute: Claude Code is not installed") == "missing"


def test_switch_to_code_when_api_is_out_and_back(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    api = Failing("BadRequestError: Your credit balance is too low")
    code = ok('{"gist":"x"}')
    rp = RoutedProvider("after", "api", {"api": api, "code": code}, auto=True, state=st, probe_every=3600)
    c = rp.complete(model="claude-sonnet-5-5", system=[{"text": "s"}], user="u", max_tokens=10, cache_ttl=None)
    assert not c.error and c.route == "code" and c.switched_from == "api"
    assert st.is_down("api") and st.read()["api"]["reason"] == "credit"
    # next job: the API is still marked out and not due for a check, so it goes straight to Claude Code
    c = rp.complete(model="m", system=[{"text": "s"}], user="u", max_tokens=10, cache_ttl=None)
    assert c.route == "code" and api.calls == 1
    # the balance is topped up: the check is due, the API answers, the job goes back
    rp.legs["api"] = ok()
    rp.probe_every = 0
    c = rp.complete(model="m", system=[{"text": "s"}], user="u", max_tokens=10, cache_ttl=None)
    assert c.route == "api" and not st.is_down("api")


def test_switch_to_api_when_code_is_out(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    rp = RoutedProvider("tips", "code", {"api": ok(), "code": Failing("ClaudeCode: usage limit reached")},
                        auto=True, state=st, probe_every=3600, background=True)
    c = rp.complete(model="m", system=[{"text": "s"}], user="u", max_tokens=10, cache_ttl=None)
    assert c.route == "api" and st.read()["code"]["reason"] == "limit"


def test_no_auto_switch_keeps_the_route(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    api = Failing("BadRequestError: Your credit balance is too low")
    rp = RoutedProvider("tips", "api", {"api": api, "code": ok()}, auto=False, state=st)
    c = rp.complete(model="m", system=[{"text": "s"}], user="u", max_tokens=10, cache_ttl=None)
    assert c.error and c.route == "api"
    assert st.is_down("api")                     # Settings > AI still shows why


def test_missing_leg_and_app_limit(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    rp = RoutedProvider("after", "api", {"api": None, "code": ok()}, auto=True, state=st)
    assert rp.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None).route == "code"
    blocked = {"v": True}
    rp = RoutedProvider("tips", "api", {"api": ok(), "code": ok()}, auto=True, state=RouteState(str(tmp_path / "t.json")),
                        api_blocked=lambda: blocked["v"])
    assert rp.pick() == "code" and rp.can_run_without_api()
    blocked["v"] = False
    assert rp.pick() == "api"


def test_extra_goes_to_the_key_only(tmp_path):
    seen = {}

    class Spy(Provider):
        def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
            seen["extra"] = extra
            return Completion(model=model, text="{}", t_start=0, t_done=0)
    rp = RoutedProvider("after", "code", {"api": None, "code": Spy()}, state=RouteState(str(tmp_path / "s.json")))
    rp.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None, extra={"thinking": {"type": "disabled"}})
    assert seen["extra"] is None


FAKE_CLI = r'''#!{py}
import json, sys
args = sys.argv[1:]
prompt = sys.stdin.read()
sysfile = args[args.index("--system-prompt-file") + 1]
system = open(sysfile).read()
mode = "{mode}"
if mode == "limit":
    print(json.dumps({{"type": "result", "subtype": "success", "is_error": True, "result": "Claude usage limit reached"}}))
    sys.exit(1)
for piece in ['{{"gist":', '"' + args[args.index("--model") + 1] + '|' + system + '|' + prompt + '"}}']:
    print(json.dumps({{"type": "stream_event", "event": {{"type": "content_block_delta", "delta": {{"type": "text_delta", "text": piece}}}}}}))
print(json.dumps({{"type": "result", "subtype": "success", "is_error": False, "result": "",
                  "total_cost_usd": 0.01, "usage": {{"input_tokens": 50, "output_tokens": 7}}}}))
'''


def _cli(tmp_path, mode):
    p = tmp_path / ("claude-" + mode)
    p.write_text(FAKE_CLI.format(py=sys.executable, mode=mode))
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return str(p)


def test_claude_code_provider_streams_and_reports(tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "must-not-leak")
    pv = ClaudeCodeProvider(_cli(tmp_path, "ok"), timeout=30)
    seen = []
    c = pv.complete(model="claude-haiku-5-5", system=[{"text": "SYS"}], user="USER", max_tokens=5, cache_ttl="1h",
                    on_text=seen.append)
    assert not c.error, c.error
    assert json.loads(c.text)["gist"] == "haiku|SYS|USER"
    assert c.model == "claude-code/haiku" and c.route == "code" and c.t_gist is not None and seen
    assert c.input_tokens == 50 and c.output_tokens == 7 and c.equiv_usd == 0.01
    c = ClaudeCodeProvider(_cli(tmp_path, "limit"), timeout=30).complete(
        model="sonnet", system=[{"text": "s"}], user="u", max_tokens=5, cache_ttl=None)
    assert out_reason("code", c.error) == "limit"


def test_cost_of_claude_code_is_not_billed():
    from livetips_m0.cost import cost_usd
    assert cost_usd("claude-code/sonnet", 1000, 0, 0, 0, 1000) is None


def test_provider_from_cfg(tmp_path):
    cfg = {"api_key_env": "CLAUDE_API", "ai": {"routes": {"tips": "code", "after": "api"}, "auto": False,
                                               "state": str(tmp_path / "s.json"), "claude_cli": _cli(tmp_path, "ok")}}
    def loader(n):
        raise KeyError(n)
    rp = provider_from_cfg(cfg, loader)
    assert rp.job == "tips" and rp.preferred == "code" and rp.legs["api"] is None and rp.legs["code"] is not None
    assert provider_from_cfg(cfg, loader, job="after").preferred == "api"
