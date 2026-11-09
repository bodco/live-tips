"""0.9.6: monthly limits per provider (Claude, OpenAI, Gemini) from the spend ledger; the router stops at them."""
import json
import time

from livetips_m0.cost import ProviderCaps
from livetips_m0.providers import Completion, Provider
from livetips_m0.routing import RoutedProvider, RouteState


def ledger(tmp_path, rows):
    p = tmp_path / "spend-ledger.jsonl"
    p.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
    return p


def now(day="10"):
    return time.strftime("%Y-%m-") + day + "T10:00:00+0200"


def test_month_sum_by_provider(tmp_path):
    p = ledger(tmp_path, [{"at": now(), "route": "api", "usd": 1.5}, {"at": now("11"), "route": "api", "usd": 1.0},
                          {"at": now(), "route": "openai", "usd": 0.4}, {"at": now(), "route": "code", "usd": 9.0},
                          {"at": "2001-01-01T10:00:00", "route": "api", "usd": 50.0}, {"at": now(), "route": "gemini", "usd": None}])
    c = ProviderCaps({"claude": 2.5, "openai": 1.0, "gemini": 0}, p)
    assert c.month_spent() == {"claude": 2.5, "openai": 0.4, "gemini": 0.0}
    assert c.capped("claude") and not c.capped("openai") and not c.capped("gemini")
    assert c.capped_route("api") and not c.capped_route("code")


def test_cache_and_missing_ledger(tmp_path):
    t = [0.0]
    c = ProviderCaps({"claude": 1.0}, tmp_path / "none.jsonl", ttl=30, clock=lambda: t[0])
    assert not c.capped("claude")
    ledger(tmp_path, [{"at": now(), "route": "api", "usd": 2.0}])
    c.path = tmp_path / "spend-ledger.jsonl"
    assert not c.capped("claude")          # cached
    t[0] = 31
    assert c.capped("claude")


def test_from_cfg(tmp_path, monkeypatch):
    st = tmp_path / "ai-routes.json"
    assert ProviderCaps.from_cfg({"provider_caps": {"claude": 0}}) is None
    c = ProviderCaps.from_cfg({"provider_caps": {"claude": 3}, "ai": {"state": str(st)}})
    assert c.path == tmp_path / "spend-ledger.jsonl"
    monkeypatch.setenv("LT_PROVIDER_CAPS", '{"openai": 2}')
    monkeypatch.setenv("LT_AI_STATE", str(st))
    assert ProviderCaps.from_cfg({}).caps == {"openai": 2.0}


class Leg(Provider):
    name = "leg"

    def __init__(self, tag):
        self.tag, self.calls = tag, 0

    def complete(self, **kw):
        self.calls += 1
        return Completion(model=self.tag, t_start=0, t_done=0, text="ok")


def test_router_stops_at_the_limit_and_switches(tmp_path):
    p = ledger(tmp_path, [{"at": now(), "route": "api", "usd": 5.0}])
    api, code = Leg("api"), Leg("code")
    st = RouteState(str(tmp_path / "ai-routes.json"))
    caps = ProviderCaps({"claude": 4.0}, p)
    r = RoutedProvider("prep", "api", {"api": api, "code": code}, auto=True, state=st, caps=caps)
    c = r.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None)
    assert c.route == "code" and api.calls == 0                       # auto-switch to the account
    r2 = RoutedProvider("prep", "api", {"api": api, "code": code}, auto=False, state=st, caps=caps)
    c2 = r2.complete(model="m", system=[], user="u", max_tokens=5, cache_ttl=None)
    assert api.calls == 0 and "monthly limit for Claude" in c2.error
    assert not st.is_down("api")                                       # a limit is not an outage
