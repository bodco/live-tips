"""deep.lookup with a fake Claude Code: arguments, environment, results and every failure."""
import json
import subprocess
import types

from livetips_m0 import deep


def setup(tmp_path, monkeypatch, out=None, rc=0, boom=None):
    tmp_path.mkdir(exist_ok=True)
    root = tmp_path / "proj"
    root.mkdir()
    extra = tmp_path / "extra"
    extra.mkdir()
    cli = tmp_path / "claude"
    cli.write_text("")
    seen = {}

    def run(args, cwd, env, capture_output, text, timeout):
        seen.update(args=args, cwd=cwd, env=env, timeout=timeout)
        if boom:
            raise boom
        return types.SimpleNamespace(stdout=out if out is not None else "", returncode=rc)
    monkeypatch.setattr(deep.subprocess, "run", run)
    monkeypatch.setenv("MY_KEY", "sk-test")
    cfg = {"project_root": str(root), "claude_cli": str(cli), "extra_dirs": [str(extra), str(tmp_path / "none"), 3],
           "api_key_env": "MY_KEY", "deep_max_turns": 5}
    return cfg, seen


def test_lookup_answer(tmp_path, monkeypatch):
    result = json.dumps({"answered": True, "gist": "15 Jan", "sources": ["a.md", 2, "c", "d", "e", "f", "g"]})
    cfg, seen = setup(tmp_path, monkeypatch, out=json.dumps({"total_cost_usd": 0.12, "result": "Sure: " + result}))
    res = deep.lookup(cfg, "  When is the release?  ", ["x" * 500, "b"], "English", timeout=7)
    assert res["gist"] == "15 Jan" and res["cost_usd"] == 0.12 and res["sources"] == ["a.md", "2", "c", "d", "e", "f"]
    a = seen["args"]
    assert a[0] == cfg["claude_cli"] and a[1] == "-p" and a[2].startswith("Question from the PM: When is the release?\n")
    assert "x" * 400 + "\nb\n</transcript_data>" in a[2] and "x" * 401 not in a[2]
    assert a[a.index("--model") + 1] == "sonnet" and a[a.index("--max-turns") + 1] == "5"
    assert "Write gist, phrase and items in English." in a[a.index("--append-system-prompt") + 1]
    assert a.count("--add-dir") == 1 and a[a.index("--add-dir") + 1] == cfg["extra_dirs"][0]
    assert seen["env"]["ANTHROPIC_API_KEY"] == "sk-test" and seen["cwd"] == cfg["project_root"] and seen["timeout"] == 7


def test_lookup_failures(tmp_path, monkeypatch):
    assert deep.lookup({}, "q", [], "English") == {"error": "no project folder for this call"}
    cfg, _ = setup(tmp_path, monkeypatch, out="not json", rc=3)
    assert deep.lookup(cfg, "q", [], "English") == {"error": "Claude Code gave no result (exit 3)"}
    monkeypatch.setattr(deep, "claude_path", lambda c: None)
    assert "not installed" in deep.lookup(cfg, "q", [], "English")["error"]


def test_lookup_no_answer_and_timeouts(tmp_path, monkeypatch):
    cfg, _ = setup(tmp_path, monkeypatch, out=json.dumps({"result": "nothing"}))
    assert deep.lookup(cfg, "q", [], "English") == {"error": "no answer from the search", "cost_usd": 0.0}
    cfg, _ = setup(tmp_path / "b", monkeypatch, boom=subprocess.TimeoutExpired("claude", 1))
    assert deep.lookup(cfg, "q", [], "English") == {"error": "the search took too long"}
    cfg, _ = setup(tmp_path / "c", monkeypatch, boom=OSError("denied"))
    assert deep.lookup(cfg, "q", [], "English") == {"error": "could not start Claude Code: denied"}
    cfg, seen = setup(tmp_path / "d", monkeypatch, out="")
    monkeypatch.delenv("MY_KEY")
    assert deep.lookup(cfg, "q", [], "English") == {"error": "no answer from the search", "cost_usd": 0.0}
    assert "ANTHROPIC_API_KEY" not in seen["env"] or seen["env"]["ANTHROPIC_API_KEY"] != "sk-test"


def test_claude_path(tmp_path, monkeypatch):
    cli = tmp_path / "c"
    cli.write_text("")
    assert deep.claude_path({"claude_cli": str(cli)}) == str(cli)
    monkeypatch.setattr(deep.shutil, "which", lambda name, path: "/found/" + name if "/opt/homebrew/bin" in path else None)
    assert deep.claude_path({"claude_cli": str(tmp_path / "missing")}) == "/found/claude"
