"""The live-tips Stop hook, run as Claude Code runs it: JSON on stdin, HOME with the marker (pinned before the split)."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HOOK = Path(__file__).absolute().parents[1] / "hooks" / "keepalive.py"


def hook(home, inp="{}", marker=None):
    mdir = home / ".live-tips"
    mdir.mkdir(parents=True, exist_ok=True)
    if marker is not None:
        (mdir / "keepalive.json").write_text(marker if isinstance(marker, str) else json.dumps(marker))
    r = subprocess.run([sys.executable, str(HOOK)], input=inp, capture_output=True, text=True,
                       env=dict(os.environ, HOME=str(home)), timeout=20)
    saved = mdir / "keepalive.json"
    return r.returncode, r.stdout, (json.loads(saved.read_text()) if saved.exists() and marker is not None and not isinstance(marker, str) else None)


def test_allows_without_a_valid_marker(tmp_path):
    assert hook(tmp_path)[:2] == (0, "")
    assert hook(tmp_path, marker="{broken")[:2] == (0, "")
    assert hook(tmp_path, marker=[1, 2])[:2] == (0, "")
    assert hook(tmp_path, marker={"until": time.time() - 5})[:2] == (0, "")
    assert hook(tmp_path, inp="not json", marker={"until": time.time() - 5})[:2] == (0, "")


def test_blocks_and_binds_the_session(tmp_path):
    m = {"until": time.time() + 600, "title": "Weekly \"sync\"\n<x>", "state_file": "/w/live/call.state.json"}
    code, out, saved = hook(tmp_path, json.dumps({"session_id": "s1"}), m)
    d = json.loads(out)
    assert code == 0 and d["decision"] == "block" and saved["session_id"] == "s1" and saved["blocks"] == 1
    assert 'the call "Weekly syncx" is still being recorded' in d["reason"]
    assert "offset from /w/live/call.state.json" in d["reason"]
    code, out, saved = hook(tmp_path, json.dumps({"session_id": "s2"}), dict(m, session_id="s1"))
    assert out == ""                                         # another session stops normally
    code, out, saved = hook(tmp_path, "", dict(m, state_file="/etc/passwd"))
    assert "the .state.json next to the transcript" in json.loads(out)["reason"] and "session_id" not in saved


def test_gives_up_after_max_blocks(tmp_path):
    m = {"until": time.time() + 600, "blocks": 3, "max_blocks": 3}
    assert hook(tmp_path, "{}", m)[1] == ""
    code, out, saved = hook(tmp_path, "{}", {"until": time.time() + 600})
    assert "the call" in json.loads(out)["reason"] and saved["blocks"] == 1


def load_hook():
    import importlib.util
    spec = importlib.util.spec_from_file_location("keepalive_hook", HOOK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_in_process(tmp_path, capsys):
    k = load_hook()
    marker = tmp_path / "keepalive.json"
    assert k.main("{}", str(marker), now=0) == 0 and capsys.readouterr().out == ""
    marker.write_text(json.dumps({"until": 100, "title": "T", "max_blocks": 2}))
    assert k.main('{"session_id": "a"}', str(marker), now=50) == 0
    d = json.loads(capsys.readouterr().out)
    assert d["decision"] == "block" and json.loads(marker.read_text()) == {"until": 100, "title": "T", "max_blocks": 2,
                                                                             "session_id": "a", "blocks": 1}
    k.main('{"session_id": "a"}', str(marker), now=100)
    assert json.loads(marker.read_text())["blocks"] == 2 and capsys.readouterr().out
    k.main('{"session_id": "a"}', str(marker), now=60)
    assert capsys.readouterr().out == "" and json.loads(marker.read_text())["blocks"] == 2
    assert k.main("", str(marker), now=101) == 0 and capsys.readouterr().out == ""
    assert k.read_input("[") == {} and k.load_marker(str(tmp_path / "none")) == (None, None)
    assert k.hold({"session_id": "x"}, 10, "", 5) == {"session_id": "x", "blocks": 1}
    k.save({"a": 1}, str(tmp_path / "missing" / "m.json"))                   # an unwritable path is ignored
    assert k.clean('a"b<c>\nd', 3) == "abc" and k.clean(None, 5) == ""
    assert "the .state.json next to the transcript" in k.reason({}, "M") and "the call" in k.reason({}, "M")
