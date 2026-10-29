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
