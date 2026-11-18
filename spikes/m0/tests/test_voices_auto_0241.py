"""rules/voices.yaml > auto (0.24.1, owner): a voice the library knows well, of a participant of this call, is named by
itself as soon as there is enough speech; nobody else is."""
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest

SRC = Path(__file__).resolve().parents[3] / "recorder/src/transcriber.py"


@pytest.fixture(scope="module")
def T():
    spec = importlib.util.spec_from_file_location("lt_transcriber_auto0241", SRC)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber_auto0241"] = mod
    spec.loader.exec_module(mod)
    return mod


def vec(i, j=None, w=0.0):
    v = np.zeros(16)
    v[i] = 1.0
    if j is not None:
        v[j] = w
    return list(v / np.linalg.norm(v))


def tracker(T, tmp_path, participants):
    p = tmp_path / "voices.json"
    p.write_text(json.dumps({"people": {n: {"embeddings": [e] * 3, "calls": 2, "side": "client", "where": ["all"]}
                                        for n, e in {"Mike T.": vec(0), "Emily R.": vec(1), "John D.": vec(2)}.items()}}))
    return T.SpeakerTracker({"participants": participants}, tmp_path / "s.speakers.json", library=T.VoiceLibrary(p))


def say(sp, *a):
    """As the recorder does: the line is tagged, written, then may be asked about or named."""
    sid = sp.observe(*a)
    sp.after_line(sid)
    return sid


def test_a_participant_is_named_after_a_few_seconds(T, tmp_path):
    sp = tracker(T, tmp_path, ["Mike T.", "Emily R."])
    a = say(sp, "10:00:01", 0, 3, vec(0, 3, 0.1), 3.0, "hello there")
    assert sp.clusters[a]["name"] is None                      # 3 s: too little to tell
    a = say(sp, "10:00:04", 3, 5, vec(0, 3, 0.1), 2.0, "shall we start")
    assert sp.clusters[a]["name"] == "Mike T." and a in sp.auto  # named by itself, long before the ask (15 s)


def test_a_calendar_spelling_of_the_participant_counts(T, tmp_path):
    sp = tracker(T, tmp_path, ["M. Turner", "Emily R."])
    a = say(sp, "10:00:01", 0, 5, vec(0), 5.0, "hello there")
    assert sp.clusters[a]["name"] == "Mike T."


def test_someone_who_is_not_on_the_call_is_not_named(T, tmp_path):
    sp = tracker(T, tmp_path, ["Mike T.", "Emily R."])
    a = say(sp, "10:00:01", 0, 5, vec(2), 5.0, "hello there")   # John's voice, John is not invited
    assert sp.clusters[a]["name"] is None


def test_an_unsure_match_is_not_named(T, tmp_path):
    sp = tracker(T, tmp_path, ["Mike T.", "Emily R."])
    a = say(sp, "10:00:01", 0, 5, vec(0, 1, 1.0), 5.0, "hello there")   # halfway between Mike and Emily
    assert sp.clusters[a]["name"] is None


def test_a_name_given_on_this_call_is_not_given_twice(T, tmp_path):
    sp = tracker(T, tmp_path, ["Mike T.", "Emily R."])
    a = say(sp, "10:00:01", 0, 5, vec(5), 5.0, "hello there")             # an unknown voice
    sp.apply_setting("speaker_name", f"{a}|Mike T.")                       # the PM says it is Mike
    b = say(sp, "10:00:10", 10, 15, vec(0), 5.0, "hi all")                 # Mike's library voice, another speaker
    assert b != a and sp.clusters[b]["name"] is None
