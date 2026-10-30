"""rules/transcribe.yaml (0.8.6): a recording becomes a call-format transcript; voices are grouped after the pass."""
import importlib.util
import json
import shutil
import subprocess
import sys
import wave
from pathlib import Path
from types import SimpleNamespace

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
    return load("lt_transcriber_ff", "transcriber.py")


@pytest.fixture(scope="module")
def F():
    return load("lt_fromfile", "fromfile.py")


def voice(k, noise=0.0, seed=0):
    rng = np.random.default_rng(seed)
    v = np.zeros(32); v[k] = 1.0
    v = v + rng.normal(0, noise, 32)
    return v / np.linalg.norm(v)


def write_wav(path, audio, rate=16000):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())


def test_cluster_finds_two_voices(F):
    embs = [voice(0, 0.1, i) if i % 2 == 0 else voice(1, 0.1, i) for i in range(12)]
    lab = F.cluster(embs, [3.0] * 12)
    assert lab[0] == 0 and lab[1] == 1
    assert len(set(lab)) == 2
    assert all(lab[i] == lab[0] for i in range(0, 12, 2))


def test_cluster_fixed_count_and_lines_without_print(F):
    embs = [voice(0, 0.1, 1), None, voice(1, 0.1, 2), voice(2, 0.1, 3), voice(2, 0.1, 4)]
    lab = F.cluster(embs, [3.0] * 5, n_speakers=2)
    assert len(set(lab)) == 2
    assert lab[1] in (lab[0], lab[2])          # the line without a print takes a neighbour's speaker


def test_cluster_tiny_group_joins(F):
    embs = [voice(0, 0.05, i) for i in range(6)] + [voice(0, 0.9, 99)]
    lab = F.cluster(embs, [3.0] * 6 + [0.5])
    assert len(set(lab)) == 1


def test_segments_split_on_silence(F):
    sr = 16000
    tone = 0.3 * np.sin(2 * np.pi * 220 * np.arange(sr) / sr).astype(np.float32)
    sil = np.zeros(sr, dtype=np.float32)
    audio = np.concatenate([tone, sil, tone, sil])
    spans = F.segments(audio, lambda fr: float(np.abs(fr).max()) > 0.05)
    assert len(spans) == 2
    assert spans[0][0] == 0 and abs(spans[1][0] / sr - 1.85) < 0.1


def test_read_wav_resamples(F, tmp_path):
    p = tmp_path / "a.wav"
    write_wav(p, np.zeros(8000, dtype=np.float32), rate=8000)
    assert abs(len(F.read_wav(p)) - 16000) <= 2


def run_file(T, F, tmp_path, wav):
    out = tmp_path / "live" / "2026-10-30-1000-orbit-review.md"
    args = SimpleNamespace(from_file=str(wav), out=str(out), langs="en", model=None, slug="orbit", people="Emily Clark,Ann Lee",
                           title="Orbit review", prompt=None, ui_lang="en", fake_whisper=True, no_speakers=True,
                           speakers=0, source="link", source_ref="https://example.com/v", when="2026-10-30 10:00:00",
                           workspace="")
    assert F.run(args, T) == 0
    return out


def test_run_writes_call_format(T, F, tmp_path, capsys):
    sr = 16000
    tone = 0.3 * np.sin(2 * np.pi * 220 * np.arange(2 * sr) / sr).astype(np.float32)
    wav = tmp_path / "rec.wav"
    write_wav(wav, np.concatenate([tone, np.zeros(sr, dtype=np.float32), tone]))
    out = run_file(T, F, tmp_path, wav)
    text = out.read_text(encoding="utf-8")
    assert "- source: link" in text and "- source_ref: https://example.com/v" in text
    rows = [l for l in text.splitlines() if l.startswith("[")]
    assert rows and all(T.TAGGED_LINE.match(r) for r in rows)
    events = [json.loads(l) for l in capsys.readouterr().out.splitlines() if l.startswith("{")]
    assert events[-1]["stage"] == "done" and any(e.get("stage") == "transcribe" for e in events)
    snap = json.loads(out.with_name(out.stem + ".speakers.json").read_text())
    assert "S1" in snap["clusters"]
    assert "Speaker 1" in out.with_name(out.stem + ".named.md").read_text()


def test_edit_renames_merges_and_fixes(T, F, tmp_path, monkeypatch):
    sr = 16000
    tone = 0.3 * np.sin(2 * np.pi * 220 * np.arange(2 * sr) / sr).astype(np.float32)
    wav = tmp_path / "rec.wav"
    write_wav(wav, np.concatenate([tone, np.zeros(sr, dtype=np.float32), tone]))
    out = run_file(T, F, tmp_path, wav)
    sp = out.with_name(out.stem + ".speakers.json")
    snap = json.loads(sp.read_text())
    snap["clusters"]["S2"] = dict(snap["clusters"]["S1"], name=None)
    sp.write_text(json.dumps(snap))
    monkeypatch.setattr(T, "ROOT", tmp_path)
    assert F.edit(["--md", str(out), "--name", "S1=Emily Clark", "--merge", "S2=S1", "--fix", "00:00:00=S1"], T) == 0
    snap = json.loads(sp.read_text())
    assert snap["clusters"]["S1"]["name"] == "Emily Clark" and snap["clusters"]["S1"]["how"] == "you"
    assert snap["merged"] == {"S2": "S1"}
    named = out.with_name(out.stem + ".named.md").read_text()
    assert "Emily Clark (" in named and "Speaker 1" not in named


@pytest.mark.skipif(shutil.which("say") is None or shutil.which("afconvert") is None, reason="macOS say needed")
def test_say_audio_runs(T, F, tmp_path):
    aiff = tmp_path / "s.aiff"
    wav = tmp_path / "s.wav"
    subprocess.run(["say", "-o", str(aiff), "Hello Emily. The Orbit launch moves to Friday."], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
    out = run_file(T, F, tmp_path, wav)
    assert len([l for l in out.read_text().splitlines() if l.startswith("[")]) >= 1


def test_link_sources():
    L = load("lt_fetchlink", "fetchlink.py")
    assert L.source("https://drive.google.com/file/d/1AbCdEfGhIjK/view") == "drive"
    assert L.source("https://youtu.be/abc") == "youtube"
    assert L.source("https://vimeo.com/123") == "vimeo"
    assert L.source("https://www.dropbox.com/s/x/a.mp3") == "dropbox"
    assert L.source("https://example.com/a.mp3") == "direct"
    assert L.source("not a link") == ""
    assert L.drive_id("https://drive.google.com/file/d/1AbCdEfGhIjK/view?usp=sharing") == "1AbCdEfGhIjK"
    assert L.drive_id("https://drive.google.com/uc?export=download&id=1AbCdEfGhIjK") == "1AbCdEfGhIjK"
    assert L.needs_sign_in("ERROR: Private video. Sign in if you've been granted access")
