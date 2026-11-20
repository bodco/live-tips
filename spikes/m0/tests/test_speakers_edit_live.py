"""0.26.2 (speakers on the call page, B1): a live call keeps its voice prints in .work/<stem>.voices.json, and
fromfile.py edit fixes its speakers after the call: names, moved lines, new people, without double learning."""
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np
import pytest

SRCDIR = Path(__file__).resolve().parents[3] / "recorder/src"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SRCDIR / file)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def T():
    return load("lt_transcriber_spk", "transcriber.py")


@pytest.fixture(scope="module")
def F():
    sys.path.insert(0, str(SRCDIR))
    return load("lt_fromfile_spk", "fromfile.py")


def vec(i, j=None, w=0.0):
    v = np.zeros(16); v[i] = 1.0
    if j is not None:
        v[j] = w
    return list(v / np.linalg.norm(v))


LINES = [("00:00:01", 2), ("00:00:05", 2), ("00:00:09", 4), ("00:00:13", 2), ("00:00:17", 4), ("00:00:21", 4)]


def live_call(T, tmp_path, monkeypatch, name_s1=None, remember=True):
    """A recorded call with two voices (vec 2 and vec 4) through the real tracker and finalize."""
    monkeypatch.setattr(T, "ROOT", tmp_path)
    lib = T.VoiceLibrary(tmp_path / "voices" / "voices.json", project="demo", remember=remember)
    md = tmp_path / "live" / "2026-11-20-demo" / "2026-11-20-1000-demo.md"
    md.parent.mkdir(parents=True)
    sp = T.SpeakerTracker({"participants": []}, T.call_layout.sidecar_of(md, ".speakers.json"), library=lib)
    rows = []
    for i, (t, k) in enumerate(LINES):
        sid = sp.observe(t, i * 4, i * 4 + 3, vec(k, k + 1, 0.05 * (i % 2)), 3.0, f"line {i}")
        rows.append(f"[{t}] Speaker [{sid}] (en): line {i}\n")
    if name_s1:
        sp.apply_setting("speaker_name", f"S1|{name_s1}")
    md.write_text("# Transcript: demo\n\n" + "".join(rows), encoding="utf-8")
    sp.finalize(md, "Speaker")
    return md


def library(tmp_path):
    p = tmp_path / "voices" / "voices.json"
    return json.loads(p.read_text())["people"] if p.exists() else {}


def edit(F, T, md, capsys, *args):
    capsys.readouterr()
    assert F.edit(["--md", str(md), *args], T) == 0
    return json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def test_finalize_writes_voice_prints_in_work(T, tmp_path, monkeypatch):
    md = live_call(T, tmp_path, monkeypatch, name_s1="Mike")
    vp = T.call_layout.sidecar_of(md, ".voices.json")
    assert vp.parent.name == ".work" and vp.exists()
    vj = json.loads(vp.read_text())
    assert sorted(vj["lines"]) == [t for t, _ in LINES]
    assert all(ln["member"] and len(ln["emb"]) == 16 for ln in vj["lines"].values())
    assert {ln["sid"] for ln in vj["lines"].values()} == {"S1", "S2"}
    assert "Mike" in vj["lib_added"] and vj["remember"] is True and vj["project"] == "demo"
    assert "audio" not in json.dumps(vj)


def test_rename_after_the_call_teaches_the_library_once(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch)
    assert library(tmp_path) == {}
    r = edit(F, T, md, capsys, "--name", "S1=Mike")
    assert r["voices"] is True
    lib = library(tmp_path)
    assert lib["Mike"]["calls"] == 1 and len(lib["Mike"]["embeddings"]) == 3
    edit(F, T, md, capsys, "--name", "S1=Mike")       # the same edit again: nothing added twice
    lib = library(tmp_path)
    assert lib["Mike"]["calls"] == 1 and len(lib["Mike"]["embeddings"]) == 3
    assert "Mike (" in T.call_layout.sidecar_of(md, ".named.md").read_text()


def test_rename_of_a_voice_named_in_the_call_moves_its_prints(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch, name_s1="Mike")
    assert "Mike" in library(tmp_path)
    edit(F, T, md, capsys, "--name", "S1=Emily")
    lib = library(tmp_path)
    assert "Mike" not in lib and lib["Emily"]["calls"] == 1 and len(lib["Emily"]["embeddings"]) == 3


def test_a_moved_line_takes_its_voice_print(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch)
    vp = T.call_layout.sidecar_of(md, ".voices.json")
    vj = json.loads(vp.read_text())
    vj["lines"]["00:00:13"]["emb"] = [round(x, 4) for x in vec(4)]      # Emily's voice, tagged as S1 on the call
    vp.write_text(json.dumps(vj))
    edit(F, T, md, capsys, "--name", "S1=Mike", "--name", "S2=Emily")
    lib = library(tmp_path)
    assert "Mike" not in lib and len(lib["Emily"]["embeddings"]) == 3   # S1 sounds like two voices: not learned
    before = json.loads(T.call_layout.sidecar_of(md, ".speakers.json").read_text())["clusters"]
    edit(F, T, md, capsys, "--fix", "00:00:13=S2")
    lib = library(tmp_path)
    assert len(lib["Mike"]["embeddings"]) == 2 and lib["Mike"]["calls"] == 1
    assert len(lib["Emily"]["embeddings"]) == 4 and lib["Emily"]["calls"] == 1
    cl = json.loads(T.call_layout.sidecar_of(md, ".speakers.json").read_text())["clusters"]
    assert cl["S1"]["seconds"] == round(before["S1"]["seconds"] - 3.0, 1)
    assert cl["S2"]["seconds"] == round(before["S2"]["seconds"] + 3.0, 1)
    named = T.call_layout.sidecar_of(md, ".named.md").read_text().splitlines()
    assert next(l for l in named if l.startswith("[00:00:13]")).startswith("[00:00:13] Emily (")


def test_a_line_of_a_person_without_a_speaker(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch)
    edit(F, T, md, capsys, "--fix", "00:00:21=@Emily Clark")
    snap = json.loads(T.call_layout.sidecar_of(md, ".speakers.json").read_text())
    assert snap["clusters"]["S3"]["name"] == "Emily Clark" and snap["overrides"]["00:00:21"] == "S3"
    named = T.call_layout.sidecar_of(md, ".named.md").read_text()
    assert "[00:00:21] Emily Clark (" in named
    assert len(library(tmp_path)["Emily Clark"]["embeddings"]) == 1
    edit(F, T, md, capsys, "--fix", "00:00:17=@emily clark")   # the same person again: the same speaker
    snap = json.loads(T.call_layout.sidecar_of(md, ".speakers.json").read_text())
    assert snap["overrides"]["00:00:17"] == "S3" and "S4" not in snap["clusters"]


def test_a_call_without_voice_prints_changes_names_only(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch)
    T.call_layout.sidecar_of(md, ".voices.json").rename(tmp_path / "gone.json")   # a call before 0.26.2
    r = edit(F, T, md, capsys, "--name", "S1=Mike", "--fix", "00:00:21=@Emily")
    assert r["voices"] is False and library(tmp_path) == {}
    named = T.call_layout.sidecar_of(md, ".named.md").read_text()
    assert "Mike (" in named and "[00:00:21] Emily (" in named


def test_a_public_call_learns_only_with_remember_on(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch, remember=False)        # a public call: nothing learned live
    assert json.loads(T.call_layout.sidecar_of(md, ".voices.json").read_text())["remember"] is False
    edit(F, T, md, capsys, "--name", "S1=Mike")
    assert library(tmp_path) == {}
    edit(F, T, md, capsys, "--remember", "S1=on")
    assert "Mike" in library(tmp_path)


def test_a_roster_named_voice_waits_for_the_pm(T, F, tmp_path, monkeypatch, capsys):
    md = live_call(T, tmp_path, monkeypatch)
    vp = T.call_layout.sidecar_of(md, ".voices.json")
    vj = json.loads(vp.read_text()); vj["auto"] = ["S2"]; vp.write_text(json.dumps(vj))
    snap_p = T.call_layout.sidecar_of(md, ".speakers.json")
    snap = json.loads(snap_p.read_text()); snap["clusters"]["S2"]["name"] = "Emily"; snap_p.write_text(json.dumps(snap))
    edit(F, T, md, capsys, "--name", "S1=Mike")               # S2 was named by the roster: not learned
    assert "Mike" in library(tmp_path) and "Emily" not in library(tmp_path)
    edit(F, T, md, capsys, "--name", "S2=Emily")              # the PM confirms the name: now it is learned
    assert "Emily" in library(tmp_path)
    assert json.loads(vp.read_text())["auto"] == []


def test_a_meet_named_voice_waits_for_the_pm(T, F, tmp_path, monkeypatch, capsys):
    """rules/voices.yaml > meet: names from the Google Meet record are not learned until the PM confirms them."""
    md = live_call(T, tmp_path, monkeypatch)
    snap_p = T.call_layout.sidecar_of(md, ".speakers.json")
    snap = json.loads(snap_p.read_text())
    snap["clusters"]["S1"].update(name="Mike", named_by="meet"); snap_p.write_text(json.dumps(snap))
    edit(F, T, md, capsys, "--side", "S1=client")
    assert "Mike" not in library(tmp_path)
    edit(F, T, md, capsys, "--name", "S1=Mike")
    assert "Mike" in library(tmp_path)
    assert "named_by" not in json.loads(snap_p.read_text())["clusters"]["S1"]


def test_an_edit_marks_when_the_speakers_changed(T, F, tmp_path, monkeypatch, capsys):
    """0.26.2 (B2): the call page shows "notes are out of date" when the speakers changed after the notes."""
    import time
    md = live_call(T, tmp_path, monkeypatch)
    snap_p = T.call_layout.sidecar_of(md, ".speakers.json")
    assert "edited_at" not in json.loads(snap_p.read_text())
    t0 = time.time()
    edit(F, T, md, capsys, "--name", "S1=Mike")
    assert json.loads(snap_p.read_text())["edited_at"] >= round(t0, 1) - 0.1
