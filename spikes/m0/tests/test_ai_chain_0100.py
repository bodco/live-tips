"""0.10.0 (AI chain, owner 12.11): one fallback chain for every job, the switch on runtime failures (a limit, no
credit, a bad key, signed out; never a plain rate limit or a timeout), the out state until the reset time, the
accounts' own usage reports, and the Meeting Sheet build switching mid-build. Invented names only."""
import datetime as dt
import json
import time
from pathlib import Path

from livetips_m0 import codex_provider as CP
from livetips_m0.providers import Completion, FakeProvider, Provider
from livetips_m0.routing import (RouteState, RoutedProvider, account_usage_claude, account_usage_codex, chain_from,
                                 chain_order, note_account_usage, out_reason, provider_from_cfg, reset_time)

ALL = {"code", "codex", "api", "openai", "gemini", "agy", "local"}
CHAIN = ["code", "codex", "api", "openai", "gemini", "agy", "local"]
CODEX_LIMIT = ("You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit "
               "https://chatgpt.com/settings/usage to purchase more credits or try again at 12:48 PM.")


class Failing(Provider):
    def __init__(self, error):
        self.error = error
        self.calls = 0

    def complete(self, *, model, system, user, max_tokens, cache_ttl, on_text=None, extra=None):
        self.calls += 1
        return Completion(model=model, t_start=time.monotonic(), t_done=time.monotonic(), error=self.error)


def ok(text="{}"):
    return FakeProvider(lambda m, u: text)


def ask(rp):
    return rp.complete(model="m", system=[{"text": "s"}], user="u", max_tokens=10, cache_ttl=None)


def test_chain_order_matches_the_app():
    assert chain_order("prep", "api", CHAIN, ALL) == ["api", "code", "codex", "openai", "gemini", "agy", "local"]
    assert chain_order("tips", "api", CHAIN, ALL) == ["api", "code", "codex", "openai", "gemini"]
    assert chain_order("after", "code", ["local", "gemini"], ALL) == ["code", "gemini", "local"]   # local always last
    assert chain_order("after", "code", CHAIN, ALL, auto=False) == ["code"]
    assert chain_order("tips", "openai", CHAIN, {"openai", "api"}) == ["openai", "api"]
    assert chain_from('["code","x","api"]') == ["code", "api"] and chain_from(None) is None and chain_from("[]") == []


def test_reset_times():
    now = dt.datetime(2026, 11, 12, 10, 15).timestamp()
    t = dt.datetime.fromtimestamp(reset_time(CODEX_LIMIT, now))
    assert (t.hour, t.minute, t.date()) == (12, 48, dt.date(2026, 11, 12))
    t = dt.datetime.fromtimestamp(reset_time("5-hour limit reached ∙ resets 9am", now))
    assert (t.hour, t.date()) == (9, dt.date(2026, 11, 13))
    assert reset_time("try again in 2 hours 5 minutes", now) == now + 7500
    assert reset_time("Claude AI usage limit reached|1793977200", now) == 1793977200
    assert reset_time("RateLimitError: 429", now) is None and reset_time("resets 5 things", now) is None


def test_runtime_failures_that_switch():
    assert out_reason("codex", "Codex: usage limit reached (try again at 12:48 pm)") == "limit"
    assert out_reason("openai", "OpenAI: HTTP 429 insufficient_quota") == "credit"
    assert out_reason("openai", "OpenAI: HTTP 429 rate_limit_exceeded") is None        # a plain rate limit: no switch
    assert out_reason("gemini", "Gemini: HTTP 429 RESOURCE_EXHAUSTED quota_exceeded") == "credit"
    assert out_reason("api", "AuthenticationError: invalid x-api-key") == "auth"
    assert out_reason("code", "ClaudeCode: Please run /login") == "auth"
    assert out_reason("api", "APITimeoutError: Request timed out.") is None


def test_codex_limit_message_keeps_only_the_reset_part():
    r = CP.failure_reason(CODEX_LIMIT)
    assert r == "Codex: usage limit reached (try again at 12:48 pm)" and "chatgpt.com" not in r


def test_chosen_codex_out_goes_down_the_chain_marked_until_reset(tmp_path):
    st = RouteState(str(tmp_path / "ai-routes.json"))
    codex = Failing("Codex: usage limit reached (try again at 12:48 pm)")
    api = ok('{"gist":"x"}')
    rp = RoutedProvider("after", "codex", {"codex": codex, "code": None, "api": api}, state=st, chain=CHAIN)
    c = ask(rp)
    assert not c.error and c.route == "api" and c.switched_from == "codex"
    s = st.read()["codex"]
    assert s["down"] and s["reason"] == "limit" and s["until"] > time.time()
    assert not st.due("codex", 0)                        # out until the reset time, not every check interval
    sw = [json.loads(x) for x in (tmp_path / "ai-switches.jsonl").read_text().splitlines()]
    assert sw[-1]["from"] == "codex" and sw[-1]["to"] == "api" and sw[-1]["reason"] == "limit"
    # the next job goes straight to the API; the reset time passes, the ChatGPT account answers, the job goes back
    ask(rp)
    assert codex.calls == 1
    d = st.read(); d["codex"]["until"] = time.time() - 1; st._write(d)
    rp.legs["codex"] = ok()
    c = ask(rp)
    assert c.route == "codex" and not st.is_down("codex")


def test_plain_rate_limit_does_not_switch_and_tips_never_go_local(tmp_path):
    st = RouteState(str(tmp_path / "r.json"))
    rp = RoutedProvider("after", "openai", {"openai": Failing("OpenAI: HTTP 429 rate_limit_exceeded"), "api": ok()},
                        state=st, chain=CHAIN)
    c = ask(rp)
    assert c.error and c.route == "openai" and not st.is_down("openai")
    local = ok()
    tips = RoutedProvider("tips", "api", {"api": Failing("BadRequestError: credit balance is too low"), "local": local,
                                          "agy": ok()}, state=RouteState(str(tmp_path / "t.json")), chain=CHAIN,
                          background=True)
    c = ask(tips)
    assert c.error and local.calls == [] and tips.order() == ["api"]


def test_local_is_the_last_step_for_jobs_but_switched_off_ai_is_skipped(tmp_path):
    st = RouteState(str(tmp_path / "r.json"))
    gem = ok()
    rp = RoutedProvider("prep", "code", {"code": Failing("ClaudeCode: usage limit reached"), "gemini": gem,
                                         "local": ok()}, state=st, chain=["local", "code", "api"])
    c = ask(rp)
    assert c.route == "local" and gem.calls == []        # gemini is off in the PM's list; local comes last
    assert rp.order() == ["code", "local"]


def test_old_app_without_chain_keeps_the_old_rules(tmp_path):
    st = RouteState(str(tmp_path / "r.json"))
    rp = RoutedProvider("after", "openai", {"openai": Failing("OpenAI: HTTP 401"), "api": ok()}, state=st)
    c = ask(rp)
    assert c.error and c.route == "openai"


def test_provider_from_cfg_reads_the_chain(tmp_path):
    cfg = {"ai": {"routes": {"tips": "api"}, "auto": True, "state": str(tmp_path / "s.json"), "chain": ["code", "local"]}}
    p = provider_from_cfg(cfg, lambda n: "", job="tips", env_route=False)
    assert p.chain == ["code", "local"]


def test_account_usage_reports(tmp_path):
    ev = {"type": "rate_limit_event", "rate_limit_info": {"status": "allowed_warning", "unifiedWindows": {
        "five_hour": {"utilization": 0.1, "resetsAt": 1793977200}, "seven_day": {"utilization": 0.81, "resetsAt": 1794063600}}}}
    u = account_usage_claude(ev, now=1)
    assert u == {"at": 1, "limited": False, "windows": [{"name": "five_hour", "used_percent": 10.0, "resets_at": 1793977200},
                                                        {"name": "seven_day", "used_percent": 81.0, "resets_at": 1794063600}]}
    rl = {"primary": {"used_percent": 12.0, "window_minutes": 300, "resets_at": 5}, "secondary": {"used_percent": 54.0,
          "window_minutes": 10080, "resets_at": 6}, "rate_limit_reached_type": None}
    assert [w["name"] for w in account_usage_codex(rl, now=1)["windows"]] == ["five_hour", "seven_day"]
    sp = str(tmp_path / "ai-routes.json")
    note_account_usage("code", u, sp)
    note_account_usage("codex", account_usage_codex(rl, now=1), sp)
    d = json.loads((tmp_path / "ai-accounts.json").read_text())
    assert set(d) == {"code", "codex"} and d["code"]["windows"][1]["used_percent"] == 81.0
    # Claude Code's stream line lands on the completion; Codex events carry rate_limits anywhere
    from livetips_m0.routing import cc_event
    c = Completion()
    cc_event(c, json.dumps(ev))
    assert c.account_usage["windows"][0]["name"] == "five_hour"
    c2 = Completion()
    CP.apply_event(c2, {"type": "event_msg", "payload": {"type": "token_count", "rate_limits": rl}}, None)
    assert c2.account_usage["windows"][1]["used_percent"] == 54.0


# ---------------------------------------------------------------- the Meeting Sheet build

from test_sheet_pipeline_0100 import ANSWER, _project, _req  # noqa: E402
from livetips_m0.sheet import build as B  # noqa: E402


def _fake_providers(monkeypatch, by_route):
    def provider(self):
        self.model = self.model or "m"
        return by_route[self.route]
    monkeypatch.setattr(B.Asker, "_provider", provider)
    monkeypatch.setattr(B.Asker, "can_run", lambda self, r: True)


def test_build_switches_a_failed_pass_to_the_next_ai(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "state" / "ai-routes.json"))
    (tmp_path / "state").mkdir()
    gem = FakeProvider(lambda m, u: json.dumps(ANSWER))
    _fake_providers(monkeypatch, {"codex": Failing(CP.failure_reason(CODEX_LIMIT)), "gemini": gem})
    lines = []
    res = B.build(_req(root, a, b, route="codex", chain=["codex", "gemini", "local"], models={"gemini": "gemini-3.8-flash"}),
                  emit=lambda **k: lines.append(k))
    assert res.get("done"), res
    assert res["route"] == "gemini" and res["switches"][0]["from"] == "codex" and res["switches"][0]["reason"] == "limit"
    assert any(l.get("stage") == "switch" and l.get("to") == "gemini" for l in lines)
    sheet = json.loads(Path(res["sheet"]).read_text(encoding="utf-8"))
    assert sheet["route"] == "gemini" and sheet["route_switches"][0]["to"] == "gemini"
    assert any("Switched from codex to gemini" in n for n in res["notes"])
    st = json.loads((tmp_path / "state" / "ai-routes.json").read_text())
    assert st["codex"]["down"] and st["codex"]["until"] > time.time()


def test_build_on_claude_out_goes_on_packed_on_the_next_ai(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    monkeypatch.setenv("LT_AI_STATE", str(tmp_path / "ai-routes.json"))
    def no_claude(*a, **k):
        raise RuntimeError("Claude AI usage limit reached|%d" % int(time.time() + 3600))
    monkeypatch.setattr(B, "run_claude", no_claude)
    _fake_providers(monkeypatch, {"openai": FakeProvider(lambda m, u: json.dumps(ANSWER))})
    res = B.build(_req(root, a, b, route="code", chain=["openai"]), emit=lambda **k: None)
    assert res.get("done"), res
    assert res["route"] == "openai" and res["switches"][0]["from"] == "code"


def test_build_without_a_next_ai_reports_the_outage(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    monkeypatch.setattr(B, "run_claude", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("ClaudeCode: usage limit reached")))
    res = B.build(_req(root, a, b, route="code"), emit=lambda **k: None)
    assert res["code"] == 5 and res["out"] == "limit"
