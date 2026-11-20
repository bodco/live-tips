"""0.26.3: the built-in bge-m3 server sleeps after idle minutes; the core starts it again from the app's launcher file."""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

pytest.importorskip("numpy")
SRC = Path(__file__).resolve().parents[3] / "recorder" / "src" / "semantic.py"


@pytest.fixture
def S(monkeypatch):
    spec = importlib.util.spec_from_file_location("semantic_wake_test", SRC)
    m = importlib.util.module_from_spec(spec)
    sys.modules["semantic_wake_test"] = m
    spec.loader.exec_module(m)
    monkeypatch.delenv("LT_EMBED_LAUNCHER", raising=False)
    return m


def write_launcher(root, **over):
    py = root / "python"
    py.write_text("")
    d = {"python": str(py), "cwd": str(root), "args": ["-m", "livetips_m0.embed_server", "--idle-exit", "600"],
         "log": str(root / "local-ai.log")}
    d.update(over)
    (root / "state").mkdir(exist_ok=True)
    (root / "state" / "embed-server.json").write_text(json.dumps(d))
    return d


def test_launcher_path_and_reading(S, tmp_path, monkeypatch):
    assert S.launcher_path(str(tmp_path)) == str(tmp_path / "state" / "embed-server.json")
    assert S.read_launcher(S.launcher_path(str(tmp_path))) is None            # missing
    d = write_launcher(tmp_path)
    got = S.read_launcher(S.launcher_path(str(tmp_path)))
    assert got["python"] == d["python"] and got["args"][-1] == "600" and got["cwd"] == str(tmp_path)
    write_launcher(tmp_path, args="not a list")
    assert S.read_launcher(S.launcher_path(str(tmp_path))) is None
    write_launcher(tmp_path, python=str(tmp_path / "missing"))
    assert S.read_launcher(S.launcher_path(str(tmp_path))) is None
    monkeypatch.setenv("LT_EMBED_LAUNCHER", "/x/y.json")
    assert S.launcher_path(str(tmp_path)) == "/x/y.json"


def test_wake_starts_once_and_waits(S, tmp_path):
    write_launcher(tmp_path)
    started, up = [], [False]

    def spawn(launch):
        started.append(launch)
        up[0] = True
    assert S.wake_builtin("http://127.0.0.1:11435", root=str(tmp_path), wait_s=2, spawn=spawn, ping=lambda: up[0])
    assert len(started) == 1 and started[0]["args"][0] == "-m"
    # already up: no second start
    assert S.wake_builtin("http://127.0.0.1:11435", root=str(tmp_path), wait_s=2, spawn=spawn, ping=lambda: True)
    assert len(started) == 1


def test_wake_is_throttled_and_needs_a_launcher(S, tmp_path):
    calls = []
    assert not S.wake_builtin("u", root=str(tmp_path), wait_s=0.1, spawn=calls.append, ping=lambda: False)   # no file
    write_launcher(tmp_path)
    assert not S.wake_builtin("u", root=str(tmp_path), wait_s=0.1, spawn=calls.append, ping=lambda: False)   # throttled
    assert calls == []
    S._WAKE_LAST[0] = 0.0
    assert not S.wake_builtin("u", root=str(tmp_path), wait_s=0.2, spawn=calls.append, ping=lambda: False)   # never answers
    assert len(calls) == 1


def test_refused_builtin_request_wakes_and_retries(S, monkeypatch):
    c = S.OllamaClient(url="http://127.0.0.1:%d" % S.BUILTIN_PORT, timeout=1)
    tries = []

    def once(path, payload, timeout):
        tries.append(path)
        if len(tries) == 1:
            raise S.SemanticError("asleep", refused=True)
        return {"ok": True}
    monkeypatch.setattr(c, "_req_once", once)
    monkeypatch.setattr(S, "wake_builtin", lambda url: True)
    assert c._req("/api/tags", None, 1) == {"ok": True} and len(tries) == 2


def test_ollama_and_other_errors_do_not_wake(S, monkeypatch):
    woke = []
    monkeypatch.setattr(S, "wake_builtin", lambda url: woke.append(url) or True)
    ollama = S.OllamaClient(url="http://127.0.0.1:11434", timeout=1)
    monkeypatch.setattr(ollama, "_req_once", lambda *a: (_ for _ in ()).throw(S.SemanticError("down", refused=True)))
    with pytest.raises(S.SemanticError):
        ollama._req("/api/tags", None, 1)
    builtin = S.OllamaClient(url="http://127.0.0.1:%d" % S.BUILTIN_PORT, timeout=1)
    monkeypatch.setattr(builtin, "_req_once", lambda *a: (_ for _ in ()).throw(S.SemanticError("HTTP 500", 500)))
    with pytest.raises(S.SemanticError):
        builtin._req("/api/tags", None, 1)
    assert woke == []
