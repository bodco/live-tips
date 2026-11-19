"""0.24.1 (F4, the first outside user): a working Claude API key and no Claude Code. The Meeting Sheet and the
preparation go on the key in packed passes; "Claude Code is not installed" never marks the key as out. Invented names."""
import json
from pathlib import Path

from livetips_m0 import apiprep
from livetips_m0.providers import FakeProvider
from livetips_m0.routing import RouteState, out_reason

from test_sheet_pipeline_0100 import ANSWER, _project, _req  # noqa: E402
from livetips_m0.sheet import build as B  # noqa: E402


def test_missing_claude_code_is_not_an_api_outage():
    assert out_reason("api", "Claude Code is not installed") is None
    assert out_reason("code", "Claude Code is not installed") == "missing"
    assert out_reason("api", "NoRoute: no API key") == "no_key"


def test_sheet_on_the_api_key_without_claude_code(tmp_path, monkeypatch):
    root, a, b = _project(tmp_path)
    state = tmp_path / "state" / "ai-routes.json"
    (tmp_path / "state").mkdir()
    monkeypatch.setenv("LT_AI_STATE", str(state))
    monkeypatch.setattr(B, "find_claude", lambda hint=None: None)
    def never(*a, **k):
        raise AssertionError("claude -p must not run without Claude Code")
    monkeypatch.setattr(B, "run_claude", never)
    api = FakeProvider(lambda m, u: json.dumps(ANSWER))
    def provider(self):
        self.model = self.model or "claude-sonnet-5-5"
        return {"api": api}[self.route]
    monkeypatch.setattr(B.Asker, "_provider", provider)
    monkeypatch.setattr(B.Asker, "can_run", lambda self, r: True)
    res = B.build(_req(root, a, b, route="api"), emit=lambda **k: None)
    assert res.get("done"), res
    assert res["route"] == "api" and not res.get("switches")
    assert any("Claude API key in packed passes" in n for n in res["notes"])
    assert not RouteState(str(state)).is_down("api")


def test_apiprep_model_names():
    assert apiprep.model_for("sonnet") == apiprep.DEFAULT_MODEL
    assert apiprep.model_for("claude-opus-5-5") == "claude-opus-5-5"
    assert apiprep.APIPreparation.route == "api"
