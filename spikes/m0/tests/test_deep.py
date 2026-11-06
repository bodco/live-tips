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


# ---------- 2026-11-06: the deep lookup on any AI way (local search + the preparation's model) ----------
class _Fake:
    def __init__(self, text="", error=None, usd=0.02):
        self.text, self.error, self.usd, self.seen = text, error, usd, {}

    def complete(self, **kw):
        self.seen.update(kw)
        return types.SimpleNamespace(text=self.text, error=self.error, usd=self.usd)


def _render(snips):
    return "\n".join("[{}] {}".format(x["src"], x["text"]) for x in snips)


SNIPS = [{"src": "notes/kickoff.md", "date": "2026-10-28", "text": "Export: production on Tuesday after the review."}]


def test_local_lookup_answers_from_passages():
    p = _Fake(text='Here: {"answered": true, "gist": "Tuesday", "phrase": "Production on Tuesday.", "items": []}')
    res = deep.local_lookup(p, "claude-sonnet-5-5", "  When is the export live? ", ["them: when?"], "English", SNIPS, _render)
    assert res["gist"] == "Tuesday" and res["cost_usd"] == 0.02 and res["sources"] == ["notes/kickoff.md"]
    assert p.seen["model"] == "claude-sonnet-5-5" and p.seen["cache_ttl"] is None
    assert "Write gist, phrase and items in English." in p.seen["system"][0]["text"]
    u = p.seen["user"]
    assert u.startswith("Question from the PM: When is the export live?") and "[notes/kickoff.md] Export" in u
    assert "<transcript_data>\nthem: when?\n</transcript_data>" in u


def test_local_lookup_failures():
    assert deep.local_lookup(None, "m", "q", [], "English", SNIPS, _render) == {"error": "no AI way for the preparation"}
    assert deep.local_lookup(_Fake(), "m", "q", [], "English", [], _render) == {"error": "nothing found in the project folders"}
    assert deep.local_lookup(_Fake(error="OpenAI: 429 rate_limit"), "m", "q", [], "English", SNIPS, _render)["error"].startswith("OpenAI: 429")
    assert deep.local_lookup(_Fake(text="no json"), "m", "q", [], "English", SNIPS, _render) == {"error": "no answer from the search", "cost_usd": 0.02}


def test_prep_provider_ignores_the_tips_route_in_env(monkeypatch):
    from livetips_m0 import routing
    monkeypatch.setenv("LT_AI_ROUTE", "openai")
    seen = {}

    class RP:
        def __init__(self, job, route, legs, **kw):
            seen.update(job=job, route=route)
    monkeypatch.setattr(routing, "RoutedProvider", RP)
    monkeypatch.setattr(routing, "make_legs", lambda *a, **k: {})
    cfg = {"ai": {"routes": {"prep": "code", "tips": "openai"}}}
    routing.provider_from_cfg(cfg, lambda n: "", job="prep", env_route=False)
    assert seen == {"job": "prep", "route": "code"}
    routing.provider_from_cfg(cfg, lambda n: "", job="prep")
    assert seen["route"] == "openai"          # a one-off run (LT_AI_ROUTE) still wins by default
