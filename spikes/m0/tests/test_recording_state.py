"""rules/recording.yaml: the recorder's Mic and Call levels and silence seconds."""
import importlib.util
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[3] / "recorder/src/transcriber.py"


@pytest.fixture(scope="module")
def T():
    spec = importlib.util.spec_from_file_location("lt_transcriber_rec", SRC)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber_rec"] = mod
    spec.loader.exec_module(mod)
    return mod


class Seg:
    def __init__(self, peak, muted=False):
        self.peak, self.muted = peak, muted

    def recent_peak(self):
        return self.peak


def test_levels_and_silence(T):
    heard = {"me": 0.0, "them": 0.0}
    r = T.audio_levels({"me": Seg(0.02), "them": Seg(0.0)}, heard, 31.0)
    assert r == {"mic_level": 0.4, "mic_silent_s": 0, "call_level": 0.0, "call_silent_s": 31}
    r = T.audio_levels({"me": Seg(0.0, muted=True), "them": Seg(0.01)}, heard, 40.0)
    assert r["mic_silent_s"] == 0 and r["call_silent_s"] == 0 and r["call_level"] == 0.2


def test_tap_recovery_once_when_zeros_while_the_output_plays(T):
    """0.8.7 (rules/recording.yaml > tap_recovery): 45 s of zeros while the speakers play = rebuild the tap once."""
    asked = []

    def playing():
        asked.append(1)
        return True
    assert not T.tap_recovery(now_t=44, live=True, zero_since=0, output_playing=playing, done=False)
    assert not asked, "the output device is asked only when everything else holds"
    assert T.tap_recovery(now_t=45, live=True, zero_since=0, output_playing=playing, done=False)
    assert not T.tap_recovery(now_t=200, live=True, zero_since=0, output_playing=True, done=True), "once per call"
    assert not T.tap_recovery(now_t=100, live=True, zero_since=0, output_playing=False, done=False), "nothing plays: real silence"
    assert not T.tap_recovery(now_t=100, live=False, zero_since=0, output_playing=True, done=False), "standby is not live"
    assert not T.tap_recovery(now_t=100, live=True, zero_since=80, output_playing=True, done=False), "sound resets the clock"


def test_tap_recovery_rule_is_in_the_rules():
    import yaml
    doc = yaml.safe_load((SRC.parents[2] / "rules" / "recording.yaml").read_text(encoding="utf-8"))
    tr = doc["tap_recovery"]
    assert tr["zero_s"] == 45 and "output device" in tr["never"]
