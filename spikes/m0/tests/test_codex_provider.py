"""A fake Codex executable verifies the real subprocess boundary without making model requests."""
import json
import os
import sys
import time

import pytest

from livetips_m0.codex_provider import CodexProvider, account_env, exec_args, find_codex_cli
from livetips_m0.providers import Completion
from livetips_m0.routing import RouteState, RoutedProvider, make_legs, other, out_reason


SCRIPT = r'''
import json, os, sys, time
args = sys.argv[1:]
assert 'forced_login_method="chatgpt"' in args
assert not any(k in os.environ for k in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'CLAUDE_API'))
mode = os.environ.get('PACENOTE_TEST_MODE', 'ok')
if 'login' in args:
    print('Logged in using an API key' if mode == 'api' else 'Logged in using ChatGPT', file=sys.stderr)
    sys.exit(0)
prompt = sys.stdin.read()
assert prompt.startswith('rules\n\n'.replace('\\n', '\n')) or 'rules' in prompt
assert '--ignore-user-config' in args and '--sandbox' in args
assert args[args.index('--sandbox') + 1] == 'read-only'
assert 'features.shell_tool=false' in args and 'features.multi_agent=false' in args
assert 'web_search="disabled"' in args and 'features.plugins=false' in args
if mode == 'timeout':
    time.sleep(5)
if mode == 'malformed':
    print('not json')
    sys.exit(0)
if mode == 'failed':
    print(json.dumps({'type': 'turn.failed', 'error': {'message': 'Usage limit reached; private text'}}))
    sys.exit(1)
for text in ['{"gist":', '{"gist":"Ready"}']:
    print(json.dumps({'type': 'item.updated', 'item': {'type': 'agent_message', 'text': text}}), flush=True)
print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': '{"gist":"Ready"}'}}))
if mode != 'incomplete':
    print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 100, 'cached_input_tokens': 40, 'output_tokens': 20}}))
'''


@pytest.fixture
def cli(tmp_path):
    path = tmp_path / "codex"
    path.write_text("#!" + sys.executable + "\n" + SCRIPT)
    path.chmod(0o700)
    return str(path)


def complete(cli, timeout=2, on_text=None):
    return CodexProvider(cli, timeout=timeout).complete(model="claude-sonnet-5-5", system=[{"text": "rules"}],
                                                       user="question", max_tokens=700, cache_ttl=None, on_text=on_text)


def test_account_process_stream_and_usage(cli, monkeypatch):
    for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CLAUDE_API"):
        monkeypatch.setenv(key, "dummy-secret")
    pieces = []
    result = complete(cli, on_text=pieces.append)
    assert result.error is None and result.text == '{"gist":"Ready"}'
    assert result.route == "codex" and result.model == "codex/default"
    assert (result.input_tokens, result.cache_read, result.output_tokens) == (60, 40, 20)
    assert pieces == ['{"gist":', '{"gist":"Ready"}']
    assert result.t_first_token and result.t_gist and result.t_done


@pytest.mark.parametrize("mode,expected", [("api", "not logged in"), ("failed", "usage limit"),
                                           ("malformed", "JSONDecodeError"), ("incomplete", "incomplete"),
                                           ("timeout", "timed out")])
def test_errors_and_key_auth_rejection(cli, monkeypatch, mode, expected):
    monkeypatch.setenv("PACENOTE_TEST_MODE", mode)
    started = time.monotonic()
    result = complete(cli, timeout=0.4 if mode == "timeout" else 2)
    assert expected in result.error
    assert "private text" not in result.error and time.monotonic() - started < 3


def test_discovery_and_account_environment(cli, monkeypatch):
    monkeypatch.setenv("LT_CODEX_CLI", cli)
    assert find_codex_cli() == cli and find_codex_cli(cli) == cli
    assert account_env({"OPENAI_API_KEY": "secret", "PATH": "/bin", "CODEX_HOME": "/tmp/login"}) == {
        "PATH": "/bin", "CODEX_HOME": "/tmp/login"}
    assert exec_args(cli)[-1] == "-"


def test_route_isolation_and_plan_accounting(cli, tmp_path, monkeypatch):
    monkeypatch.setenv("LT_CODEX_CLI", cli)
    monkeypatch.setenv("LT_LOCAL_FALLBACK", "1")
    legs = make_legs("", "", None, 1, 2)
    rp = RoutedProvider("after", "codex", legs, state=RouteState(str(tmp_path / "routes.json")))
    assert other("codex") == "codex" and not rp.auto and rp.can_run_without_api()
    result = rp.complete(model="claude-sonnet-5-5", system=[{"text": "rules"}], user="question", max_tokens=700, cache_ttl=None)
    assert not result.error and result.route == "codex"
    row = json.loads((tmp_path / "spend-ledger.jsonl").read_text())
    assert row["model"] == "codex/default" and row["usd"] is None
    monkeypatch.setenv("PACENOTE_TEST_MODE", "failed")
    assert "usage limit" in complete(cli).error
    assert out_reason("codex", "Codex: usage limit reached") == "limit"
    assert out_reason("codex", "Codex: not logged in with ChatGPT") == "auth"


def test_missing_usage_is_zero_and_non_message_events_are_ignored():
    from livetips_m0.codex_provider import apply_event
    result = Completion()
    apply_event(result, {"type": "item.completed", "item": {"type": "reasoning", "text": "private reasoning"}}, None)
    apply_event(result, {"type": "turn.completed"}, None)
    assert (result.input_tokens, result.cache_read, result.output_tokens) == (0, 0, 0)
    assert result.text == "" and result.t_first_token is None
    assert result.stop_reason == "turn.completed"


def test_missing_cli_never_switches_to_claude(tmp_path):
    provider = RoutedProvider("after", "codex", {"codex": None}, state=RouteState(str(tmp_path / "s.json")))
    result = provider.complete(model="m", system=[], user="x", max_tokens=10, cache_ttl=None)
    assert result.error == "NoRoute: Codex CLI is not installed"
    assert not provider.can_run_without_api()
