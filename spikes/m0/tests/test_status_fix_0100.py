"""0.10.0 (status fix, 12.11): the ChatGPT account's limits from each Codex run's own session log (read, then that one
file removed by id), the Claude account's report on every Claude Code run, limits kept with their reset time.
The session log content below is invented, shaped like Codex 0.167's rollout-*.jsonl token_count events."""
import json
import os
import sys
import time

import pytest

from livetips_m0 import codex_provider as cp
from livetips_m0.codex_provider import CodexProvider, exec_args, forget, rollout_files, rollout_rate_limits, run_usage
from livetips_m0.providers import Completion
from livetips_m0.routing import account_usage_claude, account_usage_codex, cc_stream_result

TID = "-".join(["thread", "aaaa", "7f50", "run"])          # shaped like a thread id, not one (no real UUID here)
OTHER = "-".join(["thread", "bbbb", "7000", "other"])


def token_count(primary, secondary, reached=None):
    return {"timestamp": "2026-11-12T08:00:00.000Z", "type": "event_msg", "payload": {
        "type": "token_count", "info": None, "rate_limits": {
            "limit_id": "codex", "limit_name": None, "primary": primary, "secondary": secondary,
            "credits": {"has_credits": False, "unlimited": False, "balance": "0"}, "plan_type": "plus",
            "rate_limit_reached_type": reached}}}


def write_rollout(home, tid, events, day="2026/11/12"):
    d = os.path.join(home, "sessions", *day.split("/"))
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "rollout-2026-11-12T10-15-00-%s.jsonl" % tid)
    with open(p, "w", encoding="utf-8") as f:
        f.write(json.dumps({"type": "session_meta", "payload": {"id": tid, "originator": "codex_exec"}}) + "\n")
        f.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user",
                                                                 "content": [{"type": "input_text", "text": "call text"}]}}) + "\n")
        for e in events:
            f.write(json.dumps(e) + "\n")
    return p


P5 = {"used_percent": 42.0, "window_minutes": 300, "resets_at": 1794000000}
PW = {"used_percent": 61.0, "window_minutes": 10080, "resets_at": 1794300000}


def test_exec_args_without_ephemeral_keep_the_other_flags(monkeypatch):
    monkeypatch.setenv("LT_CODEX_EPHEMERAL", "0")      # 2026-11-12: the session log only when asked
    a = exec_args("/bin/codex")
    assert "--ephemeral" not in a and "--ignore-user-config" in a and "--skip-git-repo-check" in a and "--json" in a
    assert a[a.index("--sandbox") + 1] == "read-only" and a[-1] == "-"
    monkeypatch.delenv("LT_CODEX_EPHEMERAL", raising=False)
    assert "--ephemeral" in exec_args("/bin/codex")      # the default


def test_rate_limits_of_a_session_log(tmp_path):
    p = write_rollout(str(tmp_path), TID, [token_count({"used_percent": 10.0, "window_minutes": 300, "resets_at": 1}, None),
                                           token_count(P5, PW), token_count(None, None)])
    rl = rollout_rate_limits(p)
    assert rl["primary"] == P5 and rl["secondary"] == PW          # the last one with numbers, not the empty one
    u = account_usage_codex(rl, now=5)
    assert u == {"at": 5, "limited": False, "windows": [{"name": "five_hour", "used_percent": 42.0, "resets_at": 1794000000},
                                                        {"name": "seven_day", "used_percent": 61.0, "resets_at": 1794300000}]}
    assert rollout_rate_limits(str(tmp_path / "missing.jsonl")) is None


def test_reached_limits():
    full = {"primary": dict(P5, used_percent=100.0), "secondary": PW, "rate_limit_reached_type": None}
    assert account_usage_codex(full, now=1)["limited"] is True and account_usage_codex(full, now=1)["until"] == 1794000000
    named = {"primary": P5, "secondary": PW, "rate_limit_reached_type": "secondary"}
    assert account_usage_codex(named, now=1)["until"] == 1794300000
    ev = {"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": 1794000000,
                                                          "unifiedWindows": {"five_hour": {"utilization": 1.0, "resetsAt": 1794000000}}}}
    u = account_usage_claude(ev, now=1)
    assert u["limited"] is True and u["until"] == 1794000000


def test_forget_removes_only_that_runs_log(tmp_path):
    home = str(tmp_path)
    mine = write_rollout(home, TID, [token_count(P5, PW)])
    other = write_rollout(home, OTHER, [token_count(P5, PW)])
    fork = os.path.join(os.path.dirname(mine), "rollout-2026-11-12T10-20-00-%s_%s.jsonl" % (TID, OTHER))
    open(fork, "w").write("{}\n")
    elsewhere = tmp_path / ("rollout-2026-11-12T10-15-00-%s.jsonl" % TID)
    elsewhere.write_text("{}\n")
    for bad in ("", "*", "../" + TID, TID + "/..", "a b", None):
        assert forget(bad, home) == 0 and rollout_files(bad, home) == []
    assert rollout_files(TID, home) == [mine]
    assert forget(TID, home) == 1
    assert not os.path.exists(mine) and os.path.exists(other) and os.path.exists(fork) and elsewhere.exists()
    assert forget(TID, home) == 0


def test_run_usage_after_a_failed_run(tmp_path, monkeypatch):
    home = str(tmp_path / "codex")
    state = tmp_path / "state" / "ai-routes.json"
    state.parent.mkdir()
    monkeypatch.setenv("LT_AI_STATE", str(state))
    p = write_rollout(home, TID, [token_count(dict(P5, used_percent=100.0), PW, reached="primary")])
    c = Completion(error=cp.failure_reason("You've hit your usage limit. Upgrade to Pro (https://x) or try again at 12:48 PM."))
    u = run_usage(c, TID, home, now=1793960000)
    assert u["limited"] is True and u["until"] == 1794000000 and c.account_usage == u
    assert not os.path.exists(p)
    saved = json.loads((tmp_path / "state" / "ai-accounts.json").read_text())
    assert saved["codex"]["until"] == 1794000000 and saved["codex"]["windows"][0]["used_percent"] == 100.0
    # no session log at all (the CLI failed before writing one): the error's own reset time is kept
    c2 = Completion(error=cp.failure_reason("You've hit your usage limit ... try again at 12:48 PM."))
    u2 = run_usage(c2, OTHER, home, now=time.time())
    assert u2["limited"] is True and u2["windows"] == [] and u2["until"] > time.time() and c2.reset_at == u2["until"]


FAKE = r'''
import json, os, sys
args = sys.argv[1:]
if 'login' in args:
    print('Logged in using ChatGPT', file=sys.stderr)
    sys.exit(0)
assert '--ephemeral' not in args and '--ignore-user-config' in args
sys.stdin.read()
tid = os.environ['FAKE_TID']
mode = os.environ.get('FAKE_MODE', 'ok')
home = os.environ['CODEX_HOME']
d = os.path.join(home, 'sessions', '2026', '11', '12')
os.makedirs(d, exist_ok=True)
print(json.dumps({'type': 'thread.started', 'thread_id': tid}), flush=True)
reached = 'primary' if mode == 'limit' else None
used = 100.0 if mode == 'limit' else 42.0
with open(os.path.join(d, 'rollout-2026-11-12T10-15-00-%s.jsonl' % tid), 'w') as f:
    f.write(json.dumps({'type': 'event_msg', 'payload': {'type': 'token_count', 'rate_limits': {
        'primary': {'used_percent': used, 'window_minutes': 300, 'resets_at': 1794000000},
        'secondary': {'used_percent': 61.0, 'window_minutes': 10080, 'resets_at': 1794300000},
        'rate_limit_reached_type': reached}}}) + '\n')
print(json.dumps({'type': 'turn.started'}), flush=True)
if mode == 'limit':
    print(json.dumps({'type': 'error', 'message': "You've hit your usage limit. Try again at 12:48 PM."}))
    print(json.dumps({'type': 'turn.failed', 'error': {'message': "You've hit your usage limit. Try again at 12:48 PM."}}))
    sys.exit(1)
print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'OK'}}))
print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 10, 'cached_input_tokens': 0, 'output_tokens': 1}}))
'''


@pytest.mark.parametrize("mode", ["ok", "limit"])
def test_provider_reads_and_removes_its_own_log(tmp_path, monkeypatch, mode):
    monkeypatch.setenv("LT_CODEX_EPHEMERAL", "0")      # 2026-11-12: the default is --ephemeral; this path is opt-in
    cli = tmp_path / "codex"
    cli.write_text("#!" + sys.executable + "\n" + FAKE)
    cli.chmod(0o700)
    home = tmp_path / "home"
    keep = write_rollout(str(home), OTHER, [token_count(P5, PW)])          # the PM's own session: never touched
    monkeypatch.setenv("CODEX_HOME", str(home))
    monkeypatch.setenv("FAKE_TID", TID)
    monkeypatch.setenv("FAKE_MODE", mode)
    monkeypatch.delenv("LT_AI_STATE", raising=False)
    c = CodexProvider(str(cli), timeout=10).complete(model="m", system=[{"text": "rules"}], user="q", max_tokens=10, cache_ttl=None)
    assert rollout_files(TID, str(home)) == [] and os.path.exists(keep)
    u = c.account_usage
    assert [w["name"] for w in u["windows"]] == ["five_hour", "seven_day"]
    if mode == "ok":
        assert c.error is None and c.text == "OK" and u["limited"] is False
    else:
        assert "usage limit" in c.error and u["limited"] is True and u["until"] == 1794000000


def test_claude_stream_result_and_old_json():
    ev = {"type": "rate_limit_event", "rate_limit_info": {"status": "allowed", "unifiedWindows": {
        "five_hour": {"utilization": 0.2, "resetsAt": 1794000000}, "seven_day": {"utilization": 0.5, "resetsAt": 1794300000}}}}
    out = "\n".join(json.dumps(x) for x in [{"type": "system", "subtype": "init"}, ev,
                                             {"type": "result", "result": "{\"answered\": true}", "total_cost_usd": 0.01}])
    res, usage = cc_stream_result(out)
    assert res["result"] == "{\"answered\": true}" and usage["windows"][1]["used_percent"] == 50.0
    res, usage = cc_stream_result(json.dumps({"type": "result", "result": "x"}))
    assert res["result"] == "x" and usage is None
    assert cc_stream_result("") == ({}, None)


def test_lookup_and_checker_note_the_claude_account(tmp_path, monkeypatch):
    from livetips_m0 import deep, prepverify as pv
    ev = {"type": "rate_limit_event", "rate_limit_info": {"status": "allowed", "unifiedWindows": {
        "five_hour": {"utilization": 0.3, "resetsAt": 1794000000}}}}
    out = json.dumps(ev) + "\n" + json.dumps({"type": "result", "result": "{\"answered\": true, \"gist\": \"g\"}", "total_cost_usd": 0})
    st = tmp_path / "s" / "ai-routes.json"
    st.parent.mkdir()
    deep.note_usage({"ai": {"state": str(st)}}, out, account=False)
    assert not (tmp_path / "s" / "ai-accounts.json").exists()             # an API key run: not the account
    deep.note_usage({"ai": {"state": str(st)}}, out, account=True)
    assert json.loads((tmp_path / "s" / "ai-accounts.json").read_text())["code"]["windows"][0]["used_percent"] == 30.0
    assert deep.read_result(out, 0)["answered"] is True
    assert "stream-json" in deep.deep_args({}, "/bin/claude", "q", [], "English")
    assert "stream-json" in pv.command({"claude": "/bin/claude", "root": "", "extra": [], "base": str(tmp_path / "b"),
                                         "python": "/p", "engine_dir": "/e"}, "prompt", "sonnet")
