"""0.10.0 (owner 12.11): the light usage probe of the Claude and ChatGPT accounts (livetips_m0.usage_probe), with fakes:
no real model request. The numbers below are invented."""
import json
import os
import subprocess
import sys
from types import SimpleNamespace

import pytest

from livetips_m0 import usage_probe as up
from livetips_m0.codex_provider import exec_args, rollout_files
from test_status_fix_0100 import FAKE, OTHER, P5, PW, TID, token_count, write_rollout


def rl_event(five=0.21, week=0.48, status="allowed"):
    return {"type": "rate_limit_event", "rate_limit_info": {"status": status, "unifiedWindows": {
        "five_hour": {"utilization": five, "resetsAt": 1794000000}, "seven_day": {"utilization": week, "resetsAt": 1794300000}}}}


def fake_run(events, rc=0, seen=None):
    def run(args, **kw):
        if seen is not None:
            seen.update(args=args, input=kw.get("input"), env=kw.get("env"), cwd=kw.get("cwd"))
        return SimpleNamespace(returncode=rc, stdout="\n".join(json.dumps(e) for e in events), stderr="")
    return run


def test_claude_probe_is_tiny_and_notes_the_account(tmp_path, monkeypatch):
    monkeypatch.setenv("CLAUDE_API", "dummy-secret")
    state = tmp_path / "state" / "ai-routes.json"
    seen = {}
    events = [{"type": "system", "subtype": "init"}, rl_event(),
              {"type": "result", "subtype": "success", "result": "OK", "total_cost_usd": 0.0004,
               "usage": {"input_tokens": 9, "output_tokens": 2, "cache_read_input_tokens": 3}}]
    out = up.probe_claude("/bin/claude", str(state), run=fake_run(events, seen=seen))
    a = seen["args"]
    assert a[a.index("--model") + 1] == "haiku" and a[a.index("--max-turns") + 1] == "1"
    assert a[a.index("--tools") + 1] == "" and "stream-json" in a and "--verbose" in a and "--no-session-persistence" in a
    assert seen["input"] == "Reply with OK" and "CLAUDE_API" not in seen["env"]
    assert out["ok"] is True and [w["used_percent"] for w in out["windows"]] == [21.0, 48.0]
    acc = json.loads((tmp_path / "state" / "ai-accounts.json").read_text())
    assert acc["code"]["windows"][0]["used_percent"] == 21.0
    row = json.loads((tmp_path / "state" / "spend-ledger.jsonl").read_text().splitlines()[-1])
    assert row["job"] == "usage_probe" and row["route"] == "code" and row["usd"] is None
    assert (row["input"], row["output"], row["cache_read"]) == (9, 2, 3)
    assert "OK" not in json.dumps(out)                    # numbers only, never the reply


def test_claude_probe_signed_out_or_missing(tmp_path):
    state = tmp_path / "ai-routes.json"
    out = up.probe_claude("/bin/claude", str(state), run=fake_run(
        [{"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in. Please run /login"}], rc=1))
    assert out["ok"] is False and out["error"] == "auth"
    assert not (tmp_path / "ai-accounts.json").exists()
    assert up.probe_claude(None, str(state))["error"] == "not_installed"

    def boom(*a, **k):
        raise subprocess.TimeoutExpired("claude", 1)
    assert up.probe_claude("/bin/claude", str(state), run=boom)["error"] == "timeout"


def test_claude_probe_reports_a_reached_limit(tmp_path):
    state = tmp_path / "ai-routes.json"
    out = up.probe_claude("/bin/claude", str(state), run=fake_run([rl_event(five=1.0, status="rejected"),
                                                                 {"type": "result", "subtype": "success", "is_error": True,
                                                                  "result": "5-hour limit reached"}], rc=1))
    assert out["limited"] is True and out["until"] == 1794300000     # the later window reset (routing.account_usage_claude)
    assert json.loads((tmp_path / "ai-accounts.json").read_text())["code"]["limited"] is True


@pytest.fixture
def codex_cli(tmp_path, monkeypatch):
    cli = tmp_path / "codex"
    cli.write_text("#!" + sys.executable + "\n" + FAKE)      # asserts that the run is NOT --ephemeral
    cli.chmod(0o700)
    home = tmp_path / "home"
    monkeypatch.setenv("CODEX_HOME", str(home))
    monkeypatch.setenv("FAKE_TID", TID)
    monkeypatch.delenv("LT_AI_STATE", raising=False)
    monkeypatch.delenv("LT_CODEX_EPHEMERAL", raising=False)   # real jobs: --ephemeral by default
    return str(cli), home


@pytest.mark.parametrize("mode", ["ok", "limit"])
def test_codex_probe_keeps_then_removes_only_its_own_log(tmp_path, monkeypatch, codex_cli, mode):
    cli, home = codex_cli
    monkeypatch.setenv("FAKE_MODE", mode)
    keep = write_rollout(str(home), OTHER, [token_count(P5, PW)])       # the PM's own session: never touched
    state = tmp_path / "state" / "ai-routes.json"
    out = up.probe_codex(cli, str(state), timeout=10)
    assert rollout_files(TID, str(home)) == [] and os.path.exists(keep)
    acc = json.loads((tmp_path / "state" / "ai-accounts.json").read_text())["codex"]
    assert [w["name"] for w in acc["windows"]] == ["five_hour", "seven_day"]
    if mode == "ok":
        assert out["ok"] is True and out["windows"][0]["used_percent"] == 42.0 and acc["limited"] is False
        row = json.loads((tmp_path / "state" / "spend-ledger.jsonl").read_text().splitlines()[-1])
        assert row["job"] == "usage_probe" and row["route"] == "codex" and row["usd"] is None and row["output"] == 1
    else:
        assert out["limited"] is True and acc["until"] == 1794000000
    assert "--ephemeral" in exec_args(cli)                       # the real jobs are unchanged


def test_codex_probe_signed_out(tmp_path):
    cli = tmp_path / "codex"
    cli.write_text("#!" + sys.executable + "\nimport sys\nprint('Not logged in', file=sys.stderr)\nsys.exit(1)\n")
    cli.chmod(0o700)
    state = tmp_path / "ai-routes.json"
    out = up.probe_codex(str(cli), str(state), timeout=10)
    assert out["ok"] is False and out["error"] == "signed_out"
    assert not (tmp_path / "ai-accounts.json").exists() and not (tmp_path / "spend-ledger.jsonl").exists()
