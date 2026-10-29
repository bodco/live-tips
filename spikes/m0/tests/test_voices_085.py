"""rules/voices.yaml (0.8.5): library aliases and merge, a named voice keeps only its own person, split on rename."""
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest

SRC = Path(__file__).resolve().parents[3] / "recorder/src/transcriber.py"


@pytest.fixture(scope="module")
def T():
    spec = importlib.util.spec_from_file_location("lt_transcriber_voices", SRC)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lt_transcriber_voices"] = mod
    spec.loader.exec_module(mod)
    return mod


def vec(i, j=None, w=0.0):
    v = np.zeros(16)
    v[i] = 1.0
    if j is not None:
        v[j] = w
    return list(v / np.linalg.norm(v))


def lib(T, tmp_path, people, aliases=None):
    p = tmp_path / "voices.json"
    p.write_text(json.dumps({"people": {n: {"embeddings": [e] * 3, "calls": 2, "side": "team", "where": ["all"]} for n, e in people.items()},
                             **({"aliases": aliases} if aliases else {})}))
    return T.VoiceLibrary(p)


def test_merge_and_aliases(T, tmp_path):
    L = lib(T, tmp_path, {"Mariia H.": vec(0), "Maria H.": vec(0, 1, 0.1), "m.holosovska": vec(0, 2, 0.1)})
    assert L.merge("Maria H.", "Mariia H.") and L.merge("m.holosovska", "Mariia H.")
    assert set(L.people) == {"Mariia H."} and L.people["Mariia H."]["calls"] == 6
    assert L.canonical("maria h.") == "Mariia H." and L.canonical("M.Holosovska") == "Mariia H."
    L.save()
    again = T.VoiceLibrary(tmp_path / "voices.json")
    assert again.canonical("Maria H.") == "Mariia H." and set(again.people) == {"Mariia H."}
    # an alias still kept as a person (an older recorder wrote it) joins the name kept on load
    d = json.loads((tmp_path / "voices.json").read_text())
    d["people"]["Maria H."] = {"embeddings": [vec(0)] * 2, "calls": 1}
    (tmp_path / "voices.json").write_text(json.dumps(d))
    assert set(T.VoiceLibrary(tmp_path / "voices.json").people) == {"Mariia H."}


def tracker(T, tmp_path, L):
    return T.SpeakerTracker({"participants": ["Mariia H.", "Olena S."]}, tmp_path / "s.speakers.json", library=L)


def test_named_voice_keeps_only_its_person(T, tmp_path):
    L = lib(T, tmp_path, {"Mariia H.": vec(0), "Olena S.": vec(1)})
    sp = tracker(T, tmp_path, L)
    a = sp.observe("10:00:01", 0, 3, vec(0, 1, 0.2), 3.0, "hello")
    sp.apply_setting("speaker_name", f"{a}|Mariia H.")
    # Olena's voice is close enough to the cluster to join it (cosine about 0.6), but clearly hers in the library
    b = sp.observe("10:00:05", 4, 7, vec(1, 0, 0.75), 3.0, "hi")
    assert b != a and sp.clusters[b]["name"] is None
    assert sp.clusters[a]["name"] == "Mariia H."


def test_split_on_rename(T, tmp_path):
    L = lib(T, tmp_path, {"Mariia H.": vec(0), "Olena S.": vec(1)})
    sp = tracker(T, tmp_path, L)
    T.DEFAULTS["speaker_join"] = 0.3              # a loose join: both voices land in one cluster, as on the call
    try:
        a = sp.observe("10:00:01", 0, 3, vec(0, 1, 0.9), 3.0, "one")
        for i, v in enumerate([vec(0, 1, 0.3), vec(1, 0, 0.3), vec(1, 0, 0.35)]):
            assert sp.observe(f"10:00:1{i}", 10 + i * 4, 13 + i * 4, v, 3.0, "x") == a
    finally:
        T.DEFAULTS["speaker_join"] = 0.45
    sp.apply_setting("speaker_name", f"{a}|Mariia H.")
    sp.apply_setting("speaker_name", f"{a}|Olena S.")       # the PM: this is Olena, not Mariia
    m = sp.by_name("Mariia H.")
    assert m and m != a and sp.clusters[a]["name"] == "Olena S."
    assert sp.resolve(sp.overrides.get("10:00:10")) == m and "10:00:11" not in sp.overrides   # Mariia's line moved, Olena's stayed


def test_typed_alias_names_the_kept_person(T, tmp_path):
    L = lib(T, tmp_path, {"Mariia H.": vec(0)}, aliases={"Maria H.": "Mariia H."})
    sp = tracker(T, tmp_path, L)
    a = sp.observe("10:00:01", 0, 3, vec(0), 3.0, "hello")
    sp.apply_setting("speaker_name", f"{a}|Maria H.")
    assert sp.clusters[a]["name"] == "Mariia H."
