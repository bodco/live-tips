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


def test_library_learns_only_a_clean_named_voice(T, tmp_path):
    """rules/voices.yaml > learning: a mixed speaker teaches the library nothing; a clean one is learned."""
    L = lib(T, tmp_path, {"Mariia H.": vec(0)})
    sp = tracker(T, tmp_path, L)
    T.DEFAULTS["speaker_join"] = -1.0             # two voices in one cluster, as on the call
    T.DEFAULTS["speaker_join_k"] = 0.0
    try:
        a = sp.observe("10:00:01", 0, 3, vec(2), 3.0, "one")
        for i, v in enumerate([vec(2, 3, 0.1), vec(3), vec(3, 2, 0.1)]):
            sp.observe(f"10:00:1{i}", 10 + i * 4, 13 + i * 4, v, 3.0, "x")
    finally:
        T.DEFAULTS["speaker_join"] = 0.45
        T.DEFAULTS["speaker_join_k"] = 0.85
    sp.apply_setting("speaker_name", f"{a}|Olena S.")
    assert "Olena S." not in L.people                     # sounds like more than one voice
    (tmp_path / "x").mkdir()
    L2 = lib(T, tmp_path / "x", {"Mariia H.": vec(0)})
    sp2 = tracker(T, tmp_path / "x", L2)
    b = sp2.observe("10:00:01", 0, 3, vec(4), 3.0, "one")
    sp2.observe("10:00:05", 4, 7, vec(4, 5, 0.1), 3.0, "two")
    sp2.apply_setting("speaker_name", f"{b}|Olena S.")
    assert "Olena S." in L2.people and len(L2.people["Mariia H."]["embeddings"]) == 3


def test_window_language_uk_means_ukrainian_only(T):
    src = SRC.read_text(encoding="utf-8")
    assert 'LANG_SETS = {"uk": ("uk", [], ["uk"]), "en": ("en", [], ["en"]),' in src
    assert T.NOT_ENGLISH.search("Dostup do Wołewski w Tobie jest") and not T.NOT_ENGLISH.search("I'll hold that.")


def test_similar_voices_stay_apart(T, tmp_path):
    """rules/voices.yaml > thresholds: two similar voices (like two colleagues on one call) are not one speaker."""
    from collections import Counter
    pur = []
    for seed in range(8):
        rng = np.random.default_rng(seed)
        base = rng.normal(size=128); base /= np.linalg.norm(base)
        P = []
        for _ in range(2):
            r = rng.normal(size=128); r -= r.dot(base) * base; r /= np.linalg.norm(r)
            P.append(np.sqrt(0.78) * base + np.sqrt(0.22) * r)
        d = tmp_path / str(seed); d.mkdir()
        sp = T.SpeakerTracker({"participants": []}, d / "s.speakers.json", library=None)
        truth, ts, who = [], [], 0
        for k in range(80):
            if rng.random() < 0.35:
                who = int(rng.integers(2))
            z = rng.normal(size=128); z /= np.linalg.norm(z)
            t = "10:%02d:%02d" % (k // 60, k % 60)
            sp.observe(t, k * 5, k * 5 + 3, list(np.sqrt(0.5) * P[who] + np.sqrt(0.5) * z), 3.0, "x")
            truth.append(who); ts.append(t)
        lab = [sp.resolve(sp.overrides.get(t) or sp.segs[t]["sid"]) for t in ts]
        pur.append(sum(max(Counter(w for w, l in zip(truth, lab) if l == c).values()) for c in set(lab)) / 80)
    assert np.mean(pur) >= 0.85


def test_people_of_the_meeting_are_offered_without_a_voice_match(T, tmp_path):
    L = lib(T, tmp_path, {"Mariia H.": vec(0)})
    sp = T.SpeakerTracker({"participants": ["Ann Lee", "Mike Johnson"], "name_aliases": ["Mike"]}, tmp_path / "s.speakers.json", library=L)
    a = sp.observe("10:00:01", 0, 3, vec(5), 3.0, "hello")
    assert [x["name"] for x in sp.clusters[a]["suggestions"]] == ["Ann L."] and sp.clusters[a]["suggestions"][0]["score"] is None
