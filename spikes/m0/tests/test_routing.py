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


FAKE_CLI = r'''import json, sys
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
    """A stand-in `claude`: a shell script that runs a Python script (a #! line cannot hold a path with
    spaces, and the test interpreter may live in one)."""
    script = tmp_path / ("claude-" + mode + ".py")
    script.write_text(FAKE_CLI.format(mode=mode))
    p = tmp_path / ("claude-" + mode)
    p.write_text('#!/bin/sh\nexec "{}" "{}" "$@"\n'.format(sys.executable, script))
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


def test_provider_from_env_without_a_route_is_the_key_alone(tmp_path, monkeypatch):
    from livetips_m0.routing import provider_from_env
    monkeypatch.delenv("LT_AI_ROUTE", raising=False)
    monkeypatch.delenv("CLAUDE_API", raising=False)
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "s.json"))
    p = provider_from_env("after")
    assert p.preferred == "api" and not p.auto and p.legs["code"] is None
    c = p.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None)
    assert out_reason("api", c.error) == "no_key"


def test_provider_from_env_with_a_route_switches_by_itself(tmp_path, monkeypatch):
    from livetips_m0.routing import provider_from_env
    monkeypatch.setenv("LT_AI_ROUTE", "code")
    monkeypatch.setenv("LT_AI_AUTO", "1")
    monkeypatch.setenv("LT_CLAUDE_CLI", _cli(tmp_path, "ok"))
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "s.json"))
    monkeypatch.delenv("CLAUDE_API", raising=False)
    p = provider_from_env("after")
    assert p.preferred == "code" and p.auto and p.legs["code"] is not None and p.legs["api"] is None
    assert not p.complete(model="haiku", system=[{"text": "s"}], user="u", max_tokens=5, cache_ttl=None).error


def test_ping_marks_a_way_that_cannot_answer(tmp_path, monkeypatch, capsys):
    import json as _json
    from livetips_m0.routing import main
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "s.json"))
    monkeypatch.delenv("CLAUDE_API", raising=False)
    assert main(["ping", "--route", "api"]) == 0
    assert _json.loads(capsys.readouterr().out)["api"]["reason"] == "no_key"
    assert main(["status"]) == 0 and "api" in capsys.readouterr().out


def test_claude_code_without_a_final_event_reports_the_exit(tmp_path):
    from livetips_m0.routing import cc_finish
    from livetips_m0.providers import Completion
    c = cc_finish(Completion(t_start=0), None, 2, "boom")
    assert c.error == "ClaudeCode: exit 2 boom"
    c = cc_finish(Completion(t_start=0, text="{}"), {"subtype": "success", "usage": {"input_tokens": 3}}, 0, "")
    assert not c.error and c.input_tokens == 3


# ---- behaviour pinned for mutation testing (ub-mode) ----

def test_state_file_location_and_new_folders(tmp_path, monkeypatch):
    from livetips_m0.routing import default_state_path
    monkeypatch.delenv("LT_AI_STATE", raising=False)
    assert default_state_path().endswith("Library/Application Support/LiveTips/state/ai-routes.json")
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "x.json"))
    assert default_state_path() == str(tmp_path / "x.json")
    st = RouteState(str(tmp_path / "a" / "b" / "s.json"))
    st.mark_down("api", "credit")
    st.mark_down("code", "limit")                  # the folder exists by now: still written
    assert st.read()["code"]["reason"] == "limit" and st.read()["api"]["reason"] == "credit"


def test_a_way_never_checked_is_due_and_a_touch_counts_as_a_check(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    assert st.due("code", 10 ** 9)
    st.touch("code")
    assert not st.due("code", 3600) and st.due("code", 0)
    assert not st.is_down("code")


def test_finding_claude_code(tmp_path, monkeypatch):
    from livetips_m0.routing import find_claude_cli
    plain = tmp_path / "claude-plain"
    plain.write_text("x")
    monkeypatch.setenv("LT_CLAUDE_CLI", "")
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("PATH", str(tmp_path / "nothing"))
    assert find_claude_cli(str(plain)) in (None, "/opt/homebrew/bin/claude", "/usr/local/bin/claude")   # not executable: skipped
    good = _cli(tmp_path, "ok")
    assert find_claude_cli(good) == good


def test_model_names_for_claude_code():
    assert cc_model("") == "sonnet" and cc_model("my-model") == "my-model" and cc_model("Claude-Opus-5") == "opus"


def test_stream_events_other_than_text_are_ignored():
    from livetips_m0.providers import Completion
    from livetips_m0.routing import cc_event
    c = Completion(t_start=0)
    assert cc_event(c, '{"type": "stream_event", "event": {"type": "message_start"}}') is None
    assert cc_event(c, '{"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "input_json_delta", "text": "no"}}}') is None
    assert cc_event(c, '{"type": "system"}') is None and cc_event(c, 'not json') is None
    assert c.text == "" and c.t_first_token is None
    cc_event(c, '{"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "{\\"a\\": 1"}}}')
    assert c.text == '{"a": 1' and c.t_first_token is not None and c.t_gist is None
    assert cc_event(c, '{"type": "result", "subtype": "success"}')["subtype"] == "success"


def test_how_a_claude_code_run_ends():
    from livetips_m0.providers import Completion
    from livetips_m0.routing import cc_finish
    assert not cc_finish(Completion(t_start=0, text="ok"), None, 0, "").error
    assert cc_finish(Completion(t_start=0), None, 0, "").error
    c = cc_finish(Completion(t_start=0), {"subtype": "success", "result": "hi"}, 0, "")
    assert c.text == "hi" and c.input_tokens == 0 and c.output_tokens == 0 and c.cache_read == 0
    assert cc_finish(Completion(t_start=0, text="x"), {"subtype": "error_max_turns"}, 0, "").error
    assert cc_finish(Completion(t_start=0, text="x"), {"subtype": "success", "is_error": True, "result": "limit"}, 0, "").error


def test_default_routed_provider_switches_and_checks_before_the_job(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    st.mark_down("api", "credit")
    rp = RoutedProvider("after", "api", {"api": ok(), "code": ok()}, state=st, probe_every=0)
    assert rp.pick() == "api" and not st.is_down("api")           # checked inline, answered, back to the key


def test_during_a_call_the_check_runs_in_the_background(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    st.mark_down("api", "credit")
    slow = Failing("APITimeoutError: still out")
    rp = RoutedProvider("tips", "api", {"api": slow, "code": ok()}, state=st, probe_every=0, background=True)
    assert rp.pick() == "code"


def test_which_ways_can_be_used(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    no_code = RoutedProvider("x", "api", {"api": ok(), "code": None}, state=st)
    assert not no_code.usable("code") and not no_code.can_run_without_api()
    assert RoutedProvider("x", "code", {"api": None, "code": ok()}, auto=False, state=st).can_run_without_api()
    assert not RoutedProvider("x", "api", {"api": ok(), "code": ok()}, auto=False, state=st).can_run_without_api()


def test_a_check_that_fails_keeps_the_way_out(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    rp = RoutedProvider("x", "api", {"api": Failing("APITimeoutError: slow"), "code": None}, state=st)
    assert rp.probe("api") is False and st.read()["api"]["reason"] == "error"
    assert rp.probe("code") is False and st.read()["code"]["reason"] == "missing"


def test_a_passing_error_neither_switches_nor_marks_the_way_out(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    code = ok()
    rp = RoutedProvider("x", "api", {"api": Failing("APITimeoutError: slow"), "code": code}, state=st, probe_every=3600)
    c = rp.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None)
    assert c.error and c.route == "api" and not st.is_down("api") and code.calls == []


def test_both_ways_out(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    rp = RoutedProvider("x", "api", {"api": Failing("BadRequestError: credit balance is too low"),
                                     "code": Failing("ClaudeCode: usage limit reached")}, state=st, probe_every=3600)
    c = rp.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None)
    assert c.error and st.read()["api"]["reason"] == "credit" and st.read()["code"]["reason"] == "limit"


def test_provider_from_cfg_reads_the_workspace_and_runs_checks_in_the_background_for_tips(tmp_path, monkeypatch):
    monkeypatch.delenv("LT_AI_ROUTE", raising=False)
    cfg = {"workspace_id_env": "WS", "ai": {"routes": {"tips": "api"}, "state": str(tmp_path / "s.json"),
                                            "claude_cli": _cli(tmp_path, "ok")}}
    secrets = {"CLAUDE_API": "sk-test", "WS": "ws-1"}

    def loader(n):
        return secrets[n]
    import livetips_m0.routing as r
    seen = {}
    monkeypatch.setattr(r, "AnthropicProvider", lambda key, timeout, workspace_id: seen.update(key=key, ws=workspace_id) or ok())
    tips = provider_from_cfg(cfg, loader)
    assert tips.auto and tips.background and seen == {"key": "sk-test", "ws": "ws-1"}
    assert not provider_from_cfg(cfg, loader, job="after").background


def test_ping_of_claude_code_that_is_not_there(tmp_path, monkeypatch, capsys):
    import json as _json
    import livetips_m0.routing as r
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "s.json"))
    monkeypatch.setattr(r, "find_claude_cli", lambda hint="": None)
    r.main(["ping", "--route", "code"])
    assert _json.loads(capsys.readouterr().out)["code"]["reason"] == "missing"


def test_a_success_brings_a_way_back(tmp_path):
    st = RouteState(str(tmp_path / "s.json"))
    st.mark_down("api", "credit")
    rp = RoutedProvider("x", "api", {"api": ok(), "code": None}, auto=False, state=st)
    assert not rp.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None).error
    assert not st.is_down("api")


def test_the_cli_path_from_the_config_and_the_tips_timeout(tmp_path, monkeypatch):
    monkeypatch.delenv("LT_AI_ROUTE", raising=False)
    cli = _cli(tmp_path, "ok")
    cfg = {"claude_cli": cli, "ai": {"routes": {"tips": "code"}, "state": str(tmp_path / "s.json")}}
    tips = provider_from_cfg(cfg, lambda n: (_ for _ in ()).throw(KeyError(n)))
    assert tips.legs["code"].cli == cli and tips.legs["code"].timeout == 60.0 and tips.preferred == "code"
    assert provider_from_cfg(cfg, lambda n: "", job="after").legs["code"].timeout == 300.0
