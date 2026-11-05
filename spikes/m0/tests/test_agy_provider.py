"""Gemini account through Antigravity CLI (agy): call contract, isolation, plan B; no network, no real CLI."""
import json
import os
import subprocess
from pathlib import Path

import pytest

from livetips_m0 import agyprep
from livetips_m0.agy_provider import AgyProvider, MODEL, account_env, forget, job_model
from livetips_m0.cost import cost_usd
from livetips_m0.providers import Completion
from livetips_m0.routing import RouteState, RoutedProvider, out_reason


class Run:
    def __init__(self, stdout="", stderr="", returncode=0, write=None):
        self.stdout, self.stderr, self.returncode, self.write = stdout, stderr, returncode, write
        self.calls = []

    def __call__(self, args, **kw):
        self.calls.append(dict(kw, args=args, files=os.listdir(kw["cwd"])))
        if self.write:
            self.write()
        return subprocess.CompletedProcess(args, self.returncode, self.stdout, self.stderr)


def envelope(**kw):
    base = {"conversation_id": "abc-123", "status": "SUCCESS", "response": '{"gist":"Ready"}',
            "usage": {"input_tokens": 22000, "output_tokens": 20, "thinking_tokens": 5, "cache_read_tokens": 8000}}
    base.update(kw)
    return json.dumps(base)


def ask(p, model="claude-sonnet-5-5"):
    return p.complete(model=model, system=[{"text": "rules"}], user=[{"text": "question"}], max_tokens=300, cache_ttl="1h")


def test_one_request_runs_isolated_on_the_account(monkeypatch, tmp_path):
    monkeypatch.setenv("GEMINI_API_KEY", "test-key")
    monkeypatch.setenv("CLAUDE_API", "test-claude")
    run = Run(envelope())
    monkeypatch.setattr(subprocess, "run", run)
    c = ask(AgyProvider("/bin/agy", timeout=120, state_dir=tmp_path))
    call = run.calls[0]
    assert c.error is None and c.text == '{"gist":"Ready"}' and c.model == "agy/" + MODEL and c.route == "agy"
    assert call["args"] == ["/bin/agy", "--output-format", "json", "--sandbox", "--disable-slash-commands",
                            "--model", MODEL, "--print-timeout", "120s"]
    assert "-p" not in call["args"] and "question" in call["input"] and "rules" in call["input"]   # prompt on stdin
    assert call["files"] == [] and "pacenote-agy-" in call["cwd"]               # an empty folder, nothing to read
    assert "GEMINI_API_KEY" not in call["env"] and "CLAUDE_API" not in call["env"]   # the account pays, never a key
    assert (c.input_tokens, c.cache_read, c.output_tokens, c.reasoning_tokens) == (22000, 8000, 25, 5)
    assert cost_usd(c.model, c.input_tokens, 0, 0, c.cache_read, c.output_tokens) is None    # paid by the plan


def test_an_account_model_id_is_used_as_given():
    assert job_model("prep") == job_model("after") == "gemini-3.8-flash-medium"
    assert job_model("after", "gemini-4-argon-high") == "gemini-4-argon-high"
    assert job_model("after", "gemini-3.8-flash") == MODEL        # an API id is not an agy id


@pytest.mark.parametrize("env,error", [
    (dict(response="", denied_actions=[{"action": "read_file"}]), "Gemini account: a tool was denied"),
    (dict(response="  "), "Gemini account: empty answer"),
    (dict(status="ERROR", response="partial"), "Gemini account: request failed"),
])
def test_a_denied_tool_or_an_empty_answer_is_never_a_good_answer(monkeypatch, tmp_path, env, error):
    monkeypatch.setattr(subprocess, "run", Run(envelope(**env)))
    assert ask(AgyProvider("/bin/agy", state_dir=tmp_path)).error == error


@pytest.mark.parametrize("stderr,error", [
    ("Error: authentication required, run agy", "Gemini account: not signed in"),
    ("quota exceeded for this account", "Gemini account: usage limit reached"),
    ("something odd with the call text inside", "Gemini account: request failed"),
])
def test_failures_name_the_kind_never_stderr(monkeypatch, tmp_path, stderr, error):
    monkeypatch.setattr(subprocess, "run", Run("", stderr, 1))
    c = ask(AgyProvider("/bin/agy", state_dir=tmp_path))
    assert c.error == error and "call text" not in c.error
    assert out_reason("agy", c.error) == {"Gemini account: not signed in": "auth",
                                          "Gemini account: usage limit reached": "limit"}.get(error)


def test_timeout_and_missing_cli(monkeypatch, tmp_path):
    def slow(*a, **k):
        raise subprocess.TimeoutExpired("agy", 1)
    monkeypatch.setattr(subprocess, "run", slow)
    assert ask(AgyProvider("/bin/agy", state_dir=tmp_path)).error == "Gemini account: request timed out"
    assert ask(AgyProvider(None)).error == "Gemini account: Antigravity CLI is not installed"


def test_the_conversation_copy_is_removed_and_only_it(monkeypatch, tmp_path):
    keep = tmp_path / "brain" / "other-1"
    keep.mkdir(parents=True)
    (tmp_path / "annotations").mkdir()
    (tmp_path / "annotations" / "other-1.pbtxt").write_text("x")

    def agy_writes():
        (tmp_path / "brain" / "abc-123").mkdir()
        (tmp_path / "brain" / "abc-123" / "transcript.jsonl").write_text("call text")
        (tmp_path / "annotations" / "abc-123.pbtxt").write_text("x")

    monkeypatch.setattr(subprocess, "run", Run(envelope(), write=agy_writes))
    ask(AgyProvider("/bin/agy", state_dir=tmp_path))
    assert not (tmp_path / "brain" / "abc-123").exists() and not (tmp_path / "annotations" / "abc-123.pbtxt").exists()
    assert keep.exists() and (tmp_path / "annotations" / "other-1.pbtxt").exists()
    assert forget("../../etc", tmp_path) is False and forget("", tmp_path) is False


def test_environment_without_keys():
    env = account_env({"PATH": "/bin", "GOOGLE_API_KEY": "k", "OPENAI_API_KEY": "k", "HOME": "/h"})
    assert env == {"PATH": "/bin", "HOME": "/h"}


class Leg:
    def __init__(self, route, error=None):
        self.route, self.error, self.calls = route, error, 0

    def complete(self, **kw):
        self.calls += 1
        return Completion(model=self.route, text="" if self.error else "answer", error=self.error)


def routed(job, preferred, legs, tmp_path, background=False):
    return RoutedProvider(job, preferred, legs, state=RouteState(str(tmp_path / "r.json")), gemini_fallback=True,
                          background=background)


def go(rp):
    return rp.complete(model="claude-sonnet-5-5", system=[{"text": "s"}], user="u", max_tokens=30, cache_ttl=None)


def test_plan_b_uses_the_key_first_then_the_account(tmp_path):
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    key, account = Leg("gemini"), Leg("agy")
    c = go(routed("after", "openai", {"openai": Leg("openai", "OpenAI: HTTP 401"), "gemini": key, "agy": account}, tmp_path / "a"))
    assert c.route == "gemini" and account.calls == 0
    c = go(routed("after", "openai", {"openai": Leg("openai", "OpenAI: HTTP 401"), "gemini": None, "agy": account}, tmp_path / "b"))
    assert c.route == "agy" and c.switched_from == "openai" and c.error is None


def test_the_account_is_never_plan_b_during_a_call(tmp_path):
    account = Leg("agy")
    c = go(routed("tips", "openai", {"openai": Leg("openai", "OpenAI: HTTP 401"), "agy": account}, tmp_path, background=True))
    assert c.error and account.calls == 0


def test_a_chosen_account_does_not_switch(tmp_path):
    other = Leg("gemini")
    c = go(routed("after", "agy", {"agy": Leg("agy", "Gemini account: usage limit reached"), "gemini": other, "api": other}, tmp_path))
    assert c.error == "Gemini account: usage limit reached" and other.calls == 0


def test_preparation_needs_the_cli(monkeypatch, tmp_path, capsys):
    req = tmp_path / "r.json"
    req.write_text(json.dumps({"title": "x"}))
    monkeypatch.setattr(agyprep, "find_agy_cli", lambda: None)
    assert agyprep.main(["--request", str(req)]) == 1
    assert "Antigravity CLI is not installed" in json.loads(capsys.readouterr().out)["error"]
