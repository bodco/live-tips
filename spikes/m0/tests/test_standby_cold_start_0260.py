"""0.26.0 (C): a cold start on a standby call. The model can take a while to load; the window shows Ready meanwhile,
and a Start pressed then (control/go) must not be lost. The recorder clears a stale Start and knows the standby state
before the model loads, and the first status already carries `standby`."""
import importlib.util
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).absolute().parents[3]
SRC = REPO / "recorder" / "src" / "transcriber.py"


@pytest.fixture(scope="module")
def T():
    spec = importlib.util.spec_from_file_location("lt_transcriber_c0260", SRC)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber_c0260"] = mod
    spec.loader.exec_module(mod)
    return mod


def test_standby_begin_clears_a_stale_start(T, tmp_path):
    (tmp_path / "go").write_text("")
    st = T.standby_begin({"standby": True}, tmp_path)
    assert st == {"on": True, "heard": [], "buf": []}
    assert not (tmp_path / "go").exists()


def test_standby_begin_without_standby_or_go(T, tmp_path):
    assert T.standby_begin({}, tmp_path)["on"] is False
    assert T.standby_begin({"standby": False}, tmp_path)["on"] is False


def test_start_written_after_begin_is_kept(T, tmp_path):
    T.standby_begin({"standby": True}, tmp_path)
    (tmp_path / "go").write_text("")        # the PM presses Start while the model loads
    assert (tmp_path / "go").exists()       # nothing in the recorder removes it before the main loop reads it


def test_main_order_begin_before_model_and_status_has_standby():
    src = SRC.read_text(encoding="utf-8")
    main = src[src.index("\ndef main("):]
    i_begin = main.index("standby = standby_begin(cfg, CONTROL, since=req_at)")
    i_status = main.index('status = {"state": "loading_model"')
    i_whisper = main.index("Whisper(cfg)")
    assert i_begin < i_status < i_whisper
    assert '"standby": standby["on"]' in main[i_status:i_status + 200]
    # the only other place that removes control/go is the main loop that acts on it
    assert len(re.findall(r'\(CONTROL / "go"\)\.unlink\(\)', main)) == 0
    assert main.count("go_file.unlink()") == 1


def test_start_pressed_before_the_recorder_is_kept(T, tmp_path):
    """Review 4: the PM pressed Start after the app wrote the request but before Python came up."""
    import os
    (tmp_path / "go").write_text("")
    req_at = (tmp_path / "go").stat().st_mtime - 5      # the request was written 5 s before the Start
    T.standby_begin({"standby": True}, tmp_path, since=req_at)
    assert (tmp_path / "go").exists()
    os.utime(tmp_path / "go", (req_at - 60, req_at - 60))   # a Start from the previous call, older than the request
    T.standby_begin({"standby": True}, tmp_path, since=req_at)
    assert not (tmp_path / "go").exists()
