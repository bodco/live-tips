"""0.10.0 (owner 12.11): the PM's own dictionary (Settings > Transcription > Dictionary). The correct words go to
Whisper's prompt before the brief's terms; the "heard as" variants are replaced by whole words, any case, in live lines
and in recordings transcribed after the call. Invented example: "Lumenfield" heard as "Lumen field"."""
import json
from types import SimpleNamespace

import numpy as np

from test_fromfile_086 import F, T, write_wav  # noqa: F401  (module fixtures: the recorder and fromfile)

ENTRIES = [{"word": "Lumenfield", "heard": ["Lumen field", "lumen fields"]},
           {"word": "Orbitex", "heard": "Orbit ex, Orbitecks"},
           {"word": "Kestrel"},
           {"word": "  ", "heard": ["nothing"]},
           {"word": "lumenfield", "heard": ["Lumin field"]}]


def test_entries_are_cleaned(T):
    e = T.dictionary_entries(ENTRIES)
    assert [x["word"] for x in e] == ["Lumenfield", "Orbitex", "Kestrel"]
    assert e[0]["heard"] == ["Lumen field", "lumen fields", "Lumin field"]       # the same word twice: variants joined
    assert e[1]["heard"] == ["Orbit ex", "Orbitecks"]                            # a comma-separated string works too
    assert T.dictionary_entries(None) == [] and T.dictionary_entries("x") == []


def test_heard_as_is_replaced_by_whole_words_any_case(T):
    rules = T.dictionary_rules(T.dictionary_entries(ENTRIES))
    f = lambda s: T.apply_dictionary(s, rules)  # noqa: E731
    assert f("We met the LUMEN  FIELD team.") == "We met the Lumenfield team."
    assert f("lumen fields and Lumen field") == "Lumenfield and Lumenfield"         # the longer variant first
    assert f("Orbitecks, orbit ex.") == "Orbitex, Orbitex."
    assert f("Lumen fielding is a word") == "Lumen fielding is a word"              # not inside another word
    assert f("xLumen field") == "xLumen field"
    assert f("") == "" and T.apply_dictionary("Lumen field", []) == "Lumen field"
    # a correct word that is only cased differently is not a variant (nothing to replace)
    assert T.dictionary_entries([{"word": "Kestrel", "heard": ["kestrel"]}])[0]["heard"] == []


def test_dictionary_words_go_first_in_whisper_prompt(T):
    words = T.dictionary_words(T.dictionary_entries(ENTRIES))
    g = T.glossary_with_dictionary(words, ["HubSpot", "kestrel", "Fireflies"])
    assert g == ["Lumenfield", "Orbitex", "Kestrel", "HubSpot", "Fireflies"]
    p = T.with_glossary("Mike and Emily discuss the pilot.", g)
    assert p.startswith("Mike and Emily discuss the pilot. Lumenfield, Orbitex, Kestrel, HubSpot")
    many = ["Word%02dxxxxxxxxxx" % i for i in range(40)]                        # the prompt keeps its length limit
    p2 = T.with_glossary("Hi.", T.glossary_with_dictionary(many, ["HubSpot"]))
    assert len(p2) <= len("Hi.") + 2 + T.GLOSSARY_CHARS and p2.startswith("Hi. Word00") and "HubSpot" not in p2


def test_recording_after_the_call_uses_the_dictionary(T, F, tmp_path, monkeypatch):
    root = tmp_path / "root"
    root.mkdir()
    (root / "config.json").write_text(json.dumps({"dictionary": [{"word": "Lumenfield", "heard": ["Lumen field"]}]}))
    monkeypatch.setattr(T, "ROOT", root)
    prompts = []

    def fake(self, audio, language, prompt):
        prompts.append(prompt)
        return "The lumen field pilot starts Monday.", language or "en"
    monkeypatch.setattr(T.FakeWhisper, "transcribe", fake)
    sr = 16000
    tone = 0.3 * np.sin(2 * np.pi * 220 * np.arange(2 * sr) / sr).astype(np.float32)
    wav = tmp_path / "rec.wav"
    write_wav(wav, np.concatenate([tone, np.zeros(sr, dtype=np.float32), tone]))
    out = tmp_path / "live" / "2026-11-12-1000-orbit-review.md"
    args = SimpleNamespace(from_file=str(wav), out=str(out), langs="en", model=None, slug="orbit", people="Emily Clark",
                           title="Orbit review", prompt=None, ui_lang="en", fake_whisper=True, no_speakers=True,
                           speakers=0, source="file", source_ref="", when="2026-11-12 10:00:00", workspace="")
    assert F.run(args, T) == 0
    text = out.read_text(encoding="utf-8")
    assert "The Lumenfield pilot starts Monday." in text and "lumen field" not in text
    assert prompts and all("Lumenfield" in (p or "") for p in prompts)
