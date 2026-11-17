"""S1-3 (2026-11-17): the speech writer module of the skill and Prepare taking its speech document for the deck."""
import json
import re
from pathlib import Path

from livetips_m0 import codexprep, prepcontext as pc

APP = Path(__file__).resolve().parents[3]
SKILL = APP / "skill"


def test_the_module_exists_is_linked_and_points_to_talk_md():
    t = (SKILL / "references" / "speech-writer.md").read_text(encoding="utf-8")
    assert "talk.md" in t and "<project>/pacenote/speech/<deck stem>.speech.md" in t
    for line in ("## Slide 1:", "Who:", "Time:", "Numbers:", "Short:", "Can skip:", "Ask:", "Stage:"):
        assert line in t, line
    s = (SKILL / "SKILL.md").read_text(encoding="utf-8")
    assert "`speech-writer.md`" in s
    desc = re.search(r'^description: "(.*)"$', s, re.M).group(1)
    assert "напиши промову" in desc and "write my talk" in desc and len(desc) <= 1024


def _deck(tmp_path):
    deck = tmp_path / "deck.json"
    deck.write_text(json.dumps({"slides": [{"n": 1, "title": "A", "text": "x"}]}))
    return deck


def test_the_speech_document_goes_first_in_the_talk_material(tmp_path):
    sd = tmp_path / "pacenote" / "speech" / "Q4 review.speech.md"
    sd.parent.mkdir(parents=True)
    sd.write_text("# Speech: Q4\n\n## Slide 1: A\nWho: me\nTime: 30 s\nWe closed the quarter early.\n", encoding="utf-8")
    run = codexprep.Preparation.__new__(codexprep.Preparation)
    others = []
    for i in range(9):
        f = tmp_path / f"speech-part{i}.md"
        f.write_text(f"part {i}")
        others.append({"path": str(f), "kind": "file", "status": "full"})
    run.request = {"deck": str(_deck(tmp_path)), "deck_lines": "", "speech_doc": str(sd)}
    run.manifest = others
    m = run.slides_material("brief")
    assert m.index("written for this deck") < m.index("part 0") and "We closed the quarter early." in m
    assert m.count("## Speech document") == codexprep.Preparation.SLIDES_DOCS
    run.request["speech_doc"] = str(tmp_path / "missing.speech.md")
    assert "written for this deck" not in run.slides_material("brief")


def test_the_pack_pins_the_speech_document_with_a_deck(tmp_path):
    sd = tmp_path / "talk.speech.md"
    sd.write_text("## Slide 1: A\nWe closed the quarter early.\n", encoding="utf-8")
    r = {"deck": str(_deck(tmp_path)), "speech_doc": str(sd), "files": [], "folders": [], "title": "x", "root": str(tmp_path)}
    pack, _, manifest, _ = pc.build(r)
    assert "We closed the quarter early." in pack
    labels = [(m.get("label") if isinstance(m, dict) else getattr(m, "label", "")) or "" for m in manifest]
    assert any(x.startswith("The PM's speech document") for x in labels), labels
    r["deck"] = ""
    assert "We closed the quarter early." not in pc.build(r)[0], "without a deck the speech document is not pinned"
